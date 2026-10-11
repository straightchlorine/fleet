#!/usr/bin/env bash
# zim-fetch - put kiwix ZIM resources on the node's NVMe volume or the NAS share.
#
# The kiwix Deployment mounts the local PVC read-only, so resources land via the
# loader pod (kiwix/zim-loader.yaml), which has both mounts writable. Transfers
# are backgrounded within that pod.
#
#   zim-fetch <url> [name]       download from a mirror to the NVMe volume
#   zim-fetch <name>             move an existing file between the two mounts
#   zim-fetch nas <file> [name]  copy from the TrueNAS share onto the volume
#   zim-fetch --to nas <url|name> [name]
#                                target the NAS share instead of the volume
#   zim-fetch dupes              files on BOTH the volume and the NAS share
#   zim-fetch status             transfers + progress (volume and share)
#   zim-fetch kick <name>        force a retry of a stalled transfer
#   zim-fetch ls                 raw listing of the volume
#   zim-fetch log <name>         tail a transfer's log
#   zim-fetch verify <name>      sha256 vs the mirror's .sha256 sidecar
#   zim-fetch cleanup            delete the loader pod when done
set -euo pipefail

NS=kiwix
POD=zim-loader
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die() { printf 'zim-fetch: %s\n' "$*" >&2; exit 1; }
k() { kubectl -n "$NS" "$@"; }

hum() { # bytes -> human readable
  awk -v b="${1:-0}" 'BEGIN{split("B KiB MiB GiB TiB",u," ");i=1;while(b>=1024&&i<5){b/=1024;i++}
    printf (i==1 ? "%.0f %s" : "%.1f %s"), b, u[i]}'
}

pct_of() { # size expected -> " (NN%)", rounded; empty when expected is unknown
  [ "${2:-0}" = 0 ] && return
  echo " ($(( (100 * $1 + $2 / 2) / $2 ))%)"
}

ensure_loader() {
  if k get pod "$POD" >/dev/null 2>&1; then
    [[ "$(k get pod "$POD" -o jsonpath='{.status.phase}')" == Running ]] \
      || die "loader pod $POD is not Running - delete it and retry"
    return
  fi
  echo "creating loader pod..."
  kubectl apply -f "$DIR/zim-loader.yaml" >/dev/null
  k wait --for=condition=Ready "pod/$POD" --timeout=180s >/dev/null
}

# Emits "name|bytes|expected|active|where|display" for every tracked transfer.
# --
# "active" - process is still running.
#
# Checks both /proc/<pid> but also /proc/<pid>/stat. Treats "Z" as done.
#
# Finished transwer stays behind, because pod's PID 1 is `sleep infinity`
# it doesn't collect exited children.
#
# /nas is never listed: NFS metadata calls hang while the NAS is busy. NAS
# transfers report from their wget log in the pod's /tmp instead.
facts() {
  k exec "$POD" -- sh -c '
    for m in /tmp/meta-*.size; do
      [ -e "$m" ] || continue
      key=${m#/tmp/meta-}; key=${key%.size}
      e=$(cat "$m" 2>/dev/null || echo 0)
      p=$(cat "/tmp/meta-$key.pid" 2>/dev/null || echo 0)
      a=0
      if [ -n "$p" ] && [ "$p" != 0 ] && [ -r "/proc/$p/stat" ]; then
        st=$(awk "{print \$3}" "/proc/$p/stat" 2>/dev/null)
        [ "$st" != "Z" ] && a=1
      fi
      # Destination: the tag written at launch, else whether the log mentions /nas/.
      # lg is set every iteration so it never carries over from the previous file.
      lg=/tmp/wget-$key.log
      d=$(cat "/tmp/meta-$key.dest" 2>/dev/null || echo "")
      if [ -z "$d" ]; then
        if [ -f "$lg" ] && grep -q "/nas/" "$lg" 2>/dev/null; then d=nas; else d=local; fi
      fi
      # .done is touched after the final rename, so the share need not be stat-ed.
      if [ -e "/tmp/meta-$key.done" ]; then
        echo "$key|0|$e|done|$d|complete - finalised"
        continue
      fi
      if [ "$d" = nas ]; then
        tail_line=$(awk -F"|" "NF>1{print \$NF}" "$lg" 2>/dev/null | tail -1 | sed "s/^ *//;s/ *$//")
        [ -n "$tail_line" ] || tail_line="no progress logged yet"
        # Lead with the percentage: it is cumulative, while the byte count after a
        # resume covers only the current session.
        last_pct=$(grep -o "[0-9]*%" "$lg" 2>/dev/null | tail -1)
        echo "$key|0|$e|$a|nas|${last_pct:+$last_pct  }$tail_line"
      else
        s=$(stat -c %s "/local/$key" 2>/dev/null || stat -c %s "/local/$key.part" 2>/dev/null || echo 0)
        echo "$key|$s|$e|$a|local|"
      fi
    done
    # untracked files on the local volume
    for z in /local/*.zim /local/*.part; do
      [ -f "$z" ] || continue
      key=${z##*/}; key=${key%.part}
      [ -e "/tmp/meta-$key.size" ] && continue
      echo "$key|$(stat -c %s "$z")|0|0|local|"
    done'
}

# Downloads land in the mount named by $DEST_DIR (/local or /nas).
#
# Files Written as <name>.part and renamed on completion, so there is no risk
# of kiwix reading a partial.
cmd_download() {
  local url="${1:-}" name="${2:-}"
  [ -n "$url" ] || die "usage: zim-fetch <url> [name] [--to nas]"
  [ -n "$name" ] || { name="${url%%\?*}"; name="${name##*/}"; }
  [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || die "unsafe name: $name"
  ensure_loader

  # Expected size and hash come from the mirror.
  # Kiwix' .sha256 sidecar per file; check's required, because busybox wget
  # in the loader pod does not validate TLS certificates.
  local size sha dest_tag
  [ "$DEST_DIR" = /nas ] && dest_tag=nas || dest_tag=local
  size=$(curl -fsIL "$url" 2>/dev/null |
    awk 'BEGIN{IGNORECASE=1}/^content-length:/{gsub(/\r/,"");v=$2}END{print v+0}') || size=0
  sha=$(curl -fsL "$url.sha256" 2>/dev/null | awk 'NR==1{print $1}') || sha=
  [ -n "$sha" ] || echo "note: no .sha256 published - only size can be checked later"

  k exec "$POD" -- sh -c "
    echo '$size' > /tmp/meta-$name.size
    echo '$sha' > /tmp/meta-$name.sha
    echo '$dest_tag' > /tmp/meta-$name.dest
    # Retry loop: wget -c resumes, so mid-transfer stalls cost a retry instead of
    # ending the download with 'download timed out'.
    nohup sh -c '
      i=0
      while [ \$i -lt 200 ]; do
        # -T 60: the busybox default of 900s leaves a stall idle for 15 minutes.
        wget -c -T 60 -O $DEST_DIR/$name.part $url >> /tmp/wget-$name.log 2>&1
        rc=\$?
        sz=\$(stat -c %s $DEST_DIR/$name.part 2>/dev/null || echo 0)
        [ \$rc = 0 ] && break
        [ $size != 0 ] && [ \$sz -ge $size ] && break
        i=\$((i+1))
        sleep 10
      done
      mv $DEST_DIR/$name.part $DEST_DIR/$name && touch /tmp/meta-$name.done
    ' >/dev/null 2>&1 &
    echo \$! > /tmp/meta-$name.pid"
  printf 'fetching %s -> %s/%s (%s)\n' "$url" "$DEST_DIR" "$name" "$(hum "$size")"
  [ "$DEST_DIR" = /nas ] && echo "note: writing to the share runs at ~12MB/s and needs the NAS up"
  echo "track it with: zim-fetch status"
}

# Moves a file between the mounts:
# copy, rename, delete (separate filesystems) - similarly backgrounded.
cmd_move() {
  local name="${1:-}" src_dir
  [ -n "$name" ] || die "usage: zim-fetch <name> [--to nas|local]"
  [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || die "unsafe name: $name"
  ensure_loader
  [ "$DEST_DIR" = /nas ] && src_dir=/local || src_dir=/nas

  local size dest_tag
  [ "$DEST_DIR" = /nas ] && dest_tag=nas || dest_tag=local
  size=$(k exec "$POD" -- stat -c %s "$src_dir/$name" 2>/dev/null || echo 0)
  [ "$size" != 0 ] || die "not found: $src_dir/$name"
  k exec "$POD" -- sh -c "
    echo '$size' > /tmp/meta-$name.size
    echo '$dest_tag' > /tmp/meta-$name.dest
    nohup sh -c 'cp $src_dir/$name $DEST_DIR/$name.part && mv $DEST_DIR/$name.part $DEST_DIR/$name && rm -f $src_dir/$name' >/tmp/mv-$name.log 2>&1 &
    echo \$! > /tmp/meta-$name.pid"
  printf 'moving %s -> %s/%s (%s)\n' "$src_dir/$name" "$DEST_DIR" "$name" "$(hum "$size")"
}

cmd_nas() {
  local src="${1:-}" name="${2:-}"
  [ -n "$src" ] || die "usage: zim-fetch nas <file> [name]"
  [ -n "$name" ] || name="${src##*/}"
  [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || die "unsafe name: $name"
  ensure_loader

  local size
  size=$(k exec "$POD" -- stat -c %s "/nas/$src" 2>/dev/null || echo 0)
  [ "$size" != 0 ] || die "no such file on the NAS share: /nas/$src"
  k exec "$POD" -- sh -c "
    echo '$size' > /tmp/meta-$name.size
    echo 'local' > /tmp/meta-$name.dest
    nohup sh -c 'cp /nas/$src /local/$name.part && mv /local/$name.part /local/$name' >/tmp/cp-$name.log 2>&1 &
    echo \$! > /tmp/meta-$name.pid"
  printf 'copying /nas/%s -> /local/%s (%s, ~%s at 12MB/s)\n' \
    "$src" "$name" "$(hum "$size")" "$(awk -v b="$size" 'BEGIN{printf "%d min", b/12e6/60}')"
}

cmd_status() {
  local found=0 name size exp act where display state pct stalled=
  while IFS='|' read -r name size exp act where display; do
    [ -n "$name" ] || continue
    found=1; pct=
    if [ -n "$display" ]; then
      case "$display" in *stalled*) stalled=1 ;; esac
      printf '%-42s %-5s %s\n' "${name%.part}" "$where" "$display$([ "$act" = 0 ] && echo '  [not running]')"
      continue
    fi
    if [ "$act" = 1 ]; then
      # a live pid wins over the filename: cp writes to the final name only at the end
      state=downloading
      pct=$(pct_of "$size" "$exp")
    elif [[ "$name" == *.part ]]; then
      # leftover .part with no process: re-running the fetch resumes it via wget -c
      state='interrupted - re-run fetch'
      pct=$(pct_of "$size" "$exp")
    else
      state=ready
      if [ "$exp" != 0 ] && [ "$size" != "$exp" ]; then state='SIZE MISMATCH'; fi
    fi
    printf '%-42s %-5s %10s / %10s  %s%s\n' "${name%.part}" "$where" "$(hum "$size")" \
      "$([ "$exp" = 0 ] && echo - || hum "$exp")" "$state" "$pct"
  done < <(facts)
  [ "$found" = 1 ] || echo "nothing tracked yet"
  [ -n "$stalled" ] && echo "hint: a '- stalled -' transfer retries itself every ~60s; to force it now: zim-fetch kick <name>"
  return 0
}

cmd_ls() {
  case "${1:-}" in
    local) k exec "$POD" -- ls -la /local ;;
    nas) k exec "$POD" -- ls -la /nas ;;
    '') k exec "$POD" -- sh -c '
          echo "--- /local (NVMe volume)"; ls -la /local
          echo "--- /nas (TrueNAS share)"; ls -la /nas' ;;
    *) die "usage: zim-fetch ls [local|nas]" ;;
  esac
}

cmd_log() {
  local name="${1:-}"
  [ -n "$name" ] || die "usage: zim-fetch log <name>"
  k exec "$POD" -- sh -c "
    [ -f /tmp/wget-$name.log ] && tail -n 20 /tmp/wget-$name.log
    [ -f /tmp/cp-$name.log ] && tail -n 20 /tmp/cp-$name.log
    [ -f /tmp/mv-$name.log ] && tail -n 20 /tmp/mv-$name.log
    exit 0"
}

# Kills a transfer's wget so the retry loop starts a new attempt without waiting
# for the socket timeout.
cmd_kick() {
  local name="${1:-}"
  [ -n "$name" ] || die "usage: zim-fetch kick <name>"
  ensure_loader
  local out
  out=$(k exec "$POD" -- sh -c "
    n=0
    for p in /proc/[0-9]*; do
      c=\$(tr '\\0' ' ' < \"\$p/cmdline\" 2>/dev/null) || continue
      case \"\$c\" in
        wget*'$name'*) kill \${p#/proc/} 2>/dev/null && n=\$((n+1)) ;;
      esac
    done
    echo \"\$n\"") || true
  case "$out" in
    '' | 0) echo "nothing to kick for $name (no wget running - re-run the fetch instead)" ;;
    *) echo "kicked $out wget process(es) for $name; the loop resumes within ~10s" ;;
  esac
}

cmd_verify() {
  local name="${1:-}" exp got where
  [ -n "$name" ] || die "usage: zim-fetch verify <name>"
  exp=$(k exec "$POD" -- cat "/tmp/meta-$name.sha" 2>/dev/null || true)
  where=$(k exec "$POD" -- sh -c "
    [ -f /local/$name ] && echo /local/$name || { [ -f /nas/$name ] && echo /nas/$name; }" | tr -d '\r')
  [ -n "$where" ] || die "not found on either mount: $name"
  echo "hashing $where ..."
  got=$(k exec "$POD" -- sha256sum "$where" | awk '{print $1}')
  if [ -z "$exp" ]; then
    echo "no .sha256 recorded for $name (only URL fetches store one)"
    echo "sha256: $got"
    return 1
  fi
  if [ "$got" = "$exp" ]; then
    echo "OK - $name matches $exp"
  else
    printf 'MISMATCH for %s\n  expected %s\n  actual   %s\n' "$name" "$exp" "$got"
    return 1
  fi
}

# kiwix serves a file on both mounts once, from the volume; the NAS copy is dead weight.
cmd_dupes() {
  ensure_loader
  local out
  out=$(k exec "$POD" -- sh -c '
    for l in /local/*.zim; do
      [ -e "$l" ] || continue
      n=${l##*/}
      [ -e "/nas/$n" ] && echo "$n"
    done
    exit 0') || true
  if [ -z "$out" ]; then
    echo "no duplicates - nothing on the volume also exists on the share"
    return
  fi
  echo "present on BOTH the NVMe and the NAS share - kiwix serves the volume copy:"
  while IFS= read -r n; do echo "  $n"; done <<<"$out"
  echo
  echo "safe to delete them from the share (NAS-side)"
}

cmd_cleanup() {
  k delete pod "$POD" --ignore-not-found
  echo "loader removed; remember to re-run only if you need more resources"
}

usage() {
  # Prints the file header (shebang to `set`) without comment markers.
  sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//; $d'
}

main() {
  DEST_DIR=/local
  local dest=local rest=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --to) dest="${2:-}"; shift 2 ;;
      --to=*) dest="${1#--to=}"; shift ;;
      *) rest+=("$1"); shift ;;
    esac
  done
  case "$dest" in
    local) DEST_DIR=/local ;;
    nas) DEST_DIR=/nas ;;
    *) die "--to expects 'local' or 'nas', got: '$dest'" ;;
  esac
  set -- ${rest[@]+"${rest[@]}"}

  case "${1:-}" in
    '' | -h | --help | help) usage ;;
    nas) shift; cmd_nas "$@" ;;
    status) cmd_status ;;
    ls) shift; cmd_ls "$@" ;;
    dupes) cmd_dupes ;;
    log) shift; cmd_log "$@" ;;
    kick) shift; cmd_kick "$@" ;;
    verify) shift; cmd_verify "$@" ;;
    cleanup) cmd_cleanup ;;
    http*) cmd_download "$@" ;;
    *.zim) cmd_move "$@" ;;
    *) die "unknown command: $1 (try: zim-fetch help)" ;;
  esac
}

main "$@"
