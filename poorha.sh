#!/bin/bash
# =============================================================================
#  poorha — poor man's HA for Proxmox VMs and containers between two
#           non-clustered hosts (no Ceph, no shared storage).
#
#  Every protected guest (VM or LXC container) has a twin on the other host: an exact copy (same MACs)
#  made by vzdump → zstd → ssh → qmrestore. Only one of the two is ACTIVE
#  (running, NICs connected); the other is on STANDBY (NICs link_down=1 except
#  the ones listed in "keep", VM running or stopped).
#
#  A single file, installed on both hosts:
#    /usr/local/sbin/poorha                 → the tool (whiptail menu + CLI)
#    /var/lib/vz/snippets/poorha-guard.sh   → the SAME file, used as the
#                                             Proxmox hookscript (guard)
#  Each host has its own /etc/poorha/poorha.conf; poorha mirrors the "vm"
#  lines on the peer itself (vmids swapped).
#
#  Usage: poorha            interactive menu
#         poorha help       CLI help
# =============================================================================

VERSION=0.3.1
CONF_DIR=${POORHA_CONF_DIR:-/etc/poorha}
CONF=$CONF_DIR/poorha.conf
GUARD_OFF_FLAG=$CONF_DIR/guard.disable
BIN=/usr/local/sbin/poorha
SNIPPET_DIR=/var/lib/vz/snippets
SNIPPET_NAME=poorha-guard.sh
SNIPPET_REF="local:snippets/$SNIPPET_NAME"
LOG_DIR=/var/log/poorha
SSH_CTL_DIR=/run/poorha
ROUTER_NOTE="Move the ONU / fiber to the WAN port of %NODE%."

# =============================================================================
#  CONFIGURATION MODEL — shared by the hookscript and the tool
# =============================================================================
VM_KEYS=(peer type standby keep guard ref note)
VM_IDS=()           # protected guests, by local vmid
declare -A V=()     # V[<local vmid>.<key>]

defaults() {
  NODE_NAME=${NODE_NAME:-$(hostname -s)}; NODE_IP=${NODE_IP:-}
  PEER_NAME=${PEER_NAME:-};               PEER_IP=${PEER_IP:-}
  STORAGE=${STORAGE:-local-lvm};          REF_IP=${REF_IP:-}
  GUARD_TRIES=${GUARD_TRIES:-15};         HEALTH_PING=${HEALTH_PING:-}
  TMP_DIR=${TMP_DIR:-/var/tmp}
}

vget()   { local v=${V[$1.$2]:-}; [ "$2" = standby ] && v=${v:-cold}; printf '%s' "$v"; }
has_vm() { [ -n "${V[$1.peer]+x}" ]; }
vtype()  { local t; t=$(vget "$1" type); echo "${t:-qemu}"; }                  # qemu | lxc
pcmd()   { if [ "$(vtype "$1")" = lxc ]; then echo pct; else echo qm; fi; }   # CLI of the pair
kind()   { if [ "$(vtype "$1")" = lxc ]; then echo ct; else echo vm; fi; }    # label prefix

vm() {   # config directive:  vm <vmid> peer=<vmid> [key=value…]
  local id=$1 kv k; shift
  if ! [[ "$id" =~ ^[0-9]+$ ]]; then echo "poorha: invalid line ignored: vm $id $*" >&2; return 0; fi
  has_vm "$id" || VM_IDS+=("$id")
  for k in "${VM_KEYS[@]}"; do unset "V[$id.$k]"; done
  V[$id.peer]=""
  for kv in "$@"; do
    k=${kv%%=*}
    if [[ "$kv" == *=* && " ${VM_KEYS[*]} " == *" $k "* ]]; then V[$id.$k]=${kv#*=}
    else echo "poorha: vm $id: \"$kv\" ignored" >&2; fi
  done
}

load_conf() {
  VM_IDS=(); V=()
  [ -r "$CONF" ] || return 1
  # shellcheck source=/dev/null
  . "$CONF"
  defaults
}

# ------------------------------------------------------------ NIC helpers ----
is_kept() { [[ ",$2," == *",$1,"* ]]; }   # is_kept netX "net1,net2"

watched_nics() {   # watched_nics "<vm config>" "<keep>" → "netX: …" lines of the NICs NOT kept up
  local net
  for net in $(grep -oE '^net[0-9]+' <<<"$1"); do
    is_kept "$net" "$2" || grep -E "^$net: " <<<"$1"
  done
}

lan_state() {   # lan_state "<vm config>" "<keep>" → up | down | none
  local w; w=$(watched_nics "$1" "$2")
  if [ -z "$w" ]; then echo none
  elif grep -qv 'link_down=1' <<<"$w"; then echo up
  else echo down; fi
}

first_bridge() { watched_nics "$1" "$2" | grep -oE 'bridge=[^,]+' | head -n1 | cut -d= -f2; }

# =============================================================================
#  HOOKSCRIPT MODE — Proxmox calls: <script> <vmid> <phase>
#  Must stay self-contained: no whiptail, no prompt.
# =============================================================================
hook_main() {
  local vmid=$1 phase=$2 conf keep peer out rc ip br ref tries i c=qm
  [ "$phase" = "pre-start" ] || return 0
  hlog() { echo "poorha-guard[$vmid]: $*"; }

  if ! load_conf; then hlog "no $CONF — start allowed"; return 0; fi
  if ! has_vm "$vmid"; then hlog "guest not protected by poorha — start allowed"; return 0; fi
  [ "$(vtype "$vmid")" = lxc ] && c=pct
  if [ -e "$GUARD_OFF_FLAG" ]; then hlog "guard disabled ($GUARD_OFF_FLAG) — start allowed"; return 0; fi

  keep=$(vget "$vmid" keep); peer=$(vget "$vmid" peer)
  conf=$($c config "$vmid" 2>/dev/null)
  case "$(lan_state "$conf" "$keep")" in
    down) hlog "links down (standby) — start allowed"; return 0 ;;
    none) hlog "no NIC that standby can cut — relying on the peer check" ;;
  esac

  # 1. Ask the peer whether the twin is active
  if [ -n "$PEER_IP" ] && [ -n "$peer" ]; then
    out=$(ssh -o BatchMode=yes -o ConnectTimeout=3 -o StrictHostKeyChecking=accept-new "root@$PEER_IP" \
          "$c status $peer 2>/dev/null && $c config $peer 2>/dev/null; true" 2>/dev/null)
    rc=$?
    if [ "$rc" = 255 ]; then
      hlog "$PEER_NAME unreachable — peer check skipped"
    elif [ "$(head -n1 <<<"$out" | awk '{print $2}')" = running ] \
         && [ "$(lan_state "$(tail -n +2 <<<"$out")" "$keep")" != down ]; then
      hlog "twin $peer is ACTIVE on $PEER_NAME — START BLOCKED"
      return 1
    else
      hlog "twin $peer on $PEER_NAME is not active"
    fi
  fi

  # 2. Is the service IP already answering on the LAN?
  ip=$(vget "$vmid" guard)
  if [ -z "$ip" ]; then hlog "no guard IP — start allowed"; return 0; fi
  br=$(first_bridge "$conf" "$keep")
  if [ -z "$br" ]; then hlog "no bridge to probe — start allowed"; return 0; fi
  if ! command -v arping >/dev/null 2>&1; then hlog "arping missing — START BLOCKED to be safe"; return 1; fi
  ref=$(vget "$vmid" ref); ref=${ref:-$REF_IP}
  tries=$GUARD_TRIES; [ -n "$ref" ] || tries=3

  for ((i = 1; i <= tries; i++)); do
    if arping -q -c 1 -w 1 -I "$br" "$ip"; then
      hlog "$ip already answers on $br — another copy is active, START BLOCKED"
      return 1
    fi
    if [ -n "$ref" ] && arping -q -c 1 -w 1 -I "$br" "$ref"; then
      hlog "LAN is working ($ref answers), $ip absent — start allowed"
      return 0
    fi
  done
  hlog "$ip absent after $tries tries — start allowed"
  return 0
}

if [[ "${1:-}" =~ ^[0-9]+$ && "${2:-}" =~ ^(pre|post)-(start|stop)$ ]]; then
  hook_main "$1" "$2"
  exit $?
fi

# =============================================================================
#  TOOL MODE
# =============================================================================
set -uo pipefail

SELF=$(readlink -f "$0")
TUI=0
YES=0
FORCE=0
PEER_DOWN=0
PEER_VERSION=""
RESERVED=""   # vmids handed out during a batch of additions: "L110 P205 …"
SSH_BASE=(-o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new)
SSH_OPTS=("${SSH_BASE[@]}" -o ControlMaster=auto -o "ControlPath=$SSH_CTL_DIR/%C" -o ControlPersist=60)

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo ">> $*"; }
warn() { echo "WARNING: $*" >&2; }

confirm() {   # confirm "message"   (\n allowed)
  [ "$YES" = 1 ] && return 0
  if [ "$TUI" = 1 ]; then
    local h; h=$(( $(printf '%b\n' "$1" | wc -l) + 8 ))
    [ "$h" -lt 10 ] && h=10; [ "$h" -gt 24 ] && h=24
    whiptail --title "Confirmation" --scrolltext --yesno "$1" "$h" 76
    return
  fi
  local r
  echo -e "$1"
  read -r -p "Continue? [y/N] " r
  [[ "$r" =~ ^[yY]$ ]]
}

have_tui() { [ -t 0 ] && [ -t 1 ] && command -v whiptail >/dev/null 2>&1; }
qcmd() { printf '%q ' "$@"; }   # quotes a command line for on()

# ------------------------------------------------------------ config edits --
qv() {   # value as written in the config file
  if [[ "$1" =~ ^[A-Za-z0-9._,:/@+%-]*$ ]]; then printf '%s' "$1"; return; fi
  local s=${1//\\/\\\\}; s=${s//\"/\\\"}; s=${s//\$/\\\$}; s=${s//\`/\\\`}
  printf '"%s"' "$s"
}

vm_set() {   # vm_set VMID key=value…   (validated; merges into an existing entry)
  local id=$1 kv k v ipre='^(([0-9]{1,3}\.){3}[0-9]{1,3})?$'; shift
  [[ "$id" =~ ^[0-9]+$ ]] || die "invalid vmid: $id"
  has_vm "$id" || { VM_IDS+=("$id"); V[$id.peer]=""; }
  for kv in "$@"; do
    [[ "$kv" == *=* ]] || die "key=value expected: $kv"
    k=${kv%%=*}; v=${kv#*=}
    case "$k" in
      peer)      [[ "$v" =~ ^[0-9]+$ ]]                    || die "peer: a vmid is expected" ;;
      type)      [[ "$v" =~ ^(qemu|lxc)?$ ]]               || die "type: qemu or lxc" ;;
      standby)   [[ "$v" =~ ^(cold|hot)$ ]]                || die "standby: cold or hot" ;;
      keep)      [[ "$v" =~ ^(net[0-9]+(,net[0-9]+)*)?$ ]] || die "keep: netX[,netY…] (or empty)" ;;
      guard|ref) [[ "$v" =~ $ipre ]]                       || die "$k: an IPv4 address is expected (or empty)" ;;
      note)      ;;
      *)         die "unknown VM option: $k (${VM_KEYS[*]} profile)" ;;
    esac
    V[$id.$k]=$v
  done
}

del_vm() {
  local id=$1 i k keep=()
  for i in "${VM_IDS[@]}"; do [ "$i" = "$id" ] || keep+=("$i"); done
  VM_IDS=("${keep[@]}")
  for k in "${VM_KEYS[@]}"; do unset "V[$id.$k]"; done
}

vm_line() {   # "vm 108 peer=208 standby=hot …" as written in the config
  local id=$1 k v line="vm $1"
  for k in "${VM_KEYS[@]}"; do
    v=$(vget "$id" "$k"); [ -n "$v" ] && line+=" $k=$(qv "$v")"
  done
  echo "$line"
}

mirror_args() {   # the entry as the peer must store it (vmids swapped), one arg per line
  local id=$1 k
  echo "peer=$id"
  for k in "${VM_KEYS[@]}"; do [ "$k" = peer ] || echo "$k=$(vget "$id" "$k")"; done
}

key_of_peer() {   # key_of_peer PEER_VMID → local vmid of the pair, or nothing
  local k
  for k in "${VM_IDS[@]}"; do [ "$(vget "$k" peer)" = "$1" ] && { echo "$k"; return; }; done
}

write_conf() {
  local id
  mkdir -p "$CONF_DIR"
  {
    cat <<EOF
# poorha — configuration of THIS node. Each node has its own file;
# poorha mirrors the "vm" lines on the peer itself (vmids swapped).
# Generated on $(date '+%F %T') by poorha $VERSION

NODE_NAME=$(qv "$NODE_NAME")          # this host (hostname -s)
NODE_IP=$(qv "$NODE_IP")              # its IP on the MGMT link
PEER_NAME=$(qv "$PEER_NAME")          # the other host
PEER_IP=$(qv "$PEER_IP")
STORAGE=$(qv "$STORAGE")              # where replications received by THIS node land

REF_IP=$(qv "$REF_IP")                # always-on LAN device (switch): proves the LAN works
GUARD_TRIES=$(qv "$GUARD_TRIES")
HEALTH_PING=$(qv "$HEALTH_PING")      # optional: pinged from the source host before a replication
TMP_DIR=$(qv "$TMP_DIR")              # containers: the archive is staged here before "pct restore"

# Protected VMs:
# vm <local vmid> peer=<vmid on the peer> [type=lxc] [standby=cold|hot] [keep=netX,…]
#    [guard=<IP of the service>] [ref=<IP>] [note="text shown after activation, %NODE% = host"]
EOF
    for id in $(printf '%s\n' "${VM_IDS[@]}" | sort -n); do vm_line "$id"; done
  } >"$CONF.tmp" && mv "$CONF.tmp" "$CONF"
}

# ------------------------------------------------------------------ sides ----
#  L = this host, P = the peer.  A pair is designated by its local vmid (KEY).
nname() { if [ "$1" = L ]; then echo "$NODE_NAME"; else echo "$PEER_NAME"; fi; }
other() { if [ "$1" = L ]; then echo P; else echo L; fi; }
svmid() { if [ "$2" = L ]; then echo "$1"; else vget "$1" peer; fi; }   # svmid KEY SIDE
label() { echo "$(nname "$2")/$(kind "$1")$(svmid "$1" "$2")"; }

on() {   # on <L|P> "<command>"  — local: bash -c ; peer: ssh (255 at once if known to be down)
  if [ "$1" = L ]; then bash -c "$2"
  elif [ "$PEER_DOWN" = 1 ]; then return 255
  else ssh "${SSH_OPTS[@]}" "root@$PEER_IP" "$2"; fi
}

peer_probe() {   # one SSH round trip: is the peer up, which poorha does it run?
  local out
  PEER_DOWN=0; PEER_VERSION=""
  if out=$(ssh "${SSH_OPTS[@]}" "root@$PEER_IP" "$BIN version 2>/dev/null; true" 2>/dev/null); then
    PEER_VERSION=${out#poorha }
  else
    PEER_DOWN=1
  fi
}

version_mismatch() {   # → a warning text if the peer runs another version (or none)
  [ "$PEER_DOWN" = 0 ] || return 1
  [ "$PEER_VERSION" != "$VERSION" ] || return 1
  echo "$PEER_NAME runs poorha ${PEER_VERSION:-(not installed)}, this host $VERSION — run \"poorha deploy\""
}

resolve_side() {
  case "$1" in
    L|l|local|"$NODE_NAME") echo L ;;
    P|p|peer|"$PEER_NAME")  echo P ;;
    *) die "unknown node: $1 (expected: $NODE_NAME or $PEER_NAME)" ;;
  esac
}

# Reads /etc/pve directly: "qm list" / "pct list" / pvesh take a second or more each.
read -r -d '' LIST_SCRIPT <<'EOS'
for f in /etc/pve/qemu-server/*.conf /etc/pve/lxc/*.conf; do
  [ -e "$f" ] || continue
  id=${f##*/}; id=${id%.conf}
  case $f in
    */lxc/*) t=lxc; n=$(sed -n '/^\[/q;s/^hostname: //p' "$f")
             if [ "$(lxc-info -n "$id" -sH 2>/dev/null)" = RUNNING ]; then st=running; else st=stopped; fi ;;
    *)       t=qemu; n=$(sed -n '/^\[/q;s/^name: //p' "$f"); p=/var/run/qemu-server/$id.pid
             if [ -e "$p" ] && kill -0 "$(cat "$p")" 2>/dev/null; then st=running; else st=stopped; fi ;;
  esac
  echo "$id ${n:-$id} $st $t"
done | sort -n
EOS
read -r -d '' USED_SCRIPT <<'EOS'
ls /etc/pve/nodes/*/qemu-server/ /etc/pve/nodes/*/lxc/ 2>/dev/null | sed -n 's/^\([0-9][0-9]*\)\.conf$/\1/p' | tr '\n' ' '
EOS

list_vms() { on "$1" "$LIST_SCRIPT" 2>/dev/null; }   # list_vms SIDE → "vmid name status qemu|lxc"

declare -A USED=()   # SIDE → " 100 101 … " vmids in use on that node (cache)
load_used() {   # load_used SIDE
  local out
  out=$(on "$1" "$USED_SCRIPT" 2>/dev/null) || return 1
  USED[$1]=" $out "
}

guest_type() {   # guest_type SIDE VMID → qemu | lxc | nothing (no such guest)
  on "$1" "if [ -e /etc/pve/lxc/$2.conf ]; then echo lxc; elif [ -e /etc/pve/qemu-server/$2.conf ]; then echo qemu; fi" 2>/dev/null
}

resolve_vm() {   # local vmid | peer vmid | VM name → KEY
  local x=$1 k id name st t
  if [[ "$x" =~ ^[0-9]+$ ]]; then
    has_vm "$x" && { echo "$x"; return; }
    k=$(key_of_peer "$x"); [ -n "$k" ] && { echo "$k"; return; }
  else
    while read -r id name st t; do
      [ "$name" = "$x" ] && has_vm "$id" && { echo "$id"; return; }
    done < <(list_vms L)
    while read -r id name st t; do
      k=$(key_of_peer "$id"); [ "$name" = "$x" ] && [ -n "$k" ] && { echo "$k"; return; }
    done < <(list_vms P)
  fi
  die "no protected VM matches \"$x\""
}

# --------------------------------------------------------------- VM state ----
# Reads the config file and the run state directly: much faster than "qm" / "pct".
read -r -d '' PROBE_QEMU <<'EOS'
f=/etc/pve/qemu-server/@ID@.conf p=/var/run/qemu-server/@ID@.pid
if [ -e "$f" ]; then
  if [ -e "$p" ] && kill -0 "$(cat "$p")" 2>/dev/null; then echo "status: running"; else echo "status: stopped"; fi
  sed '/^\[/,$d' "$f"
fi
true
EOS
read -r -d '' PROBE_LXC <<'EOS'
f=/etc/pve/lxc/@ID@.conf
if [ -e "$f" ]; then
  if [ "$(lxc-info -n @ID@ -sH 2>/dev/null)" = RUNNING ]; then echo "status: running"; else echo "status: stopped"; fi
  sed '/^\[/,$d' "$f"
fi
true
EOS

probe_script() {   # probe_script KEY SIDE → the shell snippet that probes that copy
  local tpl=$PROBE_QEMU
  [ "$(vtype "$1")" = lxc ] && tpl=$PROBE_LXC
  printf '%s' "${tpl//@ID@/$(svmid "$1" "$2")}"
}

parse_vm() {   # parse_vm KEY "<probe output>" → VM_EXISTS VM_RUN VM_LAN VM_CONF VM_NAME
  local out=${2%$'\n'}
  VM_EXISTS=0 VM_RUN=0 VM_LAN=none VM_CONF="" VM_NAME=""
  [ -n "$out" ] || return 0
  VM_EXISTS=1
  [ "${out%%$'\n'*}" = "status: running" ] && VM_RUN=1
  VM_CONF=$(tail -n +2 <<<"$out")
  VM_NAME=$(grep -E '^(name|hostname): ' <<<"$VM_CONF" | head -n1 | cut -d' ' -f2-)
  VM_LAN=$(lan_state "$VM_CONF" "$(vget "$1" keep)")
}

get_vm() {   # get_vm KEY SIDE → VM_REACH VM_EXISTS VM_RUN VM_LAN(up|down|none) VM_CONF VM_NAME
  local out
  VM_REACH=0; parse_vm "$1" ""
  out=$(on "$2" "$(probe_script "$1" "$2")" 2>/dev/null) || return 0
  VM_REACH=1; parse_vm "$1" "$out"
}

declare -A PROBE=() PROBE_OK=()   # one round trip per node for every pair (menus)
probe_all() {   # probe_all SIDE → PROBE[SIDE.KEY], PROBE_OK[SIDE]
  local s=$1 k script="" out line cur=""
  for k in "${VM_IDS[@]}"; do script+="echo '@@@ $k'"$'\n'"$(probe_script "$k" "$s")"$'\n'; PROBE[$s.$k]=""; done
  PROBE_OK[$s]=0
  out=$(on "$s" "$script" 2>/dev/null) || return 0
  PROBE_OK[$s]=1
  while IFS= read -r line; do
    if [[ "$line" == "@@@ "* ]]; then cur=${line#@@@ }; continue; fi
    [ -n "$cur" ] && PROBE[$s.$cur]+="$line"$'\n'
  done <<<"$out"
}

get_vm_cached() {   # get_vm_cached KEY SIDE — from the last probe_all
  VM_REACH=${PROBE_OK[$2]:-0}
  parse_vm "$1" "${PROBE[$2.$1]:-}"
}

is_active() { [ "$VM_REACH" = 1 ] && [ "$VM_EXISTS" = 1 ] && [ "$VM_RUN" = 1 ] && [ "$VM_LAN" != down ]; }

role_short() {   # after get_vm: ≤ 11 characters, for the tables
  if [ "$VM_REACH" = 0 ]; then echo "UNREACHABLE"
  elif [ "$VM_EXISTS" = 0 ]; then echo "missing"
  else
    case "$VM_LAN-$VM_RUN" in
      up-1|none-1) echo "ACTIVE" ;;
      up-0)        echo "stopped(up)" ;;
      down-1)      echo "STANDBY hot" ;;
      down-0)      echo "STANDBY" ;;
      none-0)      echo "stopped" ;;
    esac
  fi
}

role_txt() {   # after get_vm
  if [ "$VM_REACH" = 0 ]; then echo "UNREACHABLE"
  elif [ "$VM_EXISTS" = 0 ]; then echo "missing"
  else
    case "$VM_LAN-$VM_RUN" in
      up-1)   echo "ACTIVE" ;;
      up-0)   echo "stopped (links up)" ;;
      down-1) echo "STANDBY (hot)" ;;
      down-0) echo "STANDBY" ;;
      none-1) echo "ACTIVE (no NIC)" ;;
      none-0) echo "stopped (no NIC)" ;;
    esac
  fi
}

nic_lines() {   # after get_vm KEY …
  local net cfg br st keep; keep=$(vget "$1" keep)
  for net in $(grep -oE '^net[0-9]+' <<<"$VM_CONF"); do
    cfg=$(sed -n "s/^$net: //p" <<<"$VM_CONF")
    br=$(grep -oE 'bridge=[^,]+' <<<"$cfg" | cut -d= -f2)
    if [[ "$cfg" == *link_down=1* ]]; then st="link down"; else st="link up"; fi
    is_kept "$net" "$keep" && st+="   (kept up on standby)"
    printf '        %-6s %-10s %s\n' "$net" "$br" "$st"
  done
}

links_set() {   # links_set KEY SIDE standby|up — a single "qm set" for all NICs
  local k=$1 s=$2 mode=$3 net cfg new br args=() vmid keep
  vmid=$(svmid "$k" "$s"); keep=$(vget "$k" keep)
  get_vm "$k" "$s"
  [ "$VM_REACH" = 1 ]  || die "$(nname "$s") is unreachable"
  [ "$VM_EXISTS" = 1 ] || die "VM $vmid is missing on $(nname "$s")"
  for net in $(grep -oE '^net[0-9]+' <<<"$VM_CONF"); do
    cfg=$(sed -n "s/^$net: //p" <<<"$VM_CONF")
    br=$(grep -oE 'bridge=[^,]+' <<<"$cfg" | cut -d= -f2)
    new=$(sed -E 's/,link_down=[01]//' <<<"$cfg")
    if [ "$mode" = standby ] && ! is_kept "$net" "$keep"; then new="$new,link_down=1"; fi
    if [ "$new" != "$cfg" ]; then
      args+=("--$net" "$new")
      if [[ "$new" == *link_down=1* ]]; then info "$(label "$k" "$s"): $net ($br) → link down"
      else info "$(label "$k" "$s"): $net ($br) → link up"; fi
    fi
  done
  if [ "${#args[@]}" -gt 0 ]; then
    on "$s" "$(pcmd "$k") set $vmid $(qcmd "${args[@]}") >/dev/null" || die "$(pcmd "$k") set failed on $(nname "$s")"
  fi
}

ip_alive() {   # ip_alive KEY SIDE — after get_vm KEY (any side): does the guard IP answer, seen from SIDE?
  local ip br; ip=$(vget "$1" guard)
  [ -n "$ip" ] || return 1
  br=$(first_bridge "$VM_CONF" "$(vget "$1" keep)")
  [ -n "$br" ] || return 1
  on "$2" "arping -q -c 2 -w 3 -I $br $ip" >/dev/null 2>&1
}

auto_direction() {   # auto_direction KEY → "L P" if the local copy is the only active one, "P L" for the reverse
  local a b
  get_vm "$1" L; is_active && a=1 || a=0
  get_vm "$1" P; is_active && b=1 || b=0
  if [ "$a" = 1 ] && [ "$b" = 0 ]; then echo "L P"
  elif [ "$b" = 1 ] && [ "$a" = 0 ]; then echo "P L"
  fi
}

mp_warnings() {   # mp_warnings "<container config>" → what a replication does NOT carry over
  local line mp v
  while read -r line; do
    mp=${line%%:*}; v=${line#*: }
    if [[ "$v" == /* ]]; then
      echo "$mp: bind mount ${v%%,*} — not replicated, must exist on the other host"
    elif [[ "$v" != *backup=1* ]]; then
      echo "$mp: volume ${v%%,*} excluded from backups (backup=1 missing) — its data is NOT replicated"
    fi
  done < <(grep -E '^mp[0-9]+: ' <<<"$1")
}

activation_note() { local n; n=$(vget "$1" note); echo "${n//%NODE%/$(nname "$2")}"; }

# =============================================================================
#  PROTECTED VMS — add / remove / settings
# =============================================================================
save_vm() {   # writes the local config and mirrors the entry on the peer
  local k=$1 a=()
  write_conf
  mapfile -t a < <(mirror_args "$k")
  on P "$(qcmd "$BIN" _set-vm "$(vget "$k" peer)" "${a[@]}")" >/dev/null \
    || warn "could not update the config of $PEER_NAME${PEER_VERSION:+ (poorha $PEER_VERSION)} — run \"poorha deploy\" to resync"
}

hook_attach() {   # hook_attach SIDE VMID qm|pct — only if the guest exists
  on "$1" "$3 status $2 >/dev/null 2>&1 || exit 0; $3 set $2 --hookscript $SNIPPET_REF >/dev/null" \
    || warn "$(nname "$1")/$2: could not attach the hookscript"
}

hook_detach() {   # hook_detach SIDE VMID qm|pct — only if it is ours
  on "$1" "$3 config $2 2>/dev/null | grep -qx 'hookscript: $SNIPPET_REF' && $3 set $2 --delete hookscript >/dev/null; true"
}

vmid_used_conf() {   # vmid_used_conf SIDE VMID — already part of a pair?
  if [ "$1" = L ]; then has_vm "$2"; else [ -n "$(key_of_peer "$2")" ]; fi
}

pick_free() {   # pick_free SIDE WANTED → a vmid free on SIDE: WANTED, else the next free one
  local s=$1 id=$2 n
  [ -n "${USED[$s]+x}" ] || load_used "$s" || return 1
  [ "$id" -ge 100 ] 2>/dev/null || id=100
  for ((n = 0; n < 10000; n++, id++)); do
    if ! vmid_used_conf "$s" "$id" && [[ " $RESERVED " != *" $s$id "* && "${USED[$s]}" != *" $id "* ]]; then
      echo "$id"; return 0
    fi
  done
  return 1
}

guest_ip() {   # guest_ip SIDE VMID qemu|lxc → IPv4 of the first watched NIC
  local s=$1 id=$2 conf mac ip
  if [ "$3" = lxc ]; then   # static ip= in the config, else what the running container reports
    conf=$(on "$s" "pct config $id" 2>/dev/null)
    ip=$(watched_nics "$conf" "" | head -n1 | grep -oE 'ip=[0-9.]+' | cut -d= -f2)
    [ -n "$ip" ] || ip=$(on "$s" "lxc-info -n $id -iH 2>/dev/null" | grep -vE '^127\.|:' | head -n1)
    echo "$ip"
    return 0
  fi
  conf=$(on "$s" "qm config $id" 2>/dev/null)
  grep -qE '^agent: (1|enabled=1)' <<<"$conf" || return 0
  mac=$(watched_nics "$conf" "" | head -n1 | grep -oiE '([0-9a-f]{2}:){5}[0-9a-f]{2}')
  [ -n "$mac" ] || return 0
  on "$s" "qm status $id | grep -q running && timeout 10 qm guest cmd $id network-get-interfaces" 2>/dev/null \
    | perl -MJSON::PP -e '
        my $mac = lc shift; my $j = eval { decode_json(join "", <STDIN>) } or exit;
        for my $if (@$j) {
          next unless lc($if->{"hardware-address"} // "") eq $mac;
          for my $a (@{ $if->{"ip-addresses"} || [] }) {
            if ($a->{"ip-address-type"} eq "ipv4") { print $a->{"ip-address"}; exit }
          }
        }' "$mac"
}

pair_add() {   # pair_add SIDE VMID [OTHER_VMID] [key=value…] — protects VM VMID existing on SIDE
  local s=$1 id=$2 oid=${3:-} o key pv h ip="" t c conf w
  shift 3 2>/dev/null || shift $#
  o=$(other "$s")
  if vmid_used_conf "$s" "$id"; then warn "$(nname "$s")/$id is already protected"; return 1; fi
  t=$(guest_type "$s" "$id")
  if [ -z "$t" ]; then warn "guest $id does not exist on $(nname "$s")"; return 1; fi
  if [ "$t" = lxc ]; then c=pct; else c=qm; fi
  conf=$(on "$s" "$c config $id" 2>/dev/null)
  h=$(sed -n 's/^hookscript: //p' <<<"$conf")
  if [ -n "$h" ] && [ "$h" != "$SNIPPET_REF" ] && [ "$FORCE" != 1 ]; then
    warn "$(nname "$s")/$id already uses the hookscript $h — poorha would replace it (-f to accept)"; return 1
  fi
  if [ "$t" = lxc ]; then
    while read -r w; do [ -n "$w" ] && warn "$(nname "$s")/ct$id $w"; done <<<"$(mp_warnings "$conf")"
  fi
  if [ -z "$oid" ]; then
    oid=$(pick_free "$o" "$id") || { warn "no free vmid found on $(nname "$o")"; return 1; }
  elif vmid_used_conf "$o" "$oid"; then
    warn "vmid $oid on $(nname "$o") already belongs to another pair"; return 1
  fi
  RESERVED+=" $o$oid"
  if [ "$s" = L ]; then key=$id; pv=$oid; else key=$oid; pv=$id; fi

  vm_set "$key" "peer=$pv" "$@"
  [ "$t" = lxc ] && vm_set "$key" type=lxc
  if [ -z "$(vget "$key" guard)" ]; then
    ip=$(guest_ip "$s" "$id" "$t")
    [ -n "$ip" ] && vm_set "$key" "guard=$ip"
  fi
  save_vm "$key"
  hook_attach "$s" "$id" "$c"
  hook_attach "$o" "$oid" "$c"
  info "protected: $(label "$key" L) ↔ $(label "$key" P) (copy on $(nname "$s"))${ip:+ — guard IP $ip}"
}

pair_remove() {   # pair_remove KEY — the VMs themselves are left untouched
  local k=$1 pv c ll lp; pv=$(vget "$k" peer); c=$(pcmd "$k")
  ll=$(label "$k" L); lp=$(label "$k" P)
  hook_detach L "$k" "$c"
  hook_detach P "$pv" "$c"
  del_vm "$k"
  write_conf
  on P "$BIN _del-vm $pv" >/dev/null || warn "could not update the config of $PEER_NAME — run \"poorha deploy\""
  info "no longer protected: $ll ↔ $lp (guests left as they are)"
}

expand_profile() {   # expand_profile key=value… → KV=(…) with "profile=" expanded
  local kv out=() prof=""
  for kv in "$@"; do case "$kv" in profile=*) prof=${kv#*=} ;; *) out+=("$kv") ;; esac; done
  case "$prof" in
    "")       ;;
    standard) out=(standby=cold keep= note= "${out[@]}") ;;
    router)   out=(standby=hot "note=$ROUTER_NOTE" "${out[@]}") ;;
    *)        die "profile: standard or router" ;;
  esac
  KV=("${out[@]}")
}

candidates() {   # "SIDE VMID NAME STATUS TYPE" for every guest of both nodes that is not protected
  local s id name st t
  for s in L P; do
    while read -r id name st t; do
      [ -n "$id" ] || continue
      vmid_used_conf "$s" "$id" && continue
      echo "$s $id $name $st $t"
    done < <(list_vms "$s")
  done
}

cmd_add() {   # cmd_add VMID|all [NODE] [key=value…]
  local what=$1 s="" oid="" c n=0 bad=0 rest=() kv; shift
  if [ $# -gt 0 ] && [[ "$1" != *=* ]]; then s=$(resolve_side "$1") || exit 1; shift; fi
  expand_profile "$@"
  for kv in "${KV[@]}"; do case "$kv" in peer=*) oid=${kv#peer=} ;; *) rest+=("$kv") ;; esac; done

  if [ "$what" = all ]; then
    [ -z "$oid" ] || die "peer= cannot be used with \"all\""
    local list=() msg=""
    mapfile -t list < <(candidates)
    [ ${#list[@]} -gt 0 ] || { info "every VM is already protected"; return 0; }
    for c in "${list[@]}"; do
      # shellcheck disable=SC2086
      set -- $c; msg+="  $(nname "$1")/$([ "$5" = lxc ] && echo ct || echo vm)$2  $3\n"
    done
    confirm "Protect these VMs (the twin is created on the other node by the first replication):\n\n$msg" || die "cancelled"
    for c in "${list[@]}"; do
      # shellcheck disable=SC2086
      set -- $c
      if pair_add "$1" "$2" "" "${rest[@]}"; then n=$((n + 1)); else bad=$((bad + 1)); fi
    done
    info "$n VM(s) added, $bad skipped"
    return 0
  fi

  [[ "$what" =~ ^[0-9]+$ ]] || die "usage: poorha add VMID|all [NODE] [peer=VMID] [key=value…]"
  if [ -z "$s" ]; then
    if [ -n "$(guest_type L "$what")" ]; then s=L
    elif [ -n "$(guest_type P "$what")" ]; then s=P
    else die "guest $what exists on neither node"; fi
  fi
  pair_add "$s" "$what" "$oid" "${rest[@]}" || exit 1
}

cmd_set() {   # cmd_set KEY key=value…
  local k=$1 kv old new o c; shift
  [ $# -gt 0 ] || die "usage: poorha set VM key=value…   (${VM_KEYS[*]} profile=standard|router)"
  expand_profile "$@"
  old=$(vget "$k" peer)
  for kv in "${KV[@]}"; do   # peer=: the twin moves to another vmid on the peer
    [[ "$kv" == peer=* ]] && [ "${kv#peer=}" != "$old" ] || continue
    new=${kv#peer=}
    o=$(key_of_peer "$new")
    [ -z "$o" ] || die "vmid $new on $PEER_NAME already belongs to the pair of $NODE_NAME/$o"
    get_vm "$k" P
    is_active && die "$(label "$k" P) is the ACTIVE copy — switch to $NODE_NAME first, then change its vmid"
  done
  vm_set "$k" "${KV[@]}"
  new=$(vget "$k" peer)
  [ "$(vget "$k" standby)" = hot ] && [ -z "$(vget "$k" keep)" ] \
    && warn "hot standby without keep=: every NIC will be down on standby"
  save_vm "$k"
  if [ "$new" != "$old" ]; then
    c=$(pcmd "$k")
    on P "$BIN _del-vm $old" >/dev/null || warn "could not remove the old entry from the config of $PEER_NAME"
    hook_detach P "$old" "$c"
    hook_attach P "$new" "$c"
    info "twin moved: $PEER_NAME/$(kind "$k")$old → $(label "$k" P)"
    echo "   $PEER_NAME/$(kind "$k")$old is no longer protected and is left as it is: delete it if you do not need it."
    if on P "$c status $new >/dev/null 2>&1"; then
      echo "   $(label "$k" P) already exists: the next replication toward $PEER_NAME OVERWRITES it."
    else
      echo "   The next replication toward $PEER_NAME creates $(label "$k" P)."
    fi
  fi
  info "$(vm_line "$k")"
  echo "   (link changes apply at the next standby / activation)"
}

cmd_list() {
  local k
  [ ${#VM_IDS[@]} -gt 0 ] || { echo "No protected VM."; return 0; }
  for k in $(printf '%s\n' "${VM_IDS[@]}" | sort -n); do vm_line "$k"; done
}

# =============================================================================
#  ACTIONS
# =============================================================================
cmd_status() {   # cmd_status [KEY]
  local k s g d keys=()
  echo "poorha $VERSION — on $NODE_NAME, peer $PEER_NAME ($PEER_IP)"
  for s in L P; do
    if on "$s" true 2>/dev/null; then
      if on "$s" "test -e $GUARD_OFF_FLAG"; then g=DISABLED; else g=enabled; fi
      if on "$s" "test -x $BIN && test -x $SNIPPET_DIR/$SNIPPET_NAME && test -r $CONF"; then d=yes; else d=NO; fi
      echo "  $(nname "$s"): guard $g, deployed: $d"
    else
      echo "  $(nname "$s"): UNREACHABLE"
    fi
  done
  echo
  [ ${#VM_IDS[@]} -gt 0 ] || { echo "  No protected VM — \"poorha select\" or \"poorha add\"."; return 0; }
  if [ -n "${1:-}" ]; then keys=("$1"); else mapfile -t keys < <(printf '%s\n' "${VM_IDS[@]}" | sort -n); fi
  for k in "${keys[@]}"; do
    echo "  ● $(vm_line "$k" | cut -d' ' -f2-)"
    for s in L P; do
      get_vm "$k" "$s"
      printf '    %-14s %-9s %s%s\n' "$(nname "$s")" "$(kind "$k")$(svmid "$k" "$s")" "$(role_txt)" "${VM_NAME:+   ($VM_NAME)}"
      if [ "$VM_EXISTS" = 1 ]; then
        nic_lines "$k"
        grep -qx "hookscript: $SNIPPET_REF" <<<"$VM_CONF" || echo "        hookscript NOT attached"
        [ "$(vtype "$k")" = lxc ] && mp_warnings "$VM_CONF" | sed 's/^/        /'
      fi
    done
    if [ -n "$(vget "$k" guard)" ]; then
      get_vm "$k" L
      [ "$VM_EXISTS" = 1 ] || get_vm "$k" P
      if ip_alive "$k" L; then echo "    guard IP $(vget "$k" guard) answers on the LAN"
      else echo "    guard IP $(vget "$k" guard) does NOT answer on the LAN"; fi
    fi
    echo
  done
}

# Rewrites the VM notes: drops any previous "poorha: " line, puts the new one first.
# Usage (on the destination host): perl - <vmid> '<note>'
read -r -d '' REMOTE_NOTE <<'EOS'
use strict; use warnings; use JSON::PP;
my ($vmid, $note, $type) = @ARGV;
$type = 'qemu' unless ($type // '') eq 'lxc';
chomp(my $node = `hostname -s`);
my $json = `pvesh get /nodes/$node/$type/$vmid/config --output-format json 2>/dev/null`;
my $cfg = eval { decode_json($json) } or die "cannot read the config of VM $vmid\n";
my $desc = $cfg->{description} // '';
my @keep = grep { !/^\s*poorha: / } split /\n/, $desc;
shift @keep while @keep && $keep[0] =~ /^\s*$/;
my $new = join "\n", $note, (@keep ? ('', @keep) : ());
utf8::encode($new);
exec(($type eq 'lxc' ? 'pct' : 'qm'), 'set', $vmid, '--description', $new);
EOS

cmd_replicate() {   # cmd_replicate KEY SRC DST [start=1]
  local k=$1 s=$2 d=$3 start=${4:-1} sv dv d_exists d_prot=0 d_lock warns="" msg mid t0 note dstore log mode c t w
  [ "$s" != "$d" ] || die "source and destination are the same"
  sv=$(svmid "$k" "$s"); dv=$(svmid "$k" "$d"); mode=$(vget "$k" standby); c=$(pcmd "$k"); t=$(vtype "$k")

  # Destination: never a copy in service
  get_vm "$k" "$d"
  [ "$VM_REACH" = 1 ] || die "$(nname "$d") is unreachable"
  is_active && die "$(label "$k" "$d") is ACTIVE — a VM in service is never overwritten. Put it on standby first."
  d_exists=$VM_EXISTS
  grep -qx 'protection: 1' <<<"$VM_CONF" && d_prot=1
  d_lock=$(sed -n 's/^lock: //p' <<<"$VM_CONF")
  [ -z "$d_lock" ] || die "$(label "$k" "$d") is locked ($d_lock) — wait for the task to finish, or \"$c unlock $dv\" on $(nname "$d")"
  on "$d" "test -x $BIN && test -r $CONF" || die "poorha is not deployed on $(nname "$d") — run \"poorha deploy\" first"
  dstore=$(on "$d" "$BIN _get STORAGE")

  # Source
  get_vm "$k" "$s"
  [ "$VM_REACH" = 1 ]  || die "$(nname "$s") is unreachable"
  [ "$VM_EXISTS" = 1 ] || die "source VM $sv is missing on $(nname "$s")"
  [ "$VM_RUN" = 1 ]    || warns+="  - the source VM is stopped\n"
  [ "$VM_LAN" = down ] && warns+="  - the source is NOT the active copy (links down)\n"
  if [ -n "$HEALTH_PING" ] && ! on "$s" "ping -c 2 -W 2 $HEALTH_PING >/dev/null 2>&1"; then
    warns+="  - $HEALTH_PING does not answer from $(nname "$s")\n"
  fi
  if [ "$t" = lxc ]; then
    while read -r w; do [ -n "$w" ] && warns+="  - $w\n"; done <<<"$(mp_warnings "$VM_CONF")"
  fi

  msg="Replication of ${VM_NAME:-guest $sv}:  $(label "$k" "$s")  →  $(label "$k" "$d")\nTarget storage: $dstore\n\nVM $dv on $(nname "$d") will be OVERWRITTEN."
  [ "$d_prot" = 1 ] && msg+="\nIts protection flag is lifted for the restore (the copy then gets the source's setting)."
  [ -n "$warns" ] && msg+="\n\nWARNING:\n$warns"
  confirm "$msg" || die "cancelled"

  if [ "$d_prot" = 1 ]; then
    info "lifting the protection of $(label "$k" "$d")"
    on "$d" "$c set $dv --protection 0 >/dev/null" || die "cannot lift the protection of $(label "$k" "$d")"
  fi
  if [ "$d_exists" = 1 ]; then
    info "stopping $(label "$k" "$d")"
    on "$d" "$c shutdown $dv --timeout 60 >/dev/null 2>&1 || $c stop $dv --skiplock 1 >/dev/null 2>&1; true"
  fi

  mid="cat"; command -v pv >/dev/null 2>&1 && mid="pv -f -b -r -t"
  log=$LOG_DIR/vzdump-$sv.log
  info "transfer: vzdump (snapshot) → zstd → ssh → $([ "$t" = lxc ] && echo "pct restore" || echo qmrestore) …"
  t0=$SECONDS
  # shellcheck disable=SC2086
  on "$s" "mkdir -p $LOG_DIR; set -o pipefail; vzdump $sv --mode snapshot --compress 0 --stdout 2>$log | zstd -T0 -3 -q" \
    | $mid \
    | on "$d" "$BIN _receive $dv $t"
  local rc=("${PIPESTATUS[@]}")
  if [ "${rc[0]}" != 0 ] || [ "${rc[2]}" != 0 ]; then
    die "transfer failed (exit codes ${rc[*]}). vzdump log: $log on $(nname "$s").
       Guest $dv on $(nname "$d") may be missing or incomplete: run the replication again."
  fi
  info "transfer done in $((SECONDS - t0)) s"

  info "post-restore of $(label "$k" "$d")"
  on "$d" "$c set $dv --onboot $([ "$mode" = hot ] && echo 1 || echo 0) --hookscript $SNIPPET_REF >/dev/null" \
    || warn "$c set (onboot/hookscript) failed on $(nname "$d")"
  note="poorha: replicated from $(label "$k" "$s") on $(date '+%F %T %Z')"
  on "$d" "perl - $dv '$note' $t >/dev/null" <<<"$REMOTE_NOTE" \
    || warn "could not write the replication note on $(label "$k" "$d")"
  links_set "$k" "$d" standby
  if [ "$mode" = hot ] && [ "$start" = 1 ]; then
    info "starting $(label "$k" "$d") on standby"
    on "$d" "$c start $dv" || warn "start refused — see Tasks on $(nname "$d")"
  fi
  echo
  info "replication OK: $(label "$k" "$d") is a copy of $(label "$k" "$s") as of $(date '+%F %T')"
}

cmd_replicate_all() {   # active → standby for every pair whose direction is clear
  local start=${1:-1} k dir plan=() msg="" ok=0 failed="" p oy
  for k in $(printf '%s\n' "${VM_IDS[@]}" | sort -n); do
    dir=$(auto_direction "$k")
    if [ -n "$dir" ]; then
      plan+=("$k $dir")
      get_vm "$k" "${dir% *}"
      msg+="  $(label "$k" "${dir% *}")  →  $(label "$k" "${dir#* }")   ${VM_NAME:-}\n"
    else
      msg+="  $(kind "$k")$k: skipped (no copy active, or both active)\n"
    fi
  done
  [ ${#plan[@]} -gt 0 ] || die "nothing to replicate: no pair has a single active copy"
  confirm "Replication active → standby:\n\n${msg}\nEach destination is OVERWRITTEN." || die "cancelled"
  oy=$YES; YES=1
  for p in "${plan[@]}"; do
    # shellcheck disable=SC2086
    set -- $p
    echo; info "=== $(kind "$1")$1 ==="
    if ( cmd_replicate "$1" "$2" "$3" "$start" ); then ok=$((ok + 1)); else failed+=" $(kind "$1")$1"; fi
  done
  YES=$oy
  echo
  info "$ok replication(s) OK${failed:+ — FAILED:$failed}"
  [ -z "$failed" ]
}

cmd_standby() {   # cmd_standby KEY SIDE
  local k=$1 s=$2 vid c; vid=$(svmid "$k" "$s"); c=$(pcmd "$k")
  get_vm "$k" "$s"
  [ "$VM_REACH" = 1 ]  || die "$(nname "$s") is unreachable"
  [ "$VM_EXISTS" = 1 ] || die "VM $vid is missing on $(nname "$s")"
  if is_active; then
    confirm "$(label "$k" "$s") is the ACTIVE copy.\nPutting it on standby takes it out of service.\n\nContinue?" || die "cancelled"
  fi
  links_set "$k" "$s" standby
  if [ "$(vget "$k" standby)" = hot ] && [ "$VM_LAN" != none ]; then
    on "$s" "$c set $vid --onboot 1 >/dev/null"
    info "$(label "$k" "$s") is on standby (hot: running, links down$( [ -n "$(vget "$k" keep)" ] && echo " except $(vget "$k" keep)"))"
  else
    get_vm "$k" "$s"
    if [ "$VM_RUN" = 1 ]; then
      info "shutting down $(label "$k" "$s")"
      on "$s" "$c shutdown $vid --timeout 120 >/dev/null 2>&1 || $c stop $vid >/dev/null 2>&1; true"
    fi
    on "$s" "$c set $vid --onboot 0 >/dev/null"
    info "$(label "$k" "$s") is on standby (stopped, links down)"
  fi
}

cmd_activate() {   # cmd_activate KEY SIDE [force=0]
  local k=$1 s=$2 force=${3:-0} p vid note c
  p=$(other "$s"); vid=$(svmid "$k" "$s"); c=$(pcmd "$k")
  get_vm "$k" "$s"
  [ "$VM_REACH" = 1 ]  || die "$(nname "$s") is unreachable"
  [ "$VM_EXISTS" = 1 ] || die "VM $vid is missing on $(nname "$s")"
  if is_active; then info "$(label "$k" "$s") is already active"; return 0; fi

  if [ "$force" != 1 ]; then
    if ip_alive "$k" "$s"; then
      die "$(vget "$k" guard) still answers on the LAN (seen from $(nname "$s")): a copy seems to be active.
       Activation cancelled — force (-f) if you are sure it is out of service."
    fi
    get_vm "$k" "$p"
    is_active && die "$(label "$k" "$p") is ACTIVE. Use the planned switchover, or force (-f) if it is out of service."
  fi

  note=$(activation_note "$k" "$s")
  confirm "Activate $(label "$k" "$s")?${note:+\n\nThen: $note}" || die "cancelled"
  links_set "$k" "$s" up
  on "$s" "$c set $vid --onboot 1 >/dev/null"
  get_vm "$k" "$s"
  if [ "$VM_RUN" = 0 ]; then
    info "starting $(label "$k" "$s")"
    on "$s" "$c start $vid" || die "start refused (guard?) — see Tasks on $(nname "$s")"
  fi
  echo
  info "$(label "$k" "$s") is now active."
  [ -n "$note" ] && echo "   → $note"
  return 0
}

switch_rollback() {   # switch_rollback KEY SIDE — a switchover failed: SIDE goes back into service
  warn "switchover failed — putting $(label "$1" "$2") back into service"
  ( cmd_activate "$1" "$2" 1 ) || warn "could not restore $(label "$1" "$2") — check it by hand"
  die "switchover aborted"
}

cmd_switch() {   # cmd_switch KEY SIDE [yes|no|ask] — planned switchover to SIDE
  local k=$1 n=$2 rep=${3:-ask} p oy do_rep=0 mode ln lp
  p=$(other "$n"); mode=$(vget "$k" standby); ln=$(label "$k" "$n"); lp=$(label "$k" "$p")
  get_vm "$k" "$n"; [ "$VM_REACH" = 1 ] || die "$(nname "$n") is unreachable"
  is_active && { info "$ln is already active"; return 0; }
  get_vm "$k" "$p"
  [ "$VM_REACH" = 1 ] || die "$(nname "$p") is unreachable — use the emergency activation instead"

  if is_active; then
    if [ "$rep" = yes ] || { [ "$rep" = ask ] && confirm "Replicate $lp → $ln during the switchover?\n\n(recommended: $(nname "$n") takes over with exactly the current state)"; }; then
      do_rep=1
    fi
  fi

  if [ "$do_rep" = 1 ] && [ "$mode" = cold ]; then
    # Stop first, then copy: nothing written by the source is lost.
    confirm "Planned switchover:\n\n  1. $lp → standby (shut down)\n  2. replication $lp → $ln\n  3. $ln → active\n\nThe service is down during the transfer." || die "cancelled"
    trap '' HUP   # if the SSH session goes through this VM it drops here: finish anyway
    oy=$YES; YES=1
    ( cmd_standby "$k" "$p" )         || switch_rollback "$k" "$p"
    ( cmd_replicate "$k" "$p" "$n" 0 ) || switch_rollback "$k" "$p"
    ( cmd_activate "$k" "$n" 0 )       || switch_rollback "$k" "$p"
    YES=$oy
  elif [ "$mode" = cold ]; then
    # No copy to make: cut the source, bring up the twin, shut the source down last.
    confirm "Planned switchover:\n\n  1. $lp → links cut\n  2. $ln → active (started)\n  3. $lp → shut down (standby)\n\nThe service is cut while $ln starts." || die "cancelled"
    trap '' HUP
    oy=$YES; YES=1
    ( links_set "$k" "$p" standby ) || switch_rollback "$k" "$p"
    sleep 2   # lets the cut propagate before the activation checks the guard IP
    ( cmd_activate "$k" "$n" 0 )     || switch_rollback "$k" "$p"
    cmd_standby "$k" "$p"
    YES=$oy
  else
    [ "$do_rep" = 1 ] && cmd_replicate "$k" "$p" "$n" 1
    confirm "Planned switchover:\n\n  1. $lp → standby (links cut, stays running)\n  2. $ln → active\n\nThe service is cut for a few seconds." || die "cancelled"
    trap '' HUP
    oy=$YES; YES=1
    ( cmd_standby "$k" "$p" )    || switch_rollback "$k" "$p"
    sleep 2
    ( cmd_activate "$k" "$n" 0 ) || switch_rollback "$k" "$p"
    YES=$oy
  fi
  echo
  info "switchover done: $ln is active, $lp is on standby"
}

cmd_guard() {   # cmd_guard SIDE on|off
  case "$2" in
    on)  on "$1" "rm -f $GUARD_OFF_FLAG" && info "guard ENABLED on $(nname "$1")" ;;
    off) on "$1" "mkdir -p $CONF_DIR && touch $GUARD_OFF_FLAG" \
           && info "guard DISABLED on $(nname "$1") for every VM — remember to enable it again" ;;
    *)   die "unknown guard action: $2 (on|off|test)" ;;
  esac
}

cmd_guard_test() {   # cmd_guard_test KEY SIDE
  local rc
  info "simulation: \"what would happen if $(label "$1" "$2") were started now?\""
  on "$2" "$SNIPPET_DIR/$SNIPPET_NAME $(svmid "$1" "$2") pre-start"; rc=$?
  if [ "$rc" = 0 ]; then info "result: start ALLOWED"; else info "result: start BLOCKED"; fi
}

# ------------------------------------------------------------- deployment ----
read -r -d '' REMOTE_PKGS <<'EOS'
need=""
for c in arping:iputils-arping whiptail:whiptail zstd:zstd; do
  command -v "${c%%:*}" >/dev/null 2>&1 || need="$need ${c#*:}"
done
if [ -n "$need" ]; then
  echo "   installing:$need"
  DEBIAN_FRONTEND=noninteractive apt-get install -y -q $need >/dev/null || { echo "   apt-get failed"; exit 1; }
else
  echo "   packages OK (arping, whiptail, zstd)"
fi
EOS

read -r -d '' REMOTE_SNIPPETS <<'EOS'
c=$(awk '/^dir: local$/{f=1;next} f&&/^[a-z]+: /{f=0} f&&$1=="content"{print $2}' /etc/pve/storage.cfg)
case ",$c," in
  *,snippets,*) echo "   local storage: snippets OK" ;;
  *) pvesm set local --content "${c:-images,rootdir},snippets" && echo "   local storage: \"snippets\" content type added" ;;
esac
EOS

pull_entry() {   # pull_entry KEY peer=PV key=value… — an entry known only by the peer
  local k=$1; shift
  if has_vm "$k"; then
    [ "peer=$(vget "$k" peer)" = "$1" ] \
      || warn "vm$k: conflicting pairs (here: peer=$(vget "$k" peer), on $PEER_NAME: $1) — this node's entry wins"
    return 1
  fi
  vm_set "$k" "$@"
}

sync_pairs() {   # union of both configs (this node wins on conflict), then mirror everything
  local line k n=0
  while read -r line; do
    [ -n "$line" ] || continue
    eval "pull_entry $line" && n=$((n + 1))
  done < <(on P "$BIN _dump-vms")
  [ "$n" = 0 ] || { write_conf; echo "   $n pair(s) imported from $PEER_NAME"; }
  for k in "${VM_IDS[@]}"; do save_vm "$k"; done
  echo "   ${#VM_IDS[@]} pair(s) in sync on both hosts"
}

cmd_deploy() {
  local pk k sts st
  [ -n "$PEER_IP" ] && [ -n "$NODE_IP" ] || die "NODE_IP / PEER_IP missing — run \"poorha config\""

  confirm "Deployment on $NODE_NAME and $PEER_NAME:\n\n  - root SSH keys both ways (password of $PEER_NAME asked once if needed)\n  - packages: arping, whiptail, zstd\n  - $BIN and $SNIPPET_DIR/$SNIPPET_NAME\n  - the config of $PEER_NAME (created if missing, identity updated)\n  - \"snippets\" content type on the local storage\n  - protected VMs synced between both configs, hookscript attached" || die "cancelled"

  PEER_DOWN=0
  info "1/5 SSH keys"
  [ -f /root/.ssh/id_ed25519 ] || ssh-keygen -q -t ed25519 -N '' -f /root/.ssh/id_ed25519
  if ! ssh "${SSH_BASE[@]}" "root@$PEER_IP" true 2>/dev/null; then
    info "   copying the key of $NODE_NAME to $PEER_NAME — root password of $PEER_NAME:"
    ssh-copy-id -o StrictHostKeyChecking=accept-new -i /root/.ssh/id_ed25519.pub "root@$PEER_IP" || die "ssh-copy-id failed"
  fi
  on P true || die "SSH $NODE_NAME → $PEER_NAME does not work"
  pk=$(on P "[ -f /root/.ssh/id_ed25519 ] || ssh-keygen -q -t ed25519 -N '' -f /root/.ssh/id_ed25519; cat /root/.ssh/id_ed25519.pub")
  [ -n "$pk" ] || die "cannot read the public key of $PEER_NAME"
  grep -qF "$pk" /root/.ssh/authorized_keys 2>/dev/null || echo "$pk" >>/root/.ssh/authorized_keys
  on P "ssh ${SSH_BASE[*]} root@$NODE_IP true" || die "SSH $PEER_NAME → $NODE_NAME does not work"
  info "   SSH OK both ways"

  info "2/5 packages"
  for k in L P; do echo "   [$(nname "$k")]"; on "$k" "$REMOTE_PKGS" || die "packages: failed on $(nname "$k")"; done

  info "3/5 files and storage"
  mkdir -p "$SNIPPET_DIR" "$CONF_DIR" "$LOG_DIR"
  [ "$SELF" = "$BIN" ] || install -m 755 "$SELF" "$BIN"
  [ "$SELF" = "$SNIPPET_DIR/$SNIPPET_NAME" ] || install -m 755 "$SELF" "$SNIPPET_DIR/$SNIPPET_NAME"
  on P "mkdir -p $SNIPPET_DIR $CONF_DIR $LOG_DIR && cat > $BIN.tmp && chmod 755 $BIN.tmp && mv $BIN.tmp $BIN && install -m 755 $BIN $SNIPPET_DIR/$SNIPPET_NAME" <"$SELF" \
    || die "copying the script to $PEER_NAME failed"
  echo "   poorha $VERSION installed on both hosts"
  for k in L P; do echo "   [$(nname "$k")]"; on "$k" "$REMOTE_SNIPPETS" || die "storage: failed on $(nname "$k")"; done

  info "4/5 config of $PEER_NAME"
  if on P "test -r $CONF"; then
    on P "$(qcmd "$BIN" _set-identity "NODE_NAME=$PEER_NAME" "NODE_IP=$PEER_IP" "PEER_NAME=$NODE_NAME" "PEER_IP=$NODE_IP")" \
      || die "updating the config of $PEER_NAME failed"
    echo "   existing config kept (identity updated, storage: $(on P "$BIN _get STORAGE"))"
  else
    sts=$(on P "pvesm status --content images 2>/dev/null | awk 'NR>1{print \$1}'")
    if grep -qx "$STORAGE" <<<"$sts"; then st=$STORAGE; else st=$(head -n1 <<<"$sts"); fi
    if [ "$TUI" = 1 ] && [ -n "$sts" ]; then
      local items=() x
      for x in $sts; do items+=("$x" ""); done
      st=$(whiptail --title "poorha deploy" --default-item "$st" --menu \
        "Storage of $PEER_NAME that will receive the replications:" 16 70 6 "${items[@]}" 3>&1 1>&2 2>&3) || die "cancelled"
    fi
    [ -n "$st" ] || die "no storage for VM images found on $PEER_NAME"
    on P "$(qcmd "$BIN" _set-identity "NODE_NAME=$PEER_NAME" "NODE_IP=$PEER_IP" "PEER_NAME=$NODE_NAME" "PEER_IP=$NODE_IP" \
            "STORAGE=$st" "REF_IP=$REF_IP" "GUARD_TRIES=$GUARD_TRIES" "HEALTH_PING=$HEALTH_PING" "TMP_DIR=$TMP_DIR")" \
      || die "creating the config of $PEER_NAME failed"
    echo "   config created (storage: $st)"
  fi

  info "5/5 protected VMs"
  sync_pairs
  for k in "${VM_IDS[@]}"; do hook_attach L "$k" "$(pcmd "$k")"; hook_attach P "$(vget "$k" peer)" "$(pcmd "$k")"; done
  [ ${#VM_IDS[@]} -eq 0 ] || echo "   hookscript attached to the existing guests"
  echo
  info "deployment done"
}

# ---------------------------------------------------- import from opnha ----
cmd_import_opnha() {
  local f=/etc/opnsense-ha/ha.conf me ot lv pv wan h
  [ -r "$f" ] || die "$f not found"
  local NODE_A_NAME NODE_A_IP NODE_A_VMID NODE_A_STORAGE NODE_B_NAME NODE_B_IP NODE_B_VMID NODE_B_STORAGE
  local WAN_BRIDGE GW_IP o_ref o_ping
  # shellcheck source=/dev/null
  o_ref=$(. "$f"; echo "${REF_IP:-}")
  # shellcheck source=/dev/null
  o_ping=$(. "$f"; echo "${HEALTH_PING:-}")
  eval "$(. "$f"; declare -p NODE_A_NAME NODE_A_IP NODE_A_VMID NODE_A_STORAGE NODE_B_NAME NODE_B_IP NODE_B_VMID NODE_B_STORAGE WAN_BRIDGE GW_IP 2>/dev/null | sed 's/^declare -- //')"
  h=$(hostname -s)
  if [ "$h" = "$NODE_A_NAME" ]; then me=A; ot=B; elif [ "$h" = "$NODE_B_NAME" ]; then me=B; ot=A
  else die "this host ($h) is neither $NODE_A_NAME nor $NODE_B_NAME in $f"; fi
  lv=$(eval echo "\$NODE_${me}_VMID"); pv=$(eval echo "\$NODE_${ot}_VMID")

  if ! load_conf; then
    NODE_NAME=$h
    NODE_IP=$(eval echo "\$NODE_${me}_IP")
    PEER_NAME=$(eval echo "\$NODE_${ot}_NAME"); PEER_IP=$(eval echo "\$NODE_${ot}_IP")
    STORAGE=$(eval echo "\$NODE_${me}_STORAGE")
    REF_IP=$o_ref; HEALTH_PING=$o_ping
    defaults
  fi
  has_vm "$lv" && die "vm$lv is already protected by poorha"
  wan=$(qm config "$lv" 2>/dev/null | grep -E "^net[0-9]+:.*bridge=${WAN_BRIDGE}(,|$)" | head -n1 | cut -d: -f1)
  [ -n "$wan" ] || die "no NIC of VM $lv on the WAN bridge $WAN_BRIDGE"
  vm_set "$lv" "peer=$pv" standby=hot "keep=$wan" "guard=$GW_IP" "ref=$o_ref" "note=$ROUTER_NOTE"
  write_conf
  info "imported: $(vm_line "$lv")"
  echo "   Next: \"poorha deploy\" (creates the config on $PEER_NAME and replaces the opnha hookscript)."
  echo "   opnha can then be removed from both hosts:"
  echo "     rm -rf /usr/local/sbin/opnha $SNIPPET_DIR/opnha-guard.sh /etc/opnsense-ha"
}

# ------------------------------------------------------ configuration wizard --
cmd_config() {
  have_tui || die "interactive wizard unavailable (no terminal or whiptail missing) — edit $CONF"
  TUI=1
  load_conf || defaults
  local sts items=() x
  NODE_IP=${NODE_IP:-$(hostname -I 2>/dev/null | awk '{print $1}')}

  ask_in() {   # ask_in VAR "question"
    local __v
    __v=$(whiptail --title "poorha configuration" --inputbox "$2" 11 72 "${!1}" 3>&1 1>&2 2>&3) || return 1
    printf -v "$1" '%s' "$__v"
  }

  whiptail --title "poorha configuration" --msgbox "This wizard configures THIS node ($NODE_NAME) and names its peer.\n\nThe peer's own config is created by \"Deploy\". Protected VMs are chosen afterwards with \"Select VMs\"." 12 72

  ask_in NODE_NAME "This host's name (hostname -s)"                     || return 1
  ask_in NODE_IP   "This host's IP on the MGMT link (the peer connects to it)" || return 1
  ask_in PEER_NAME "Peer host name (hostname -s)"                       || return 1
  ask_in PEER_IP   "Peer IP on the MGMT link"                           || return 1
  sts=$(pvesm status --content images 2>/dev/null | awk 'NR>1{print $1}')
  if [ -n "$sts" ]; then
    for x in $sts; do items+=("$x" ""); done
    STORAGE=$(whiptail --title "poorha configuration" --default-item "$STORAGE" --menu \
      "Storage of THIS host that receives the replications:" 16 72 6 "${items[@]}" 3>&1 1>&2 2>&3) || return 1
  else
    ask_in STORAGE "Storage of THIS host that receives the replications" || return 1
  fi
  ask_in REF_IP      "Always-on LAN device (a switch) — lets the guard decide quickly.\nEmpty: none (each guarded start then waits ~3 s)" || return 1
  ask_in HEALTH_PING "Optional: IP pinged from the source host before a replication\n(e.g. 1.1.1.1). Empty: no check" || return 1
  [ -n "$PEER_NAME" ] && [ -n "$PEER_IP" ] && [ -n "$NODE_IP" ] || { whiptail --msgbox "Host names and IPs are required." 8 50; return 1; }

  write_conf
  whiptail --title "poorha configuration" --msgbox "Configuration saved to $CONF.\n\nNext: \"Deploy\", then \"Select VMs\"." 10 70
}

# =============================================================================
#  WHIPTAIL MENU
# =============================================================================
declare -A ROW=() ROLE=() ACT=()   # per KEY: table row, ROLE[KEY.SIDE] = role_txt, ACT = "L P" | "P L" | ""
ROW_FMT='%-14.14s %-7.7s %-7.7s %-11.11s  %-7.7s %-7.7s %-11.11s'

pause() { echo; read -r -p "Press Enter to return to the menu… " _; }
run_action() { clear; ( "$@" ); pause; }

wait_box() {   # a "please wait" box instead of the bare shell while poorha works
  [ "$TUI" = 1 ] && TERM=ansi whiptail --title "poorha" --infobox "$1" 7 60
  return 0
}

run_quick() {   # run_quick "title" cmd… — short action without prompt: result in a box, no shell screen
  local t=$1 f h; shift
  f=$(mktemp)
  wait_box "Working…"
  ( "$@" ) >"$f" 2>&1 || echo "(failed)" >>"$f"
  [ -s "$f" ] || echo "done" >"$f"
  h=$(( $(wc -l <"$f") + 7 )); [ "$h" -lt 9 ] && h=9; [ "$h" -gt 24 ] && h=24
  whiptail --title "$t" --scrolltext --textbox "$f" "$h" 78
  rm -f "$f"
}

table_head() {   # the two header lines of the pair tables
  printf '%-14s %-27s  %s\n' "" "SOURCE (active)" "DESTINATION (standby)"
  # shellcheck disable=SC2059
  printf "$ROW_FMT" VM HOST VMID STATUS HOST VMID STATUS
}

refresh_rows() {   # 2 round trips in all, whatever the number of pairs
  local k a b ra rb name
  ROW=(); ROLE=(); ACT=()
  probe_all L; probe_all P
  for k in "${VM_IDS[@]}"; do
    get_vm_cached "$k" L; ROLE[$k.L]=$(role_txt); ra=$(role_short); name=$VM_NAME; is_active && a=1 || a=0
    get_vm_cached "$k" P; ROLE[$k.P]=$(role_txt); rb=$(role_short); name=${name:-$VM_NAME}; is_active && b=1 || b=0
    if [ "$a" = 1 ] && [ "$b" = 0 ]; then ACT[$k]="L P"
    elif [ "$b" = 1 ] && [ "$a" = 0 ]; then ACT[$k]="P L"; fi
    # the active copy on the left; the local one when neither (or both) is active
    if [ "${ACT[$k]:-}" = "P L" ]; then
      # shellcheck disable=SC2059
      ROW[$k]=$(printf "$ROW_FMT" "${name:-?}" "$PEER_NAME" "$(kind "$k")$(svmid "$k" P)" "$rb" "$NODE_NAME" "$(kind "$k")$k" "$ra")
    else
      # shellcheck disable=SC2059
      ROW[$k]=$(printf "$ROW_FMT" "${name:-?}" "$NODE_NAME" "$(kind "$k")$k" "$ra" "$PEER_NAME" "$(kind "$k")$(svmid "$k" P)" "$rb")
    fi
  done
}

pick_vm() {   # pick_vm "title" [all] → KEY | all
  local items=() k
  [ ${#VM_IDS[@]} -gt 0 ] || { whiptail --title poorha --msgbox "No protected VM yet — use \"Select VMs\" first." 8 60; return 1; }
  [ "${2:-}" = all ] && items+=(all "every protected VM (direction: active → standby)")
  for k in $(printf '%s\n' "${VM_IDS[@]}" | sort -n); do items+=("$k" "${ROW[$k]}"); done
  whiptail --title poorha --menu "$1\n\n$(table_head | sed 's/^/       /')" 22 82 12 "${items[@]}" 3>&1 1>&2 2>&3
}

pick_side() {   # pick_side "title" KEY → L|P   (roles from the last refresh_rows)
  whiptail --title poorha --menu "$1" 14 72 2 \
    L "$(label "$2" L)  [${ROLE[$2.L]:-?}]" P "$(label "$2" P)  [${ROLE[$2.P]:-?}]" 3>&1 1>&2 2>&3
}

tui_select() {
  local items=() list k s id name st t c sel pre adds=() removes=() msg="" o pick v dup
  local -A NAMEOF=() OID=() OTAKEN=()
  wait_box "Listing the VMs and containers of both nodes…"
  list=$(candidates)
  pre=OFF; [ ${#VM_IDS[@]} -eq 0 ] && pre=ON   # first time: everything is preselected
  for k in $(printf '%s\n' "${VM_IDS[@]}" | sort -n); do
    items+=("K$k" "$(printf '%-16.16s %s ↔ %s' "$(cut -c1-16 <<<"${ROW[$k]}" | sed 's/ *$//')" "$(label "$k" L)" "$(label "$k" P)")" ON)
  done
  while read -r s id name st t; do
    [ -n "$id" ] || continue
    NAMEOF[$s$id]=$name
    items+=("$s$id" "$(printf '%-16.16s %s/%s only (%s)%s' "$name" "$(nname "$s")" "$id" "$st" "$([ "$t" = lxc ] && echo "  [CT]")")" "$pre")
  done <<<"$list"
  [ ${#items[@]} -gt 0 ] || { whiptail --title poorha --msgbox "No VM or container found on either node." 8 50; return 0; }

  sel=$(whiptail --title "Protected guests" --separate-output --checklist \
    "Checked VMs / containers [CT] get a twin on the other node (created by the\nfirst replication). Unchecking stops the protection; nothing is deleted." \
    22 78 13 "${items[@]}" 3>&1 1>&2 2>&3) || return 0

  for k in "${VM_IDS[@]}"; do grep -qx "K$k" <<<"$sel" || { removes+=("$k"); msg+="  − $(label "$k" L) ↔ $(label "$k" P)\n"; }; done
  mapfile -t adds < <(grep -E '^[LP][0-9]+$' <<<"$sel")

  # vmid of each new twin: proposed (same vmid if free, else the next free one), editable
  if [ ${#adds[@]} -gt 0 ]; then
    RESERVED=""
    wait_box "Looking for free vmids…"
    USED=(); load_used L; load_used P
    for c in "${adds[@]}"; do
      o=$(other "${c:0:1}")
      OID[$c]=$(pick_free "$o" "${c:1}") || OID[$c]=""
      RESERVED+=" $o${OID[$c]}"
    done
    while true; do
      items=(ok "→ continue with these vmids")
      for c in "${adds[@]}"; do
        o=$(other "${c:0:1}")
        items+=("$c" "$(printf '%-16.16s %s/%s → %s/%s%s' "${NAMEOF[$c]}" "$(nname "${c:0:1}")" "${c:1}" "$(nname "$o")" "${OID[$c]:-?}" "${OTAKEN[$c]:+  EXISTS: overwritten}")")
      done
      pick=$(whiptail --title "Twin vmids" --menu \
        "vmid of each new twin on the other node. Select a line to change it." \
        20 78 11 "${items[@]}" 3>&1 1>&2 2>&3) || return 0
      [ "$pick" = ok ] && break
      o=$(other "${pick:0:1}")
      v=$(whiptail --title "Twin vmids" --inputbox \
        "vmid on $(nname "$o") of the twin of $(nname "${pick:0:1}")/${pick:1} (${NAMEOF[$pick]}):" 10 70 "${OID[$pick]}" 3>&1 1>&2 2>&3) || continue
      if ! [[ "$v" =~ ^[0-9]+$ ]] || [ "$v" -lt 100 ]; then
        whiptail --msgbox "A vmid is a number ≥ 100." 8 40; continue
      fi
      dup=0
      for c in "${adds[@]}"; do
        [ "$c" != "$pick" ] && [ "$(other "${c:0:1}")" = "$o" ] && [ "${OID[$c]}" = "$v" ] && dup=1
      done
      if [ "$dup" = 1 ] || vmid_used_conf "$o" "$v"; then
        whiptail --msgbox "vmid $v on $(nname "$o") already belongs to another pair." 8 60; continue
      fi
      OID[$pick]=$v; OTAKEN[$pick]=""
      [[ "${USED[$o]:-}" == *" $v "* ]] && OTAKEN[$pick]=1
    done
    for c in "${adds[@]}"; do
      [ -n "${OID[$c]}" ] || { whiptail --msgbox "No vmid for $(nname "${c:0:1}")/${c:1}." 8 50; return 0; }
      o=$(other "${c:0:1}")
      msg+="  + $(nname "${c:0:1}")/${c:1} → $(nname "$o")/${OID[$c]}${OTAKEN[$c]:+   (EXISTS: overwritten at the first replication)}\n"
    done
  fi
  [ -n "$msg" ] || return 0
  confirm "Changes:\n\n$msg" || return 0
  run_quick "Protected guests" apply_selection "${removes[@]}" -- $(for c in "${adds[@]}"; do echo "$c:${OID[$c]}"; done)
}

apply_selection() {   # apply_selection KEY… -- SIDEVMID:TWINVMID…
  local a phase=rm
  RESERVED=""
  for a in "$@"; do
    if [ "$a" = "--" ]; then phase=add; continue; fi
    if [ "$phase" = rm ]; then pair_remove "$a"
    else a=${a%:}; pair_add "${a:0:1}" "$(cut -d: -f1 <<<"${a:1}")" "$( [[ "$a" == *:* ]] && echo "${a#*:}")"; fi
  done
  echo
  info "use \"VM settings\" for a router (hot standby, WAN kept up) or to set a guard IP"
}

tui_settings() {
  local k c v s nets items=() net br
  k=$(pick_vm "Settings of which VM?") || return 0
  while true; do
    c=$(whiptail --title "Settings — $(label "$k" L) ↔ $(label "$k" P)" --menu "Saved on both nodes with \"save\"." 20 78 9 \
      standby  "standby mode:  $(vget "$k" standby)   (cold = stopped, hot = running)" \
      keep     "NICs kept up on standby:  $(vget "$k" keep)" \
      guard    "guard IP:  $(vget "$k" guard)" \
      ref      "reference IP:  $(vget "$k" ref)   (empty: $REF_IP)" \
      twin     "twin vmid on $PEER_NAME:  $(vget "$k" peer)   (applied at once)" \
      note     "note after activation:  $(vget "$k" note)" \
      router   "→ router profile (hot standby, WAN NIC kept up)" \
      standard "→ standard profile (cold standby, nothing kept up)" \
      save     "SAVE" \
      cancel   "cancel" 3>&1 1>&2 2>&3) || c=cancel
    case "$c" in
      standby)  v=$(whiptail --menu "Standby mode" 12 60 2 cold "stopped, links down" hot "running, links down" 3>&1 1>&2 2>&3) && vm_set "$k" "standby=$v" ;;
      guard|ref|note)
                v=$(whiptail --inputbox "$c" 10 72 "$(vget "$k" "$c")" 3>&1 1>&2 2>&3) && { ( vm_set "$k" "$c=$v" ) 2>/dev/null && vm_set "$k" "$c=$v" || whiptail --msgbox "Invalid value." 8 40; } ;;
      keep|router)
                s=L; get_vm "$k" L; [ "$VM_EXISTS" = 1 ] || { s=P; get_vm "$k" P; }
                nets=$(grep -E '^net[0-9]+: ' <<<"$VM_CONF")
                [ -n "$nets" ] || { whiptail --msgbox "No NIC found." 8 40; continue; }
                items=()
                while read -r net; do
                  br=$(grep -oE 'bridge=[^,]+' <<<"$net" | cut -d= -f2); net=${net%%:*}
                  if [ "$c" = keep ]; then items+=("$net" "$br" "$(is_kept "$net" "$(vget "$k" keep)" && echo ON || echo OFF)")
                  else items+=("$net" "$br"); fi
                done <<<"$nets"
                if [ "$c" = keep ]; then
                  v=$(whiptail --separate-output --checklist "NICs that stay connected on standby" 16 60 8 "${items[@]}" 3>&1 1>&2 2>&3) \
                    && vm_set "$k" "keep=$(paste -sd, - <<<"$v")"
                else
                  v=$(whiptail --menu "Which NIC is the WAN (kept up on standby)?" 16 60 8 "${items[@]}" 3>&1 1>&2 2>&3) \
                    && vm_set "$k" standby=hot "keep=$v" "note=$( [ -n "$(vget "$k" note)" ] && vget "$k" note || echo "$ROUTER_NOTE")"
                fi ;;
      standard) vm_set "$k" standby=cold keep= note= ;;
      twin)     v=$(whiptail --inputbox "New vmid on $PEER_NAME for the twin of $(label "$k" L).\nThe old twin is left untouched (no longer protected)." 11 72 "$(vget "$k" peer)" 3>&1 1>&2 2>&3) || continue
                [ "$v" = "$(vget "$k" peer)" ] && continue
                load_conf   # discard unsaved edits: cmd_set saves the entry as it is on disk
                run_quick "Twin vmid" cmd_set "$k" "peer=$v"; return 0 ;;
      save)     run_quick "Settings" save_vm "$k"; return 0 ;;
      cancel)   return 0 ;;
    esac
  done
}

tui_replicate() {
  local k dir def
  k=$(pick_vm "Replicate which VM?" all) || return 0
  if [ "$k" = all ]; then run_action cmd_replicate_all 1; return 0; fi
  if [ "${ACT[$k]:-}" = "P L" ]; then def=PL; else def=LP; fi
  dir=$(whiptail --title "Replication" --default-item "$def" --menu \
    "Choose the direction. The destination is OVERWRITTEN.\n(recommended direction preselected: active → standby)" 14 72 2 \
    LP "$(label "$k" L)  →  $(label "$k" P)" \
    PL "$(label "$k" P)  →  $(label "$k" L)" 3>&1 1>&2 2>&3) || return 0
  run_action cmd_replicate "$k" "${dir:0:1}" "${dir:1:1}" 1
}

tui_guard() {
  local act s k
  act=$(whiptail --title "Guard" --menu "Action" 13 72 3 \
    test "Simulate the start of a VM" \
    off  "Disable on a node (maintenance)" \
    on   "Enable again on a node" 3>&1 1>&2 2>&3) || return 0
  if [ "$act" = test ]; then
    k=$(pick_vm "Guard test: which VM?") || return 0
    s=$(pick_side "Guard test: which copy?" "$k") || return 0
    run_quick "Guard test" cmd_guard_test "$k" "$s"
  else
    s=$(whiptail --title "Guard" --menu "Which node?" 12 60 2 L "$NODE_NAME" P "$PEER_NAME" 3>&1 1>&2 2>&3) || return 0
    run_quick "Guard" cmd_guard "$s" "$act"
  fi
}

tui_help() {
  local f; f=$(mktemp)
  cat >"$f" <<EOF
poorha $VERSION — poor man's HA for Proxmox VMs and containers, two hosts

PRINCIPLE
  Each protected VM or container (CT) has a twin on the other node: an exact copy (same
  MACs). The ACTIVE copy runs with its NICs connected. The other is on
  STANDBY: NICs link_down=1 (except "keep"), stopped (cold) or running
  (hot). No conflict is possible as long as only one is connected.

REPLICATION (active → standby)
  The destination is overwritten, then put back on standby. Never onto
  an active copy. Source and date go into the notes of the copy.

EMERGENCY ACTIVATION (the node of the active copy is dead)
  "Activate" on the surviving node. Refused if the guard IP still
  answers or if the other copy is active (force from the CLI: -f).

PLANNED SWITCHOVER (both nodes alive)
  cold + replication: active → standby (shut down) → replication →
        activate the other. Nothing written is lost; down during the copy.
  cold, no replication: cut the active → activate the other → shut the
        old one down. Down only while the twin boots.
  hot:  [replication] → active to standby (keeps running) → activate.
  If a step fails, the old copy is put back into service.

CONTAINERS
  Same as VMs (pct instead of qm). Bind mounts and mount points without
  backup=1 are NOT replicated: poorha warns about them.

GUARD
  pre-start hookscript on every protected VM: blocks the start of a copy
  whose links are up if its twin is active on the peer, or if its guard
  IP already answers on the LAN.

ROUTER (OPNsense…)
  "VM settings" → router profile: hot standby, WAN NIC kept up so that
  PPPoE comes up as soon as the fiber is plugged in.

CLI
  poorha status [VM]                      poorha list
  poorha select                           poorha add VMID|all [NODE] [key=value…]
  poorha remove VM                        poorha set VM key=value…
  poorha replicate [VM|all] [--to NODE] [--no-start] [-y]
  poorha activate VM NODE [-f] [-y]       poorha standby VM NODE [-y]
  poorha switch VM NODE [--replicate|--no-replicate] [-y]
  poorha guard on|off NODE                poorha guard test VM NODE
  poorha deploy [-y]                      poorha config
  poorha import-opnha
  VM = local vmid, peer vmid or name     NODE = $NODE_NAME | $PEER_NAME
  keys: peer standby(cold|hot) keep(netX,…) guard ref note profile(standard|router)
EOF
  whiptail --title "Help" --scrolltext --textbox "$f" 30 78
  rm -f "$f"
}

tui_main() {
  TUI=1
  local choice hdr k n s h rows=""
  while true; do
    load_conf || die "configuration lost ($CONF)"
    wait_box "Reading the state of $NODE_NAME and $PEER_NAME…"
    peer_probe
    refresh_rows
    rows=""
    for k in $(printf '%s\n' "${VM_IDS[@]}" | sort -n); do rows+=$'\n'"  ${ROW[$k]}"; done
    [ -n "$rows" ] || rows=$'\n  (no protected VM yet: "Select VMs")'
    hdr="On $NODE_NAME, peer $PEER_NAME$( [ "$PEER_DOWN" = 1 ] && printf '\n!! %s is UNREACHABLE' "$PEER_NAME")$(m=$(version_mismatch) && printf '\n!! %s' "$m")"
    hdr+=$'\n\n'"$(table_head | sed 's/^/  /')$rows"
    h=$(( $(wc -l <<<"$hdr") + 20 )); n=$(tput lines 2>/dev/null || echo 40); [ "$h" -gt "$n" ] && h=$n
    choice=$(whiptail --title "poorha $VERSION" --menu "$hdr" "$h" 80 12 \
      status    "Detailed status" \
      replicate "Replicate a VM (or all) onto its twin" \
      switch    "Planned switchover of a VM" \
      activate  "Emergency activation of a copy" \
      standby   "Put a copy on standby" \
      select    "Select VMs: choose the protected VMs / containers" \
      settings  "VM settings (router profile, guard IP…)" \
      guard     "Guard: test / disable / enable" \
      deploy    "Deploy / update on both hosts" \
      config    "Configuration wizard (this node)" \
      help      "Help" \
      quit      "Quit" 3>&1 1>&2 2>&3) || break
    case "$choice" in
      status)    s=$(mktemp); cmd_status >"$s" 2>&1
                 whiptail --title "Status" --scrolltext --textbox "$s" 30 78; rm -f "$s" ;;
      replicate) tui_replicate ;;
      switch)    k=$(pick_vm "Planned switchover: which VM?") && s=$(pick_side "Which copy should become ACTIVE?" "$k") && run_action cmd_switch "$k" "$s" ask ;;
      activate)  k=$(pick_vm "Emergency activation: which VM?") && s=$(pick_side "Activate which copy?" "$k") && run_action cmd_activate "$k" "$s" 0 ;;
      standby)   k=$(pick_vm "Standby: which VM?") && s=$(pick_side "Put which copy on standby?" "$k") && run_action cmd_standby "$k" "$s" ;;
      select)    tui_select ;;
      settings)  tui_settings ;;
      guard)     tui_guard ;;
      deploy)    run_action cmd_deploy ;;
      config)    cmd_config ;;
      help)      tui_help ;;
      quit)      break ;;
    esac
  done
  clear
}

# =============================================================================
#  ENTRY POINT
# =============================================================================
usage() {
  cat <<EOF
poorha $VERSION — poor man's HA for Proxmox VMs and containers between two hosts

  poorha                                   interactive menu (whiptail)
  poorha status [VM]
  poorha list                              protected VMs and their options
  poorha select                            choose the protected VMs (checklist)
  poorha add VMID|all [NODE] [peer=VMID] [key=value…] [-f]
  poorha remove VM [-y]
  poorha set VM key=value…                 standby=cold|hot keep=netX,… guard=IP ref=IP
                                           note=TEXT profile=standard|router
  poorha replicate [VM|all] [--to NODE] [--no-start] [-y]
                                           (no --to: active → standby)
  poorha activate VM NODE [-f] [-y]        emergency activation
  poorha standby  VM NODE [-y]
  poorha switch   VM NODE [--replicate|--no-replicate] [-y]
  poorha guard    on|off NODE   |   poorha guard test VM NODE
  poorha deploy   [-y]                     installs everything on both hosts
  poorha config                            configuration wizard (this node)
  poorha import-opnha                      takes over an opnha setup
  poorha version

  VM = local vmid, peer vmid or name (VMs and containers alike)
  NODE = this host or the peer (name)
  -y: no confirmation     -f: force
EOF
}

internal() {   # commands run by poorha itself on a node, about that node's own config
  local cmd=$1 kv k; shift
  case "$cmd" in
    _get)      load_conf >/dev/null 2>&1 || defaults; printf '%s\n' "${!1:-}" ;;
    _set-vm)   load_conf || die "no config on $(hostname -s) — run \"poorha deploy\""
               vm_set "$@"; write_conf ;;
    _del-vm)   load_conf || exit 0; del_vm "$1"; write_conf ;;
    _dump-vms) load_conf || exit 0
               for k in "${VM_IDS[@]}"; do
                 # the entry seen from the other side: "<its key> peer=<our key> …"
                 qcmd "$(vget "$k" peer)" "peer=$k" "type=$(vget "$k" type)" "standby=$(vget "$k" standby)" "keep=$(vget "$k" keep)" \
                      "guard=$(vget "$k" guard)" "ref=$(vget "$k" ref)" "note=$(vget "$k" note)"; echo
               done ;;
    _set-identity)
               load_conf || defaults
               for kv in "$@"; do
                 k=${kv%%=*}
                 case "$k" in
                   NODE_NAME|NODE_IP|PEER_NAME|PEER_IP|STORAGE|REF_IP|GUARD_TRIES|HEALTH_PING|TMP_DIR) printf -v "$k" '%s' "${kv#*=}" ;;
                   *) die "unknown setting: $k" ;;
                 esac
               done
               write_conf ;;
    _receive)  load_conf || die "no config on $(hostname -s)"
               if [ "${2:-qemu}" = lxc ]; then
                 # pct cannot restore from stdin without being told the volumes: stage the archive
                 mkdir -p "$TMP_DIR"
                 RECV_TMP=$(mktemp -p "$TMP_DIR" --suffix=.tar.zst poorha-XXXXXX) || die "mktemp failed in $TMP_DIR"
                 trap 'rm -f "$RECV_TMP"' EXIT
                 cat >"$RECV_TMP" || die "receiving the archive failed (space in $TMP_DIR?)"
                 pct restore "$1" "$RECV_TMP" --force 1 --storage "$STORAGE"
               else
                 zstd -d -q | qmrestore - "$1" --force 1 --unique 0 --storage "$STORAGE"
               fi ;;
    *)         die "unknown internal command: $cmd" ;;
  esac
}

main() {
  local cmd=${1:-menu} args=() kvs=() start=1 rep=ask to="" k s dir m
  shift || true

  case "$cmd" in
    help|-h|--help) usage; exit 0 ;;
    version|-v|--version) echo "poorha $VERSION"; exit 0 ;;
  esac
  [ "$(id -u)" = 0 ] || die "must be run as root"
  command -v qm >/dev/null 2>&1 || die "qm not found — this script runs on a Proxmox host"
  if [[ "$cmd" == _* ]]; then internal "$cmd" "$@"; exit $?; fi

  while [ $# -gt 0 ]; do
    case "$1" in
      -y|--yes)        YES=1 ;;
      -f|--force)      FORCE=1 ;;
      --no-start)      start=0 ;;
      --replicate)     rep=yes ;;
      --no-replicate)  rep=no ;;
      --to)            to=${2:-}; shift ;;
      *=*)             kvs+=("$1") ;;
      *)               args+=("$1") ;;
    esac
    shift
  done
  mkdir -p "$SSH_CTL_DIR"
  PEER_DOWN=0

  if [ "$cmd" = import-opnha ]; then cmd_import_opnha; exit $?; fi
  if ! load_conf; then
    if [ "$cmd" = config ] || { [ "$cmd" = menu ] && have_tui && \
         whiptail --title "poorha" --yesno "No configuration ($CONF).\n\nRun the wizard?" 10 60; }; then
      cmd_config || exit 1
      load_conf || exit 1
      [ "$cmd" = config ] && exit 0
    else
      die "no configuration: run \"poorha config\" (or \"poorha import-opnha\")"
    fi
  fi
  [ "$(hostname -s)" = "$NODE_NAME" ] || warn "this host is $(hostname -s) but $CONF describes $NODE_NAME"
  [ -n "$PEER_IP" ] || die "PEER_IP missing in $CONF — run \"poorha config\""
  if [ "$cmd" != deploy ]; then
    peer_probe
    m=$(version_mismatch) && warn "$m"
  fi

  case "$cmd" in
    menu)      have_tui || die "no interactive terminal or whiptail missing — see \"poorha help\""; tui_main ;;
    status)    if [ ${#args[@]} -gt 0 ]; then k=$(resolve_vm "${args[0]}") || exit 1; fi
               cmd_status "${k:-}" ;;
    list)      cmd_list ;;
    select)    have_tui || die "no interactive terminal — use \"poorha add\""; TUI=1; refresh_rows; tui_select ;;
    add)       [ ${#args[@]} -ge 1 ] || die "usage: poorha add VMID|all [NODE] [key=value…]"
               cmd_add "${args[@]}" "${kvs[@]}" ;;
    remove)    [ ${#args[@]} -ge 1 ] || die "usage: poorha remove VM"
               k=$(resolve_vm "${args[0]}") || exit 1
               confirm "Stop protecting $NODE_NAME/vm$k ↔ $PEER_NAME/vm$(vget "$k" peer)?\n(the VMs themselves are left untouched)" || die "cancelled"
               pair_remove "$k" ;;
    set)       [ ${#args[@]} -ge 1 ] || die "usage: poorha set VM key=value…"
               k=$(resolve_vm "${args[0]}") || exit 1
               cmd_set "$k" "${kvs[@]}" ;;
    replicate)
      if [ ${#args[@]} -eq 0 ] || [ "${args[0]}" = all ]; then
        [ -z "$to" ] || die "--to needs a VM"
        cmd_replicate_all "$start"
      else
        k=$(resolve_vm "${args[0]}") || exit 1
        if [ -n "$to" ]; then
          s=$(resolve_side "$to") || exit 1
          cmd_replicate "$k" "$(other "$s")" "$s" "$start"
        else
          dir=$(auto_direction "$k")
          [ -n "$dir" ] || die "ambiguous direction (no copy or both copies active) — specify: --to NODE"
          # shellcheck disable=SC2086
          cmd_replicate "$k" $dir "$start"
        fi
      fi ;;
    activate|standby|switch)
      [ ${#args[@]} -ge 2 ] || die "usage: poorha $cmd VM NODE"
      k=$(resolve_vm "${args[0]}") || exit 1
      s=$(resolve_side "${args[1]}") || exit 1
      case "$cmd" in
        activate) cmd_activate "$k" "$s" "$FORCE" ;;
        standby)  cmd_standby "$k" "$s" ;;
        switch)   cmd_switch "$k" "$s" "$rep" ;;
      esac ;;
    guard)
      case "${args[0]:-}" in
        on|off) [ ${#args[@]} -ge 2 ] || die "usage: poorha guard on|off NODE"
                s=$(resolve_side "${args[1]}") || exit 1; cmd_guard "$s" "${args[0]}" ;;
        test)   [ ${#args[@]} -ge 3 ] || die "usage: poorha guard test VM NODE"
                k=$(resolve_vm "${args[1]}") || exit 1
                s=$(resolve_side "${args[2]}") || exit 1; cmd_guard_test "$k" "$s" ;;
        *)      die "usage: poorha guard on|off NODE | poorha guard test VM NODE" ;;
      esac ;;
    deploy)    cmd_deploy ;;
    config)    cmd_config ;;
    *)         usage; exit 2 ;;
  esac
}

main "$@"
