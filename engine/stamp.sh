#!/usr/bin/env bash
# stamp.sh: writes one computer's identity, configuration, and stamp into an image's filesystems.
#
#   stamp.sh --computer NAME --table FILE --recipe-dir DIR \
#       --root DIR --coproc DIR --data DIR \
#       --release NAME --recipe-hash HEX --agent-config FILE \
#       [--label NAME=VALUE]... [--built-at TIME] [--keys FILE] \
#       [--settings DIR] [--inputs DIR] [--stamp-out FILE]
#
# --root, --coproc, and --data are the image's three filesystems, as mounted (stamp-image.sh does
# that in CI), or any directories: it only writes files, so the tests run it without root. Into
# them it writes, from the table:
#   root    /etc/hostname, /etc/hosts (every computer in the table), /etc/machine-id, the robot
#           network's NetworkManager profile (a static address, 10.TE.AM.<address>/24), the
#           team's SSH public keys (--keys, without their comments), the agent's configuration
#           (--agent-config: the computer's file of those Spotter's build tool's agent-configs
#           writes, one per computer, from the table), and /etc/coprocessor/stamp.json
#   coproc  stamp.json again, and a README.txt, for anyone holding the drive
#   data    the folders the root's bind mounts need, and what the recipe's own stamp step writes:
#           its stamp-data.sh, given --settings (the team's committed settings) and --inputs (what
#           provisioning left, and its tools), writes into the data folder and prints its stamp
#           labels, NAME=VALUE, one to a line
#
# The stamp is Spotter's: the computer's name, team, and address; the release, recipe hash, and
# build time; and labels, each --label and each the recipe's step printed. Needs bash and yq
# (mikefarah's, version 4). Stamping the same inputs twice writes the same bytes.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
. "$here/lib/common.sh"

computer="" table="" recipe_dir="" root="" coproc="" data="" release="" recipe_hash=""
agent_config="" built_at="" keys="" settings="" inputs="" stamp_out=""
labels=()
while (($#)); do
  case $1 in
    --computer) computer=${2:?}; shift 2 ;;
    --table) table=${2:?}; shift 2 ;;
    --recipe-dir) recipe_dir=${2:?}; shift 2 ;;
    --root) root=${2:?}; shift 2 ;;
    --coproc) coproc=${2:?}; shift 2 ;;
    --data) data=${2:?}; shift 2 ;;
    --release) release=${2:?}; shift 2 ;;
    --recipe-hash) recipe_hash=${2:?}; shift 2 ;;
    --agent-config) agent_config=${2:?}; shift 2 ;;
    --label) labels+=("${2:?}"); shift 2 ;;
    --built-at) built_at=${2-}; shift 2 ;;
    --keys) keys=${2-}; shift 2 ;;
    --settings) settings=${2-}; shift 2 ;;
    --inputs) inputs=${2-}; shift 2 ;;
    --stamp-out) stamp_out=${2:?}; shift 2 ;;
    -h | --help) sed -n '2,27p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
    *) die "unknown option: $1" ;;
  esac
done

require_yq
load_recipe "$recipe_dir"
for dir in "$root" "$coproc" "$data"; do
  [[ -n $dir && -d $dir ]] || die "--root, --coproc, and --data must be existing directories"
done
[[ -n $computer ]] || die "--computer is required"
[[ $release =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] || die "--release '$release': letters, digits, '.', '_', '-'"
is_sha256 "$recipe_hash" || die "--recipe-hash must be a sha256 (64 lowercase hex digits)"
[[ -z $built_at || $built_at =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] ||
  die "--built-at '$built_at' isn't a time in UTC, such as 2027-01-10T18:30:00Z"
check_table "$table"
export NAME=$computer
[[ $(yq -r '[.computers[] | select(.name == strenv(NAME))] | length' "$table") == 1 ]] ||
  die "no computer named '$computer' in $table"
[[ -n $agent_config ]] || die "--agent-config is required: the computer's agent configuration"
[[ -f $agent_config ]] || die "no agent configuration at $agent_config"
config_name=$(yq -p json -r '.name' "$agent_config" 2>/dev/null) ||
  die "$agent_config isn't an agent configuration (JSON)"
[[ $config_name == "$computer" ]] ||
  die "$agent_config is the agent configuration of '$config_name', not $computer"
team=$(table_get '.team' "$table")
prefix=$(team_prefix "$team")
address="$prefix.$(yq -r '.computers[] | select(.name == strenv(NAME)) | .address' "$table")"
gateway="$prefix.$GATEWAY_OCTET"

# Writes stdin to a file, with a mode, replacing what was there.
put() {
  mkdir -p "$(dirname "$1")"
  cat >"$1.stamp-new"
  chmod "$2" "$1.stamp-new"
  mv -f "$1.stamp-new" "$1"
}

# A stamp label: a name, then one line of text.
check_label() {
  [[ $1 =~ ^[A-Za-z][A-Za-z0-9_.-]{0,63}=[^[:cntrl:]]{0,256}$ ]] ||
    die "label '$1' isn't NAME=VALUE: a name, then one line of text"
}

# --- The data partition: the bind mounts' folders, then the recipe's own step. ---
mkdir -p "$data/$DATA_JOURNAL" "$data/$DATA_SSH"
chmod 2755 "$data/$DATA_JOURNAL"
chmod 0700 "$data/$DATA_SSH"
for label in "${labels[@]}"; do
  check_label "$label"
done
if [[ -x $RECIPE_DIR/stamp-data.sh ]]; then
  printed=$("$RECIPE_DIR/stamp-data.sh" --computer "$computer" --data "$data" \
    --settings "$settings" --inputs "$inputs") || die "the recipe's stamp step failed for $computer"
  while IFS= read -r label; do
    [[ -n $label ]] || continue
    check_label "$label"
    labels+=("$label")
  done <<<"$printed"
fi

# --- Identity. ---
put "$root/etc/hostname" 0644 <<<"$computer"
{
  cat <<HOSTS
# Written at stamping (Paddock's stamp.sh), from the table.
127.0.0.1	localhost
::1	localhost ip6-localhost ip6-loopback
ff02::1	ip6-allnodes
ff02::2	ip6-allrouters

# The robot's coprocessors. This computer's own name resolves to its robot address.
HOSTS
  yq -r '.computers[] | (.address | tostring) + " " + .name' "$table" | while read -r last name; do
    printf '%s.%s\t%s\n' "$prefix" "$last" "$name"
  done
} | put "$root/etc/hosts" 0644
# A fixed machine ID. With the root read-only, systemd would otherwise make a new one at every
# boot, treat every boot as the first, and start the journal afresh under the new ID, leaving the
# boot before a power cut out of `journalctl -b -1`. Derived from the computer, so a stamp repeats.
put "$root/etc/machine-id" 0444 <<<"$(derived_hex "coprocessor machine-id/$team/$computer")"
put "$root$IMG_CONNECTION" 0600 <<PROFILE
# Written at stamping (Paddock's stamp.sh): $computer's address on the robot network.
# FRC's static range for on-robot devices is 10.TE.AM.6 to .19, netmask 255.255.255.0, gateway
# 10.TE.AM.4 (docs.wpilib.org, "IP Configurations"). Any Ethernet port takes it.
[connection]
id=robot
uuid=$(derived_uuid "coprocessor connection/$team/$computer")
type=ethernet
autoconnect=true
autoconnect-priority=100
autoconnect-retries=0

[ethernet]

[ipv4]
method=manual
address1=$address/$NETMASK_BITS,$gateway
# Duplicate-address detection: a second drive stamped for this computer stays off the address.
dad-timeout=3000
may-fail=false

[ipv6]
method=disabled
PROFILE

# --- SSH: the team's public keys, if it gave any, without their comments (often a name or an
# email address, and the images may be public). Root-owned and read-only, which sshd accepts; no
# key means no SSH login. ---
ssh_dir="$root/home/$RECIPE_SSH_USER/.ssh"
if [[ -n $keys && -f $keys ]]; then
  if grep -q 'PRIVATE KEY' "$keys"; then
    die "$keys holds a private key: only public keys belong there (it ships in every image)"
  fi
  if grep -Ev '^[[:space:]]*(#|$)' "$keys" | grep -Evq '^(ssh-(ed25519|rsa)|ecdsa-sha2-nistp(256|384|521)|sk-(ssh-ed25519|ecdsa-sha2-nistp256)@openssh\.com) '; then
    die "$keys has a line that isn't an SSH public key"
  fi
  mkdir -p "$ssh_dir"
  chmod 0755 "$ssh_dir"
  awk '!/^[[:space:]]*(#|$)/ { print $1, $2 }' "$keys" | put "$ssh_dir/authorized_keys" 0644
else
  rm -f "$ssh_dir/authorized_keys"
  say "no SSH keys: $computer takes no SSH logins"
fi

# --- Spotter's agent: its configuration. ---
put "$root$IMG_AGENT_CONFIG" 0644 <"$agent_config"

# --- The stamp. ---
# shellcheck disable=SC2016 # $c is yq's variable, not the shell's
stamp=$(
  ADDRESS=$address RELEASE=$release RECIPE_HASH=$recipe_hash BUILT_AT=$built_at \
    DEFAULT_PORT=$DEFAULT_AGENT_PORT \
    yq -o=json -I=2 '
      (.computers[] | select(.name == strenv(NAME))) as $c |
      {
        "name": $c.name,
        "team": .team,
        "address": strenv(ADDRESS),
        "version": strenv(RELEASE),
        "recipeHash": strenv(RECIPE_HASH),
        "builtAt": strenv(BUILT_AT),
        "labels": {},
        "agentPort": ($c.agentPort // .agentPort // env(DEFAULT_PORT))
      }' "$table"
)
for label in "${labels[@]}"; do
  stamp=$(KEY=${label%%=*} VALUE=${label#*=} yq -p json -o=json -I=2 \
    '.labels[strenv(KEY)] = strenv(VALUE)' <<<"$stamp")
done
stamp=$(yq -p json -o=json -I=2 '.labels |= sort_keys(.)' <<<"$stamp")
put "$root$IMG_STAMP" 0644 <<<"$stamp"
put "$coproc/stamp.json" 0644 <<<"$stamp"
put "$coproc/README.txt" 0644 <<README
This drive is $computer, $address on team $team's robot.

Release $release ($RECIPE_TITLE). stamp.json says exactly what's on it.
Put it only in $computer's board: two drives with the same image would share an address.
README
if [[ -n $stamp_out ]]; then
  put "$stamp_out" 0644 <<<"$stamp"
fi
say "stamped $computer: $address"
