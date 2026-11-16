<div align="center">

<h1 align="center">fleet</h1>

**Repository:** [Codeberg](https://codeberg.org/piotrkrzysztof/fleet) (primary) · [GitHub](https://github.com/straightchlorine/fleet) (mirror)

Personal GitOps for Kubernetes clusters.

**Sibling repository:** [cloud](https://codeberg.org/piotrkrzysztof/cloud)

</div>

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
| WKE | [wke.piotrkrzysztof.dev](https://wke.piotrkrzysztof.dev) | ![](https://status.codextechnologies.org/api/v1/endpoints/external_wke/health/badge.svg) | ![](https://status.codextechnologies.org/api/v1/endpoints/external_wke/uptimes/24h/badge.svg) |
| WKE API | [wke.piotrkrzysztof.dev/api](https://wke.piotrkrzysztof.dev/api/v1/status) | ![](https://status.codextechnologies.org/api/v1/endpoints/external_wke-api/health/badge.svg) | ![](https://status.codextechnologies.org/api/v1/endpoints/external_wke-api/uptimes/24h/badge.svg) |
| KSeF Docs | [ksef.piotrkrzysztof.dev](https://ksef.piotrkrzysztof.dev/) | ![](https://status.codextechnologies.org/api/v1/endpoints/docs_ksef/health/badge.svg) | ![](https://status.codextechnologies.org/api/v1/endpoints/docs_ksef/uptimes/24h/badge.svg) |
| Usher | [usher.piotrkrzysztof.dev](https://usher.piotrkrzysztof.dev) | ![](https://status.codextechnologies.org/api/v1/endpoints/external_usher/health/badge.svg) | ![](https://status.codextechnologies.org/api/v1/endpoints/external_usher/uptimes/24h/badge.svg) |
| Usher API | [usher-api.piotrkrzysztof.dev](https://usher-api.piotrkrzysztof.dev/api/health) | ![](https://status.codextechnologies.org/api/v1/endpoints/external_usher-api/health/badge.svg) | ![](https://status.codextechnologies.org/api/v1/endpoints/external_usher-api/uptimes/24h/badge.svg) |
| c-pi.org Status | [status.c-pi.org](https://status.c-pi.org) | ![](https://status.c-pi.org/api/v1/endpoints/serwis_c-pi-org/health/badge.svg) | ![](https://status.c-pi.org/api/v1/endpoints/serwis_c-pi-org/uptimes/24h/badge.svg) |


## Structure

```
apps/            # ArgoCD Application manifests (bootstrap)
base/            # Shared Kustomize bases (cluster-agnostic)
clusters/        # Cluster-specific overlays and configs
compose/         # Docker Compose setups
```

## Clusters

- **Hetzner** - single-node with Traefik ingress, cert-manager (Let's Encrypt), and
Sealed Secrets. From notable projects - it runs honeywatch dashboard and headscale.
Along with that some observability and Woodpecker CI.
- **OCI** - single-node rke2 (arm64). Registered in the Hetzner ArgoCD across headscale
tunnel; hosts WKE, the native arm64 Woodpecker agent and the host telemetry agent.

---

<div align="center">

To the only God, be honour and glory for ever and ever.

</div>
