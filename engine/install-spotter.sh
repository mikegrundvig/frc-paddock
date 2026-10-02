#!/usr/bin/env bash
# install-spotter.sh: installs Spotter's agent from its .deb, and packs, into an image. Every
# recipe's provisioning runs it.
#
#   install-spotter.sh --deb FILE [--pack DIR]... [--root DIR] [--offline]
#
#   --deb      the agent's package for the image's architecture, as Spotter releases it
#              (spotter.lock pins it; the engine's fetch.sh downloads and checks it)
#   --pack     a pack's folder as built, with its pack.json: its install.sh installs it, when it has
#              one; else the folder goes to /usr/lib/frc-coprocessor/packs/<name>/ as it is, and
#              its *.rules files to polkit's rules (a team's pack, say)
#   --root     the image's root (/ in its chroot, as provisioning runs it)
#   --offline  for the tests, on a directory tree: the package is unpacked with dpkg-deb and its
#              unit enabled here, instead of dpkg running its maintainer scripts
#
# In the chroot, dpkg runs the package's maintainer scripts: they make the agent's account and
# enable its unit, and start nothing, as no systemd is running. The agent must run as its own
# account, never root: its polkit rules name it. Also installs the root job that writes the
# drive's health for the agent (files/coprocessor-facts.*), which needs nvme-cli.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
. "$here/lib/common.sh"

deb=""
packs=()
target=/
offline=no
while (($#)); do
  case $1 in
    --deb) deb=${2:?}; shift 2 ;;
    --pack) packs+=("${2:?}"); shift 2 ;;
    --root) target=${2:?}; shift 2 ;;
    --offline) offline=yes; shift ;;
    -h | --help) sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
    *) die "unknown option: $1" ;;
  esac
done
[[ -f $deb ]] || die "no agent package at '$deb': Spotter's .deb, as spotter.lock pins it"
target=$(cd "$target" && pwd)

# A path inside the target.
t() {
  printf '%s%s' "${target%/}" "$1"
}

# Writes stdin to a file inside the target, with a mode, replacing what was there.
put() {
  local dest
  dest=$(t "$1")
  mkdir -p "$(dirname "$dest")"
  cat >"$dest.coproc-new"
  chmod "$2" "$dest.coproc-new"
  mv -f "$dest.coproc-new" "$dest"
}

units() {
  systemctl --root="$target" --quiet "$@"
}

if [[ $offline == yes ]]; then
  # Its files, as dpkg unpacks them; its account is made when the image boots (sysusers.d).
  dpkg-deb -x "$deb" "$target"
else
  arch=$(dpkg --print-architecture)
  [[ $(dpkg-deb -f "$deb" Architecture) == "$arch" ]] ||
    die "$deb is for $(dpkg-deb -f "$deb" Architecture), but this image is $arch"
  dpkg -i "$deb"
fi
unit=$(t "$IMG_AGENT_UNIT")
[[ -f $unit ]] || die "the agent's package installed no $IMG_AGENT_UNIT"
# Never root: its polkit rules, which let it power off and stop the software it watches, name its
# account.
user=$(sed -n 's/^User=//p' "$unit" | tail -1)
if [[ -z $user || $user == root || $user == 0 ]]; then
  die "$IMG_AGENT_UNIT would run the agent as root"
fi
[[ $user == "$IMG_AGENT_USER" ]] ||
  die "$IMG_AGENT_UNIT runs the agent as '$user', but its polkit rules are for '$IMG_AGENT_USER'"
units enable "${IMG_AGENT_UNIT##*/}"

for pack in "${packs[@]}"; do
  [[ -f $pack/pack.json ]] || die "no pack at $pack: a pack's folder as built, with its pack.json"
  if [[ -f $pack/install.sh ]]; then
    sh "$pack/install.sh" --root "$target" >/dev/null
    continue
  fi
  # pack.json as Spotter's build tool writes it (Json.pretty): its name a top-level member.
  name=$(sed -n 's/^  "pack": *"\([a-z0-9-]*\)".*/\1/p' "$pack/pack.json" | head -n 1)
  [[ -n $name ]] || die "$pack/pack.json names no pack"
  dest=$(t "/usr/lib/frc-coprocessor/packs/$name")
  rm -rf "$dest"
  mkdir -p "$dest"
  (cd "$pack" && find . -type f ! -name '*.rules' ! -name 'pack.yaml' -print0 |
    while IFS= read -r -d '' file; do
      mkdir -p "$dest/$(dirname "$file")"
      cp "$file" "$dest/$file"
    done)
  for rule in "$pack"/*.rules; do
    [[ -e $rule ]] || continue
    put "/usr/share/polkit-1/rules.d/${rule##*/}" 0644 <"$rule"
  done
done

# The root job: the drive's health and the SPI bootloader's version, into /run for the agent.
put /usr/local/lib/coprocessor/coprocessor-facts.sh 0755 <"$here/files/coprocessor-facts.sh"
put /etc/systemd/system/coprocessor-facts.service 0644 <"$here/files/coprocessor-facts.service"
put /etc/systemd/system/coprocessor-facts.timer 0644 <"$here/files/coprocessor-facts.timer"
units enable coprocessor-facts.service coprocessor-facts.timer
say "installed Spotter's agent ($(dpkg-deb -f "$deb" Version)) and ${#packs[@]} pack(s)"
