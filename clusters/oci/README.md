# OCI cluster: tailnet access, bootstrap, ArgoCD registration

The OCI rke2 host is managed only over the headscale tailnet: its API server
(6443) and its sshd sit on tailnet addresses, and ArgoCD on Hetzner reaches it
through that tunnel. The exception is WKE: once it is deployed, ports 80 and 443
on the node are its only public listener. The OCI security list must allow TCP
80 and 443 (precondition in section 2); the node has no host firewall: firewalld is disabled and
the INPUT chain accepts by default (checked 2026-11-14).

Order matters - every step assumes the previous one passed. Live facts (arch,
allocatable, ingress class, node tailnet IP) are recorded in section 8 below.

Contexts used below: `hetzner-debian` (the k3s cluster) and `oci-arm` (the rke2
cluster), both already in `~/.kube/config`.

## 0. Get on the tailnet

```sh
# workstation. The admin user (group:admins) is granted *:* by the ACL, so an
# interactive session needs no tag.
sudo tailscale up --login-server=https://vpn.codextechnologies.org
tailscale status
```

`tailscale status` must list the Hetzner node (tag:cluster-hetzner), the OCI node
(tag:cluster-oci) and the honeypot, then `tailscale ping <oci-node>` must answer.

A preauth key is only needed for unattended hosts
(`--authkey=... --advertise-tags=tag:...`, headplane -> Keys); the tag has to be
owned by the key's user in `tagOwners`
(`clusters/hetzner/headscale/configmap-headscale.yaml`).

The **Hetzner node must itself be a tailnet peer tagged `tag:cluster-hetzner`**:
ArgoCD's pods reach the OCI API server through that node's `tailscale0`, and every
ACL here is tag-to-tag. Check from either side:

```sh
kubectl --context hetzner-debian -n headscale exec deploy/headscale -- headscale nodes list
# or the headplane UI at https://vpn.codextechnologies.org/admin
```

Then record the addresses (both are now known; the Hetzner one is already filled
into the telemetry config):

| Address | Which peer | Where it goes |
|---|---|---|
| `100.64.0.25` (`hetzner-k3s`) | tag:cluster-hetzner | already set in `clusters/oci/observability/configmap-alloy.yaml` and in `clusters/oci/woodpecker-agent/deployment.yaml` (`WOODPECKER_SERVER`) |
| `100.64.0.2` (`oci-arm`) | tag:cluster-oci | the `server=` value of `scripts/seal.sh` in §3 |

## 1. Prove the OCI cluster itself

```sh
kubectl --context oci-arm get nodes -o wide
kubectl --context oci-arm get nodes -o jsonpath='{.items[*].status.allocatable}{"\n"}'
kubectl --context oci-arm get ingressclass
kubectl --context oci-arm -n kube-system get pods --show-labels
kubectl --context oci-arm get ns -o custom-columns=NAME:.metadata.name,PSA:.metadata.labels.pod-security\\.kubernetes\\.io/enforce
```

Measured 2026-10-14 (details in §8): one Ready node, 4 CPU / 23Gi, no taints,
`rke2-canal` CNI, and **no ingress class at all**: the WKE manifests use the
`traefik` ingress class, which section 2 lists as a precondition. `wke` exists
but is empty and unlabelled; `woodpecker` and `observability` do not exist yet:
section 2 creates them.
If `oci-arm` is missing, pull the kubeconfig off the node
(`/etc/rancher/rke2/rke2.yaml`) and rewrite `127.0.0.1` to its tailnet address.

## 2. Bootstrap (one-shot `kubectl`; none of this is ArgoCD-managed)

ArgoCD cannot create any of it: cluster-scoped resources are outside the `oci` and
`wke` AppProjects (`clusterResourceWhitelist: []`), and it needs the
Role/RoleBinding to exist before it can sync into a namespace.

```sh
kubectl --context oci-arm apply -k clusters/oci/bootstrap
```

That is the namespaces (`wke` restricted, `woodpecker` privileged,
`observability` privileged), the `kube-system/argocd-manager` Role/RoleBinding in
each of them, the long-lived ServiceAccount token, cert-manager, sealed-secrets
(v0.27.3 - this cluster's own keypair) and local-path-provisioner.

The node runs SELinux enforcing and `/opt` is `usr_t`, so the provisioner's
helper pod cannot create volume directories there: every PVC stays Pending and
anything that needs one (the Woodpecker workspace) never starts. Label the path
once, on the node:

```sh
sudo mkdir -p /opt/local-path-provisioner
sudo semanage fcontext -a -t container_file_t '/opt/local-path-provisioner(/.*)?'
sudo restorecon -Rv /opt/local-path-provisioner
```

Before the bootstrap apply, the node needs two settings. This is done by hand on
the node, not by ArgoCD. `/etc/rancher/rke2/config.yaml`:

```yaml
write-kubeconfig-mode: "0640"
tls-san:
  - 100.64.0.2
  - oci-arm
disable:
  - rke2-ingress-nginx
ingress-controller: traefik
resolv-conf: /etc/rancher/rke2/resolv.conf
```

`/etc/rancher/rke2/resolv.conf` holds two lines: `nameserver 169.254.169.254`
(the OCI resolver) and `nameserver 1.1.1.1`.

`ingress-controller: traefik` installs rke2-traefik (chart 39.0.701, Traefik
v3.6.12) as a DaemonSet with hostPort 80 and 443 on a pod-network pod, IngressClass
`traefik`; the `disable: rke2-ingress-nginx` entry is redundant and harmless.
`bootstrap/traefik-config.yaml` is a HelmChartConfig that makes Traefik write the
public hostname into every Ingress status; its Service is ClusterIP and has no
address to copy, which would leave Argo CD showing the app as Progressing.
`resolv-conf` is needed because Tailscale manages the node's `/etc/resolv.conf`
(MagicDNS): pods cannot reach that resolver, so CoreDNS, which forwards to the
kubelet's resolv.conf, answered SERVFAIL for every external name. The node's own
DNS is untouched. Restart rke2, then CoreDNS (existing pods keep the resolver
they were created with):

```sh
sudo systemctl restart rke2-server
kubectl --context oci-arm -n kube-system rollout restart deploy/rke2-coredns-rke2-coredns
```

Check afterwards; a busybox pod must fetch `https://en.wikipedia.org`:

```sh
kubectl --context oci-arm get ingressclass                # traefik is listed
kubectl --context oci-arm -n kube-system get pods -l app.kubernetes.io/name=rke2-traefik
kubectl --context oci-arm get crd middlewares.traefik.io  # exists
```

The OCI security list must allow TCP 80 and 443: they become the node's only
public listener, and the HTTP-01 challenge of the issuers below arrives on port
80. The node has no host firewall: firewalld is disabled and the INPUT chain accepts by default
(checked 2026-11-14). `wke.piotrkrzysztof.dev` is proxied through Cloudflare (not
DNS-only), zone SSL mode Full; the HTTP-01 challenge passes through the proxy.

Then, only once the webhook is up, the issuers (two applies, not one: the
ClusterIssuers are CRs whose CRDs the previous step installs):

```sh
kubectl --context oci-arm -n cert-manager wait --for=condition=Available deploy/cert-manager-webhook --timeout=180s
kubectl --context oci-arm apply -k clusters/oci/cert-manager-config
```

## 3. Register the cluster with ArgoCD (Hetzner side)

```sh
kubectl --context oci-arm -n kube-system get secret argocd-manager-token \
  -o jsonpath='{.data.token}' | base64 -d > /tmp/argocd-manager-token
kubectl --context oci-arm -n kube-system get secret argocd-manager-token \
  -o jsonpath='{.data.ca\.crt}' | base64 -d > /tmp/oci-ca.crt

jq -n --rawfile t /tmp/argocd-manager-token --rawfile ca /tmp/oci-ca.crt \
  '{bearerToken: ($t|rtrimstr("\n")), tlsClientConfig: {caData: ($ca|@base64)}}' > /tmp/oci-config.json
scripts/seal.sh -c hetzner-debian -n argocd -N oci-cluster \
  --label argocd.argoproj.io/secret-type=cluster \
  -l name=oci -l server=https://100.64.0.2:6443 \
  -l namespaces=wke,observability,woodpecker -l clusterResources=false \
  -f config=/tmp/oci-config.json -o clusters/hetzner/argocd/oci-cluster-sealed.yaml
rm -f /tmp/argocd-manager-token /tmp/oci-ca.crt /tmp/oci-config.json
```

Sealing with the committed Hetzner public key is correct here - the Secret lives
in the *Hetzner* cluster. `namespaces: "wke,observability,woodpecker"` and
`clusterResources: "false"` are what stop ArgoCD from treating the cluster as
cluster-wide, which is the failure described in §5.

## 4. Commit and push, then let ArgoCD own `apps/oci`

**Nothing untracked exists as far as ArgoCD is concerned.** `hetzner-apps`
(`apps/hetzner/root.yaml`) syncs `https://codeberg.org/piotrkrzysztof/fleet.git`
at `master`; an uncommitted manifests directory is an empty one.

Add files by path, never with `git add -A`: the working tree also holds unrelated
changes (for example `.claude/commands/`, the talos files and the `wke.json`
dashboard below).

The safe order for WKE:

1. On the node: enable Traefik, create the DNS record, open ports 80 and 443
   (the precondition in section 2). Nothing to commit.
2. Reseal `clusters/hetzner/argocd/oci-cluster-sealed.yaml` so its namespace list
   includes `wke` (section 3; the usage example in `scripts/seal.sh` now says so
   too), and push it with `clusters/hetzner/argocd/wke-project.yaml` (the `wke`
   AppProject, which the Application in step 6 names), `oci-project.yaml`
   (its `wke` destination stays for the Alloy Role) and the edited
   `clusters/hetzner/argocd/kustomization.yaml` (it lists `wke-project.yaml`;
   without it the project is never created). Sections 2 and 3 may run in either order.
3. Apply `clusters/oci/bootstrap` (namespace `wke` with the restricted
   pod-security level, `wke-argocd-rbac.yaml`) and
   `clusters/oci/cert-manager-config` (section 2). Commit both directories as well.
   If you followed section 2 already, the applies are done and idempotent.
4. Push `clusters/oci/observability`. Its new Role lives in `wke`, so steps 2 and
   3 come first.
5. In the WKE repository: merge `k8s/base` to `master`, publish the tag `0.1.0`
   and make the three ghcr packages (`wke-api`, `wke-ml`, `wke-web`) public.
6. Last: `apps/oci/wke.yaml` and
   `clusters/hetzner/argocd-image-updater/imageupdater-wke.yaml` with its
   `kustomization.yaml`.
7. Once `kubectl --context oci-arm -n wke get certificate` shows the certificate
   ready: the WKE entries in `clusters/hetzner/gatus/configmap.yaml`. They alert
   after three failed probes, so pushing them earlier pages you. The KSeF entry
   sits in the same file and can go at any time (`git add -p`).

Then once, on Hetzner:

```sh
kubectl --context hetzner-debian apply -f apps/hetzner/oci-root.yaml   # only if hetzner-apps is not live yet
```

`oci-apps` (automated, selfHeal, prune) then owns
`apps/oci/{wke,woodpecker-agent,observability}.yaml`, and those children sync
into the OCI cluster over the tunnel.

The WKE dashboard file `clusters/hetzner/observability/dashboards/wke.json` is
kept out of git until Grafana gets dashboard provisioning; it can be imported by
hand.

## 5. Verify

```sh
kubectl --context hetzner-debian -n argocd get applications
# the registration secret must carry the namespace allowlist - empty output means
# §3 has not been applied and every sync below fails on RBAC
kubectl --context hetzner-debian -n argocd get secret oci-cluster \
  -o jsonpath='{.data.namespaces}' | base64 -d; echo
kubectl --context hetzner-debian -n argocd get app oci-observability \
  -o jsonpath='{.status.sync.status} {.status.health.status}'; echo
kubectl --context oci-arm -n observability get ds,pods -o wide
```

Failure modes worth recognising:

| Symptom | Cause |
|---|---|
| `forbidden` on every list / "not permitted" on the cluster | the registration secret has no `namespaces` key (§3 not applied): ArgoCD treats the cluster as cluster-wide while the token is namespaced, so the cache never syncs |
| `namespace observability is not permitted` | `oci-project.yaml`/`wke-project.yaml` destinations and the sealed `namespaces` list are out of lockstep with the app's destination |
| app OutOfSync with an empty diff | the path does not exist at the synced revision - §4's push |

### After the first sync: two restarts ArgoCD will not do for you

Neither Prometheus nor headscale watches its config file, and neither Deployment
carries a config checksum annotation, so applying their ConfigMaps changes nothing
until the pods are replaced:

```sh
kubectl --context hetzner-debian -n observability rollout restart deploy/prometheus
kubectl --context hetzner-debian -n headscale rollout restart deploy/headscale
```

The Prometheus restart is what makes the new `node-exporter` job appear at all; the
headscale restart is what activates the two new ACL rules (control-plane blip only -
established WireGuard tunnels keep flowing). Both footguns are noted in place, in
`base/prometheus/deployment.yaml` and `base/headscale/deployment.yaml`.

## 6. The telemetry path this repo wires up

Three hosts report into the Hetzner stack; only the first is scraped.

| Host | Metrics | Logs | Transport | Auth |
|---|---|---|---|---|
| Hetzner node (Prometheus's own) | `node-exporter` DaemonSet, job `integrations/unix` (relabelled) | pod logs via the in-cluster Alloy DaemonSet | in-cluster | none needed |
| Honeypot (CentOS VPS) | Alloy unix exporter, job `integrations/unix` | Alloy journal shipping | **tailnet** | headscale ACL |
| OCI rke2 node | Alloy unix exporter, job `integrations/unix` | Alloy journal + pod logs | **tailnet** | headscale ACL |

OCI specifics:

- `clusters/oci/observability/configmap-alloy.yaml` holds the pipelines; the Loki
  push and the remote-write endpoint both point at `100.64.0.25` (`hetzner-k3s`,
  section 0).
- Alloy also scrapes the pods in `wke` that are annotated `prometheus.io/scrape:
  "true"`, only those on this node, labelled `cluster=oci`. Discovery goes
  through the `alloy` ServiceAccount and the Role in
  `clusters/oci/observability/rbac.yaml`; the samples use the same remote write,
  with no credentials. How the network policies treat host-to-pod traffic has to
  be checked after the first sync, for example `up{cluster="oci",namespace="wke"}`
  in Prometheus.
- The sinks are NodePorts on the Hetzner node - `30090` remote-write, `30310` Loki
  push (`clusters/hetzner/observability/nodeport-*.yaml`) - that exist only for the
  tunnel. `externalTrafficPolicy: Local` is load-bearing: it preserves the tailnet
  source address so the `100.64.0.0/10` ingress rules in
  `base/{prometheus,loki}/network-policy.yaml` can tell a tailnet peer from a
  public client. Those rules, not the ACL, are the last gate - Loki runs
  `auth_enabled: false` and `--web.enable-remote-write-receiver` accepts anything.
- Headscale has to allow it: `tag:cluster-oci, tag:honeypot -> tag:cluster-hetzner:{30090,30310}`
  in `clusters/hetzner/headscale/configmap-headscale.yaml` (applied with the rest
  of the headscale app).
- Nothing is sealed for this path: the credential never leaves the Hetzner side,
  so the OCI keypair (`.oci-sealed-secrets-cert.pem`) is not involved.
- The journal pipeline replays at most 12h after a restart (`max_age`), and the
  pod-log tailer uses `tail_from_end = true` because positions live in the pod
  (`--storage.path=/tmp/alloy`, the same trade-off `base/alloy` takes).

Checking it once it is up:

```sh
kubectl --context oci-arm -n observability logs ds/alloy -c alloy --tail=50
kubectl --context oci-arm -n observability port-forward ds/alloy 12345:12345  # /-/ready, component graph
# from the OCI node's own shell, the tunnel end to end (the NodePort is the
# tailnet address of the Hetzner node):
curl -sS -o /dev/null -w '%{http_code}\n' http://100.64.0.25:30310/ready
```

In Grafana (`monitoring.codextechnologies.org`, Explore) the Node Exporter Full
Job variable should offer `integrations/unix` (honeypot and OCI node side by
side) and `node-exporter` (the Hetzner node); `{cluster="oci"}` in Loki should
show the OCI host's journal plus `{namespace="wke"}` pod streams.

## 7. Known gaps

1. **`oci-cluster-sealed.yaml` has to be resealed** so the `namespaces` list
   includes `wke`, before the first sync of `apps/oci/wke.yaml` (section 3).
2. **Nothing for WKE is proven live yet.** The Traefik entry point and the
   certificate, the namespaced `wke` AppProject syncing `wke`, and Alloy's scrape
   of the `wke` pods are exercised for the first time by that rollout. After the first
   sync check `kubectl --context hetzner-debian -n argocd get app wke`,
   `kubectl --context oci-arm -n wke get certificate` and
   `up{cluster="oci",namespace="wke"}` in Prometheus.
3. **Argo CD showed `wke` as Synced and Progressing, not Healthy**: Traefik's
   Service is ClusterIP, so the Ingress status stayed empty and Argo CD's
   Ingress check waits for an address. `bootstrap/traefik-config.yaml` fixes it
   by publishing the public hostname in the status. It holds until applied
   (`kubectl --context oci-arm apply -f clusters/oci/bootstrap/traefik-config.yaml`,
   which restarts the Traefik pod).
4. **Traefik's rate limit counts per connecting address**, which behind the
   Cloudflare proxy is a Cloudflare edge address.

## 8. Live state (measured 2026-10-14, both clusters over the tailnet)

The expectations in section 1 were written before the cluster was audited. This
is what the audit actually returned; re-run it after any change.

### Tailnet

| Peer | Address | Identity |
|---|---|---|
| `hetzner-k3s` | 100.64.0.25 | `tag:cluster-hetzner` |
| `oci-arm` | 100.64.0.2 | `tag:cluster-oci` |
| `research-station` (workstation) | 100.64.0.29 | user `piotrkrzysztof` -> `group:admins`, i.e. `*:*` |

Headscale policy is `mode: file` at `/etc/headscale/acl.hujson`, so the committed
ConfigMap is the source of truth (headplane does not own it) - and it only takes
effect after a reload: `kubectl -n headscale rollout restart deploy/headscale`.

### Hetzner (`debian-k3s`, k3s v1.33.5, public 46.224.8.239, no private address)

- 16 ArgoCD apps, 15 Synced + Healthy. **`sealed-secrets` is OutOfSync** on
  `Deployment/sealed-secrets-controller` - pre-existing, unrelated to the OCI work,
  worth a look.
- `oci-apps` is live and Synced but has **no children**: everything under
  `apps/oci` was uncommitted, so ArgoCD synced an empty directory.
- `oci-cluster` registration: `server = https://100.64.0.2:6443`, keys
  `config`/`name`/`server` only - **no `namespaces`, no `clusterResources`**. §3 is
  mandatory before any OCI app can sync (commit e9c1747 added a list without
  `wke`; section 7 has the open item).
- Observability pods healthy (`alloy`, `grafana`, `loki`, `prometheus`), one
  `traefik` ingress class, both public ingest ingresses live for 28d.
- No NodePort services at all, so 30090/30310 are free.
- **No namespace carries a PSA label**, including `observability` - which is why
  the `enforce: privileged` the bootstrap adds there documents an existing fact
  rather than changing behaviour.
- Namespaces not managed by this repo: `arc-systems` (an ARC runner controller,
  361d), `honeywatch`, `portfolio`, and an empty `traefik-v2`.

### OCI (`arm-instance`, rke2 v1.35.4, Rocky 9.7, 4 CPU / 23Gi, no taints)

- CNI is `rke2-canal`, i.e. Calico enforces NetworkPolicy here.
- CoreDNS runs as `rke2-coredns-*` with rke2's own labels - **not** the
  `k8s-app: kube-dns` k3s uses, so the agent's NetworkPolicy matches `kube-system`
  by namespace only (network-policy.yaml), never by pod label.
- `local-path` StorageClass present; sealed-secrets controller running in
  `kube-system` with a keypair rotating monthly (newest 2026-10-13).
- `kube-system/argocd-manager` ServiceAccount **and** `argocd-manager-token`
  Secret exist (151d), so §3 can read the token. Role/RoleBinding exist in `wke`
  only.
- `wke` exists but is **empty and unlabelled**; the uncommitted bootstrap declares
  `enforce: restricted` for it, so a later apply adds the label with no workloads
  to evict.
- No `cert-manager`, **no ingress controller anywhere** (`get ingressclass` is
  empty), no NodePort/LoadBalancer services, no NetworkPolicies.
- `rke2-metrics-server` was NotReady when measured on 2026-10-14 and Ready
  (1/1 Running) on 2026-11-13.

### What that changes here

- Section 1: there was no ingress class yet; the `traefik` class that the WKE
  ingress uses comes from the precondition in section 2.
- §6: the tailnet ACL plus the two `100.64.0.0/10` NetworkPolicy rules are the
  entire gate on the OCI path, and both ends were verified against live tags.
- The `namespaces` list of `oci-cluster` is the one blocker for the WKE app: it
  must include `wke` (section 7); everything else is additive.

### Changes on 2026-11-14

These supersede the 10-14 bullets on ingress, cert-manager and `wke`.

- Ingress: rke2-traefik runs (DaemonSet, hostPort 80 and 443, IngressClass `traefik`).
- Resolver: the kubelet uses `/etc/rancher/rke2/resolv.conf` (section 2); pods resolve
  through the OCI resolver. Pods still cannot reach tailnet addresses; the host can.
- Host firewall: none (firewalld disabled, INPUT and FORWARD accept); the OCI security
  list allows TCP 80 and 443 from 0.0.0.0/0.
- Bootstrap applied: cert-manager v1.21.1, ClusterIssuers `letsencrypt` and
  `letsencrypt-staging` Ready; `wke` enforces pod-security restricted; the Argo CD
  registration allows `wke,observability,woodpecker`.
- WKE: Argo CD app `wke` (project `wke`), release 0.1.2, five Deployments (api, ml,
  redis, watcher, web) Running, CronJob `wke-trending` at 03:00 UTC; certificate
  `wke-tls` issued.
- CPU: 4 allocatable, requests 3055m (76 percent) with WKE; 1875m of that is the
  control plane, canal and the Woodpecker agent. wke-ml's request is 1000m, limit 2000m.
