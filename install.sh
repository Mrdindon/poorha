#!/bin/bash
# =============================================================================
#  install.sh — installs or updates poorha from GitHub.
#
#  On a Proxmox host, as root:
#    curl -fsSL https://raw.githubusercontent.com/Mrdindon/poorha/main/install.sh | bash
#
#  Afterwards: "poorha-update" (function added to /root/.bashrc).
#
#  Options: --deploy     runs "poorha deploy -y" after the update
#           --no-bashrc  leaves /root/.bashrc alone
#  Variables: POORHA_REPO (default: Mrdindon/poorha), POORHA_REF (default: main)
# =============================================================================
set -euo pipefail

main() {
  local prefix=${POORHA_PREFIX:-}   # tests only: alternate root
  local repo=${POORHA_REPO:-Mrdindon/poorha} ref=${POORHA_REF:-main}
  local bashrc=$prefix/root/.bashrc
  local bin=$prefix/usr/local/sbin/poorha snippet=$prefix/var/lib/vz/snippets/poorha-guard.sh
  local conf=$prefix/etc/poorha/poorha.conf
  local deploy=0 do_bashrc=1 a old new

  die() { echo "ERROR: $*" >&2; exit 1; }

  for a in "$@"; do
    case "$a" in
      --deploy)    deploy=1 ;;
      --no-bashrc) do_bashrc=0 ;;
      *)           die "unknown option: $a" ;;
    esac
  done

  [ -n "$prefix" ] || [ "$(id -u)" = 0 ] || die "must be run as root"
  [[ "$repo" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || die "invalid POORHA_REPO (expected: user/repo)"
  command -v curl >/dev/null 2>&1 || die "curl not found"

  tmp=$(mktemp)   # global: read by the trap after main returns
  trap 'rm -f "$tmp"' EXIT
  curl -fsSL -o "$tmp" "https://raw.githubusercontent.com/$repo/$ref/poorha.sh" \
    || die "cannot download poorha.sh ($repo@$ref)"
  head -n1 "$tmp" | grep -q '^#!/bin/bash' || die "the downloaded file is not the expected script"
  bash -n "$tmp" || die "the downloaded script fails the syntax check"
  new=$(sed -n 's/^VERSION=//p' "$tmp" | head -n1)
  [ -n "$new" ] || die "no version found in the downloaded script"
  old=$( [ -r "$bin" ] && sed -n 's/^VERSION=//p' "$bin" | head -n1 || true )

  mkdir -p "$(dirname "$bin")"
  install -m 755 "$tmp" "$bin.tmp" && mv "$bin.tmp" "$bin"
  echo ">> poorha $new installed to $bin${old:+ (was: $old)}"
  if [ -e "$snippet" ]; then
    install -m 755 "$tmp" "$snippet.tmp" && mv "$snippet.tmp" "$snippet"
    echo ">> local hookscript updated: $snippet"
  fi

  if [ "$do_bashrc" = 1 ]; then
    touch "$bashrc"
    awk '/^# >>> poorha >>>$/{skip=1} !skip{print} /^# <<< poorha <<<$/{skip=0}' "$bashrc" >"$bashrc.poorha.tmp"
    cat >>"$bashrc.poorha.tmp" <<BLOCK
# >>> poorha >>>
# Block managed by install.sh — updates poorha from GitHub.
poorha-update() {   # poorha-update [--deploy]   (POORHA_REF=<branch|tag> for a specific version)
  curl -fsSL "https://raw.githubusercontent.com/$repo/\${POORHA_REF:-main}/install.sh" \\
    | POORHA_REPO=$repo POORHA_REF=\${POORHA_REF:-main} bash -s -- "\$@"
}
# <<< poorha <<<
BLOCK
    cat "$bashrc.poorha.tmp" >"$bashrc" && rm -f "$bashrc.poorha.tmp"
    echo ">> \"poorha-update\" function up to date in $bashrc (source ~/.bashrc to enable it)"
  fi

  echo
  if [ ! -r "$conf" ]; then
    echo "   Next: run \"poorha\" (configuration wizard), then \"Deploy\"."
  elif [ "$deploy" = 1 ]; then
    echo ">> propagating: poorha deploy -y"
    "$bin" deploy -y </dev/null
  else
    echo "   Next: \"poorha deploy\" to push this version to the other host"
    echo "         (or directly: poorha-update --deploy)."
  fi
}

main "$@"
