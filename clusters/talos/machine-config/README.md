# Talos node machine config

Applied with `talosctl`. Not manifests.

## Layout

The node (CM4) has two disks:

- 32GB eMMC (`mmcblk0`): boot disk. Talos and its ~29GB ephemeral partition
  (`/var`: containerd, kubelet, etcd) live here. `install.disk` must point at it,
  or `talosctl upgrade` installs Talos onto the NVMe.
- 256GB NVMe (`nvme0n1`): a 200GB user volume for local-path PVs, so PVC growth
  does not compete with containerd and etcd. The remaining ~50GB is left for
  future user volumes.

## Patches

| File | Effect |
|------|--------|
| `install-disk.yaml` | `install.disk` -> `/dev/mmcblk0`. No reboot needed; only affects future upgrades. |
| `user-volume-local-path.yaml` | 200GB xfs user volume on the NVMe at `/var/mnt/local-path-provisioner`. Created at boot, so apply with a reboot. |

## Runbook (in order)

```bash
# 1. Set the install disk
talosctl -e 192.168.20.30 -n 192.168.20.30 patch mc --patch @install-disk.yaml

# 2. Preview, then create the user volume with a reboot
talosctl -e 192.168.20.30 -n 192.168.20.30 patch mc --patch @user-volume-local-path.yaml --dry-run

# --mode=reboot: Talos cannot apply volume documents live.
# --
# --mode=try: in Talos 1.x applies live and reverts after 1 minute unless
# confirmed; it does not roll back a failed boot.
talosctl -e 192.168.20.30 -n 192.168.20.30 patch mc --patch @user-volume-local-path.yaml --mode=reboot

# 3. Post reboot, verify. User volumes appear as u-<name>
talosctl -e 192.168.20.30 -n 192.168.20.30 get volumestatus u-local-path-provisioner
# -> partition /dev/nvme0n1p1, /var/mnt/local-path-provisioner, xfs
talosctl -e 192.168.20.30 -n 192.168.20.30 read /proc/mounts | grep nvme

# 4. Point local-path-provisioner at the volume.
kubectl apply -k clusters/talos/local-path-provisioner
```

## Kiwix zims on the NVMe

The kiwix Deployment mounts its local PVC read-only. Files go in through the
temporary pod in `kiwix/zim-loader.yaml`, driven by `kiwix/zim-fetch.sh`.

- Creates the loader on demand.
- Runs transfers in the background inside the pod.
- Writes `<name>.part`, renames on completion, so kiwix never loads a partial file.
- Records the mirror's `.sha256` - the only integrity check: busybox `wget` skips TLS validation.

```bash
# one-time setup
echo "alias zim-fetch='\$HOME/code/fleet/clusters/talos/kiwix/zim-fetch.sh'" >> ~/.bashrc

zim-fetch nas maps.zim                                    # NAS share -> volume
zim-fetch https://download.kiwix.org/zim/other/<file>.zim # mirror -> volume
zim-fetch --to nas https://.../<file>.zim                 # mirror -> share
zim-fetch <name> --to nas                                 # volume -> share
zim-fetch <name>                                          # share -> volume
zim-fetch status                                          # progress
zim-fetch dupes                                           # files on both volume and share
zim-fetch verify <name>                                   # sha256 vs the mirror's
zim-fetch cleanup                                         # delete the loader pod
```

`status` shows `interrupted - re-run fetch`: run the same command again. `wget -c`
resumes the `.part`.

A zim on both mounts is served once, from the volume. `zim-fetch dupes` lists the NAS
copies that are safe to delete.

## NAS availability (kiwix + TrueNAS)

The node resolves NFS mounts itself, not cluster DNS. Short names depend on the
search domain and break silently on DNS changes.

**Sidecar mounts the share, not the kubelet.** The kubelet mounts NFS volumes before
containers start. Workaround for lack of the "optional" flag. In such case NAS
down means `ContainerCreating` forever.

A privileged `nas-mounter` sidecar mounts the share into a shared `emptyDir`
(`mountPropagation: Bidirectional`); `kiwix-serve` sees it via `HostToContainer`.

Behaviour:

- NAS down at startup: sidecar retries every 60s; kiwix serves local zims only.
  Pod is Ready.
- NAS back later: mount appears, NAS zims show up within ~60s. kiwix serves a
  `library.xml` rebuilt when the zim list changes; `--monitorLibrary` reloads it.
- NAS fails mid-use: `soft,timeo=50` makes reads fail fast instead of hanging kiwix.

Costs:

- kiwix namespace is labelled `pod-security.kubernetes.io/enforce: privileged`;
  baseline forbids the sidecar's CAP_SYS_ADMIN.
- Sidecar runs `apk add nfs-utils` on every pod start, a few seconds.

## Notes

- `uservolumeconfig` shows in `talosctl get rd` only once such a document exists.
  Missing before the patch is expected.
- Undo the user volume: remove the `UserVolumeConfig` document, then
  `talosctl wipe disk nvme0n1p1 --drop-partition`.
- `kubectl delete pvc` hangs: a **Completed** pod still counts as a volume user, so
  `kubernetes.io/pvc-protection` never clears. Delete that pod. Data matters? Set the PV
  to `Retain` first.
- `kubectl cp` drops symlinks and breaks the HuggingFace cache (`snapshots/<rev>/<file>`
  link into `blobs/`). Use `tar cf - | tar xf -` over `kubectl exec`.
- `/var` growth in Grafana is mostly the containerd image store; it cannot leave the
  ephemeral partition.
