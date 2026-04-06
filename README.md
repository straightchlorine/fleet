# Fleet

GitOps repository for managing Kubernetes infrastructure across multiple clusters using ArgoCD and Kustomize.

## Structure

```
apps/            # ArgoCD Application manifests (bootstrap)
base/            # Shared Kustomize bases (cluster-agnostic)
clusters/        # Cluster-specific overlays and configs
compose/         # Docker Compose setups (for future migration)
```

## Clusters

- **Hetzner** — k3s single-node with Traefik ingress, cert-manager (Let's Encrypt), and Sealed Secrets

## Services

| Service | Domain | Description |
|---------|--------|-------------|
| Woodpecker CI | ci.codextechnologies.org | CI/CD with Codeberg integration |
| ntfy | ntfy.codextechnologies.org | Push notifications |
| Gatus | status.codextechnologies.org | Status monitoring with ntfy alerting |
| Yopass | secrets.codextechnologies.org | One-time secret sharing |
| PostgreSQL | internal | Shared database (Hetzner) |

## Adding a service

1. Create a base in `base/<service>/`
2. Create a cluster overlay in `clusters/<cluster>/<service>/`
3. Add an ArgoCD Application in `apps/<cluster>/<service>.yaml`
4. Push to `master` — ArgoCD auto-syncs
