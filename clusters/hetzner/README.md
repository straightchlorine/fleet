# Hetzner cluster: bootstrap and recovery

ArgoCD on this k3s node syncs every Application in `apps/hetzner` (and, through
`oci-apps`, everything in `apps/oci`). Three things are applied by hand, once per
cluster: ArgoCD itself, the sealed-secrets key, and the root Application. After
that every change is a commit.

To add an app, add one Application file under `apps/<cluster>/`; the app's own
repo keeps its manifests (ADR 0009). Never `kubectl apply` an Application: the
root cannot see it, so its edits in git never reach the cluster (how `honeywatch`
drifted before `apps/hetzner/honeywatch.yaml`).

Context used below: `hetzner-debian`.

## 0. Not in this repo

- k3s with its bundled Traefik.
- The cert-manager controller. Only its ClusterIssuer is here
  (`clusters/hetzner/cert-manager`).

## 1. Install ArgoCD

```sh
kubectl --context hetzner-debian apply --server-side --force-conflicts -k clusters/hetzner/argocd-install
```

Server-side because the upstream CRDs exceed the client-side annotation limit
(the same reason `argocd-install` syncs with `ServerSideApply=true`). The root
adopts this install in step 3.

## 2. Restore the sealed-secrets key

Every SealedSecret here is encrypted to this cluster's key, and a fresh controller
generates a new one that decrypts none of them. Put the backup back before the
root deploys the controller in step 3:

```sh
kubectl --context hetzner-debian apply -f main.key
```

If the controller already started, restart it after the restore:
`kubectl --context hetzner-debian -n kube-system delete pod -l name=sealed-secrets-controller`.

Take the backup while the cluster is healthy. It holds the private keys:
`*.key` is gitignored, but move it into the vault rather than leaving it here.

```sh
kubectl --context hetzner-debian -n kube-system get secret \
  -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml > main.key
```

The controller adds a new key every 30 days. `scripts/seal.sh` seals with
`.sealed-secrets-cert.pem` (from 2026-04-05), so any later backup decrypts what
they produce; re-take it if you ever seal against the controller's current cert.

## 3. Apply the root

```sh
kubectl --context hetzner-debian apply -f apps/hetzner/root.yaml
kubectl --context hetzner-debian -n argocd get applications -w
```

`hetzner-apps` adopts itself and syncs `apps/hetzner` in waves: `argocd-install`
(-10), `sealed-secrets` (-5), `argocd-config` (-3), then everything else (0). Each
wave waits until the previous one is Healthy (the Application health check in
`clusters/hetzner/argocd-install`). If `argocd-config` stays Degraded, one of its
SealedSecrets did not decrypt: the key from step 2 is missing.

The OCI cluster's own bootstrap is in [clusters/oci/README.md](../oci/README.md).

## 4. Check nothing was registered by hand

Lists live Applications that no file under `apps/` declares; empty is the pass:

```sh
comm -13 <(grep -h '^  name:' apps/*/*.yaml | awk '{print $2}' | sort) \
  <(kubectl --context hetzner-debian -n argocd get applications -o name | cut -d/ -f2 | sort)
```
