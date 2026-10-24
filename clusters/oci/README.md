# OCI cluster: tailnet access, bootstrap, ArgoCD registration

The OCI rke2 host is reachable **only** over the headscale tailnet: its API
server (6443), its sshd and everything else on it sit on tailnet addresses.
ArgoCD on Hetzner manages it through that tunnel, so there is no path in or out
that does not start with a working tailnet session.

Order matters - every step assumes the previous one passed. Live facts (arch,
allocatable, ingress class, pod CIDR, node tailnet IP) belong in the WKE repo's
`docs/internal/architecture/OCI_FACTS.md`; `ARCHITECTURE.md` section 12 is the
why behind each manifest here.

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
| `100.64.0.25` (`hetzner-k3s`) | tag:cluster-hetzner | already set in `clusters/oci/observability/configmap-alloy.yaml`; still a `<HETZNER_TAILNET_IP>` placeholder in `clusters/oci/woodpecker-agent/deployment.yaml` (`WOODPECKER_SERVER`, next slice) |
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
`rke2-canal` CNI, and **no ingress class at all** - ADR 0008 assumes `traefik`,
which is a WKE prerequisite, not current state. `wke` exists but is empty and
unlabelled; `woodpecker` and `observability` do not exist yet: §2 creates them.
If `oci-arm` is missing, pull the kubeconfig off the node
(`/etc/rancher/rke2/rke2.yaml`) and rewrite `127.0.0.1` to its tailnet address.

## 2. Bootstrap (one-shot `kubectl`; none of this is ArgoCD-managed)

ArgoCD cannot create any of it: cluster-scoped resources are outside the `oci`
AppProject (`clusterResourceWhitelist: []`), and it needs the Role/RoleBinding to
exist before it can sync into a namespace.

```sh
kubectl --context oci-arm apply -k clusters/oci/bootstrap
```

That is the namespaces (`wke` restricted, `woodpecker` privileged,
`observability` privileged), the `kube-system/argocd-manager` Role/RoleBinding in
each of them, the long-lived ServiceAccount token, cert-manager, sealed-secrets
(v0.27.3 - this cluster's own keypair) and local-path-provisioner.

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
  -l namespaces=observability,woodpecker -l clusterResources=false \
  -f config=/tmp/oci-config.json -o clusters/hetzner/argocd/oci-cluster-sealed.yaml
rm -f /tmp/argocd-manager-token /tmp/oci-ca.crt /tmp/oci-config.json
```

Sealing with the committed Hetzner public key is correct here - the Secret lives
in the *Hetzner* cluster. `namespaces: "wke,woodpecker,observability"` and
`clusterResources: "false"` are what stop ArgoCD from treating the cluster as
cluster-wide, which is the failure described in §5.

## 4. Commit and push, then let ArgoCD own `apps/oci`

**Nothing untracked exists as far as ArgoCD is concerned.** `hetzner-apps`
(`apps/hetzner/root.yaml`) syncs `https://codeberg.org/piotrkrzysztof/fleet.git`
at `master`; an uncommitted manifests directory is an empty one.

```sh
git add -A && git commit -m "feat(oci): telemetry over the tailnet" && git push
```

Then once, on Hetzner:

```sh
kubectl --context hetzner-debian apply -f apps/hetzner/oci-root.yaml   # only if hetzner-apps is not live yet
```

`oci-apps` (automated, selfHeal, prune) then owns
`apps/oci/{wke,woodpecker-agent,observability}.yaml`, and those children sync
into the OCI cluster over the tunnel.

### First slice: telemetry only

The first rollout is deliberately `observability` alone - it has no coupling to
WKE or Woodpecker (no ingress, no cert-manager, no PVCs) and it proves the whole
tailnet + ArgoCD + NetworkPolicy path on its own. Commit exactly this set and
leave the rest for the next slice:

```
# Hetzner
base/loki/network-policy.yaml
base/prometheus/network-policy.yaml
base/headscale/deployment.yaml
base/prometheus/deployment.yaml
clusters/hetzner/headscale/configmap-headscale.yaml
clusters/hetzner/observability/namespace.yaml
clusters/hetzner/observability/kustomization.yaml
clusters/hetzner/observability/configmap-prometheus.yaml
clusters/hetzner/observability/nodeport-loki.yaml
clusters/hetzner/observability/nodeport-prometheus.yaml
clusters/hetzner/observability/node-exporter-daemonset.yaml
clusters/hetzner/observability/node-exporter-service.yaml
clusters/hetzner/argocd/oci-project.yaml
scripts/seal.sh

# Required by the configMapGenerator that file already had - omitting it makes the
# live observability app's kustomize build fail, taking Grafana/Loki/Prometheus
# with it.
clusters/hetzner/observability/dashboards/wke.json

# OCI
clusters/oci/bootstrap/            # namespaces + argocd-manager RBAC + token
clusters/oci/cert-manager-config/  # §2's second apply
clusters/oci/observability/
apps/oci/observability.yaml
clusters/oci/README.md

# Unchanged until §3 reseals it, so nothing to add today:
clusters/hetzner/argocd/oci-cluster-sealed.yaml
```

Deliberately **not** in this commit: `apps/oci/{wke,woodpecker-agent}.yaml`,
`clusters/oci/woodpecker-agent/`, `clusters/hetzner/woodpecker/*` (the gRPC
NodePort and its sealed secret), `base/woodpecker-server/deployment.yaml` and
`clusters/hetzner/observability/dashboards/wke.json`. `git add -A` drags all of
them in - including `.claude/commands/` - so add by path.

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
| `namespace observability is not permitted` | `oci-project.yaml` destinations and the sealed `namespaces` list are out of lockstep with the app's destination |
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

- `clusters/oci/observability/configmap-alloy.yaml` holds both pipelines; both
  endpoints point at `100.64.0.25` (`hetzner-k3s`, §0).
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

## 7. Known gaps as of this commit

1. **The OCI change set had never been committed.** Everything under
   `clusters/oci/` and `apps/oci/`, plus the matching edits in
   `clusters/hetzner/{argocd,headscale,woodpecker}`, was untracked or unstaged.
   ArgoCD only ever sees `master`, so none of it existed - §4 is the step that
   makes the multicluster setup real.
2. **`oci-cluster-sealed.yaml` carries no `namespaces`/`clusterResources` key.**
   Both the WKE app and `oci-observability` need the §3 reseal; until then the
   registration is cluster-wide against a namespaced token and the cache never
   syncs.
3. **`clusters/oci/woodpecker-agent/deployment.yaml` still has a
   `<HETZNER_TAILNET_IP>` placeholder** for its `WOODPECKER_SERVER`
   (`100.64.0.25`, §0). Out of the first slice, so it is only a blocker once that
   app is committed.
4. **`clusters/oci/woodpecker-agent/sealed-agent-token.yaml` does not exist yet**
   (`scripts/seal.sh -c oci-arm -n woodpecker -N woodpecker-agent-secret -f agent-secret=...`) - deliberately out of the first slice,
   so `apps/oci/woodpecker-agent.yaml` should not be committed until then.
5. **Nothing here is proven live.** The namespaced `oci` AppProject model, the two
   NodePort policies, rke2's CoreDNS labels under the `observability`
   NetworkPolicy and the pod-log path parsing are all exercised for the first time
   by this rollout. §5's checks are the ones to watch, in that order.

## After B8: drop the QEMU step (B8.3)

Once the OCI arm64 agent (`clusters/oci/woodpecker-agent`) is registering
successfully against the Hetzner gRPC NodePort, remove only the
`tonistiigi/binfmt --install arm64` privileged init step, if one was added, from
`base/woodpecker-server/deployment.yaml`. Keep the
`WOODPECKER_PLUGINS_PRIVILEGED` allowance for
Which leaves no namespace between the two clusters named `node-exporter`: the
Hetzner DaemonSet lives in `observability` like the OCI agent.

## 8. Live state (measured 2026-10-14, both clusters over the tailnet)

§1's expectations were written from the plan, not the cluster. This is what the
audit actually returned; re-run it after any change.

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
  `Deployment/sealed-secrets-controller` - pre-existing, unrelated to this slice,
  worth a look.
- `oci-apps` is live and Synced but has **no children**: everything under
  `apps/oci` was uncommitted, so ArgoCD synced an empty directory.
- `oci-cluster` registration: `server = https://100.64.0.2:6443`, keys
  `config`/`name`/`server` only - **no `namespaces`, no `clusterResources`**. §3 is
  mandatory before any OCI app can sync.
- Observability pods healthy (`alloy`, `grafana`, `loki`, `prometheus`), one
  `traefik` ingress class, both public ingest ingresses live for 28d.
- No NodePort services at all, so 30090/30310 are free.
- **No namespace carries a PSA label**, including `observability` - which is why
  the `enforce: privileged` this change adds there documents an existing fact
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
- `rke2-metrics-server` is **NotReady** (151d): it cannot reach the kubelet,
  `dial tcp 10.0.0.32:10250: no route to host`. Pre-existing, unrelated, and it
  will block `kubectl top` and HPAs later.

### What that changes here

- §1: there is no ingress class to expect yet; ADR 0008's `traefik` is a WKE
  prerequisite, not current state.
- §6: the tailnet ACL plus the two `100.64.0.0/10` NetworkPolicy rules are the
  entire gate on the OCI path, and both ends were verified against live tags.
- The missing `namespaces` key in `oci-cluster` is the one true blocker; every
  other item in this slice is additive.
