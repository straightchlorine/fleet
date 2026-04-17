# Fleet

Personal GitOps repo for my homelab Kubernetes clusters.

## Live status


| Service | URL | Health | Uptime (24h) |
|---------|-----|:------:|:------------:|
| Woodpecker CI | [ci.codextechnologies.org](https://ci.codextechnologies.org) | ![](https://status.codextechnologies.org/api/v1/endpoints/infrastructure_woodpecker-ci/health/badge.svg) | ![](https://status.codextechnologies.org/api/v1/endpoints/infrastructure_woodpecker-ci/uptimes/24h/badge.svg) |
| ntfy | [ntfy.codextechnologies.org](https://ntfy.codextechnologies.org) | ![](https://status.codextechnologies.org/api/v1/endpoints/infrastructure_ntfy/health/badge.svg) | ![](https://status.codextechnologies.org/api/v1/endpoints/infrastructure_ntfy/uptimes/24h/badge.svg) |
| Headscale VPN | [vpn.codextechnologies.org](https://vpn.codextechnologies.org) | ![](https://status.codextechnologies.org/api/v1/endpoints/infrastructure_headscale-vpn/health/badge.svg) | ![](https://status.codextechnologies.org/api/v1/endpoints/infrastructure_headscale-vpn/uptimes/24h/badge.svg) |
| Headplane Admin | [vpn.codextechnologies.org/admin](https://vpn.codextechnologies.org/admin) | ![](https://status.codextechnologies.org/api/v1/endpoints/infrastructure_headplane-admin/health/badge.svg) | ![](https://status.codextechnologies.org/api/v1/endpoints/infrastructure_headplane-admin/uptimes/24h/badge.svg) |
| Yopass | [secrets.codextechnologies.org](https://secrets.codextechnologies.org) | ![](https://status.codextechnologies.org/api/v1/endpoints/infrastructure_yopass/health/badge.svg) | ![](https://status.codextechnologies.org/api/v1/endpoints/infrastructure_yopass/uptimes/24h/badge.svg) |
| Grafana | [monitoring.codextechnologies.org](https://monitoring.codextechnologies.org) | ![](https://status.codextechnologies.org/api/v1/endpoints/infrastructure_grafana/health/badge.svg) | ![](https://status.codextechnologies.org/api/v1/endpoints/infrastructure_grafana/uptimes/24h/badge.svg) |
| Loki | internal | ![](https://status.codextechnologies.org/api/v1/endpoints/infrastructure_loki/health/badge.svg) | ![](https://status.codextechnologies.org/api/v1/endpoints/infrastructure_loki/uptimes/24h/badge.svg) |
| Blog | [piotrkrzysztof.dev](https://piotrkrzysztof.dev) | ![](https://status.codextechnologies.org/api/v1/endpoints/external_blog/health/badge.svg) | ![](https://status.codextechnologies.org/api/v1/endpoints/external_blog/uptimes/24h/badge.svg) |
| Honeywatch Dashboard | [honey.piotrkrzysztof.dev](https://honey.piotrkrzysztof.dev) | ![](https://status.codextechnologies.org/api/v1/endpoints/external_honeywatch-dashboard/health/badge.svg) | ![](https://status.codextechnologies.org/api/v1/endpoints/external_honeywatch-dashboard/uptimes/24h/badge.svg) |
| Honeywatch API | [honey.piotrkrzysztof.dev/api](https://honey.piotrkrzysztof.dev/api/stats) | ![](https://status.codextechnologies.org/api/v1/endpoints/external_honeywatch-api/health/badge.svg) | ![](https://status.codextechnologies.org/api/v1/endpoints/external_honeywatch-api/uptimes/24h/badge.svg) |


## Structure

```
apps/            # ArgoCD Application manifests (bootstrap)
base/            # Shared Kustomize bases (cluster-agnostic)
clusters/        # Cluster-specific overlays and configs
compose/         # Docker Compose setups (for future migration)
```

## Clusters

- **Hetzner** — k3s single-node with Traefik ingress, cert-manager (Let's Encrypt), and Sealed Secrets
