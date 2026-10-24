#!/usr/bin/env bash
# Seal a Secret for one cluster's sealed-secrets controller. The one script
# that replaces the per-secret reseal-*.sh ones.
#
# The cert is fetched from the controller of --context each run, so it is
# always the current key and no *.pem has to be kept around. Sealing is
# strict-scoped (bound to namespace + name), the kubeseal default.
set -euo pipefail

usage() {
  cat <<'EOF'
usage: scripts/seal.sh -c CONTEXT -n NAMESPACE -N NAME [options]

  -c, --context CTX       kube context of the cluster the Secret will live in
  -n, --namespace NS      namespace of the Secret
  -N, --name NAME         name of the Secret
  -f, --from-file K=PATH  key from a file (repeatable)
  -l, --from-literal K=V  key from a value (repeatable; lands in shell history,
                          prefer --from-file for anything real)
      --label K=V         label on the resulting Secret (repeatable)
      --type TYPE         Secret type (default Opaque)
  -o, --out FILE          write the SealedSecret here and validate it against
                          the controller (default: stdout, not validated)
      --cert FILE         seal offline with this cert instead of fetching one
  -h, --help

examples
  # OCI agent token (value read from a file, never echoed)
  scripts/seal.sh -c oci-arm -n woodpecker -N woodpecker-agent-secret \
    -f agent-secret=/tmp/agent-secret -o clusters/oci/woodpecker-agent/sealed-agent-token.yaml

  # ArgoCD cluster registration (sealed for Hetzner, where ArgoCD runs)
  jq -n --rawfile t /tmp/token --rawfile ca /tmp/ca.crt \
    '{bearerToken: ($t|rtrimstr("\n")), tlsClientConfig: {caData: ($ca|@base64)}}' > /tmp/config.json
  scripts/seal.sh -c hetzner-debian -n argocd -N oci-cluster \
    --label argocd.argoproj.io/secret-type=cluster \
    -l name=oci -l server=https://100.64.0.2:6443 \
    -l namespaces=observability,woodpecker -l clusterResources=false \
    -f config=/tmp/config.json -o clusters/hetzner/argocd/oci-cluster-sealed.yaml
EOF
}

die() { echo "seal.sh: $*" >&2; exit 1; }

ctx= ns= name= out= cert= type=
from=() labels=()
while [ $# -gt 0 ]; do
  case $1 in
    -c|--context)      ctx=${2:?}; shift 2 ;;
    -n|--namespace)    ns=${2:?}; shift 2 ;;
    -N|--name)         name=${2:?}; shift 2 ;;
    -f|--from-file)    from+=("--from-file=${2:?}"); shift 2 ;;
    -l|--from-literal) from+=("--from-literal=${2:?}"); shift 2 ;;
    --label)           labels+=("${2:?}"); shift 2 ;;
    --type)            type=${2:?}; shift 2 ;;
    -o|--out)          out=${2:?}; shift 2 ;;
    --cert)            cert=${2:?}; shift 2 ;;
    -h|--help)         usage; exit 0 ;;
    *)                 usage >&2; die "unknown option: $1" ;;
  esac
done

[ -n "$ctx" ] && [ -n "$ns" ] && [ -n "$name" ] || { usage >&2; die "-c, -n and -N are required"; }
[ ${#from[@]} -gt 0 ] || die "nothing to seal: pass -f or -l"
command -v kubeseal >/dev/null || die "kubeseal not found"

# A placeholder sealed by accident is a secret that decrypts to garbage.
for a in "${from[@]}"; do
  v=${a#--from-*=}
  if [[ $a == --from-file=* ]]; then
    p=${v#*=}; [ -s "$p" ] || die "$p is missing or empty"
    ! grep -qiE 'REPLACE_ME|<[A-Z_]+>' "$p" || die "$p still contains a placeholder"
  else
    [[ $v != *REPLACE_ME* && $v != *'<'*'>'* ]] || die "literal still contains a placeholder"
  fi
done

ks=(--context "$ctx" --controller-name sealed-secrets-controller --controller-namespace kube-system)
[ -z "$cert" ] || ks+=(--cert "$cert")

mk() {
  kubectl create secret generic "$name" -n "$ns" ${type:+--type "$type"} "${from[@]}" \
    --dry-run=client -o json
}
if [ ${#labels[@]} -gt 0 ]; then
  mk | kubectl label --local -f - "${labels[@]}" -o json
else
  mk
fi | if [ -n "$out" ]; then kubeseal "${ks[@]}" -o yaml > "$out"; else kubeseal "${ks[@]}" -o yaml; fi

if [ -n "$out" ] && [ -z "$cert" ]; then
  kubeseal "${ks[@]}" --validate < "$out" >&2
  echo "sealed $ns/$name for $ctx -> $out (validated)" >&2
fi
