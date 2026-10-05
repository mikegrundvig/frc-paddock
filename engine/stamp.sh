#!/usr/bin/env bash
# stamp.sh: writes one computer's identity (hostname, hosts, machine ID, address), its own files,
# and its image's os-release labels into ROOT. Same inputs, same bytes. Needs no root.
#
#   stamp.sh --plan DIR --computer HOSTNAME --root DIR [--stamp-out FILE]
#
#   --stamp-out  the computer's record, JSON, for manifest.sh
#
# Writes from outside the image, so it follows no links in it (an absolute one would resolve on the
# build machine). The machine ID derives from the repository and hostname: stable across releases.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
. "$here/lib/common.sh"

plan="" computer="" root="" stamp_out=""
while (($#)); do
  case $1 in
    --plan) need_value "$@"; plan=$2; shift 2 ;;
    --computer) need_value "$@"; computer=$2; shift 2 ;;
    --root) need_value "$@"; root=$2; shift 2 ;;
    --stamp-out) need_value "$@"; stamp_out=$2; shift 2 ;;
    -h | --help) usage ;;
    *) die "unknown option: $1" ;;
  esac
done
[[ -n $plan && -n $computer ]] || die "--plan and --computer are required"
[[ -n $root && -d $root ]] || die "--root must be an existing folder: the image's root"
root=$(cd "$root" && pwd)
root=${root%/}
load_plan "$plan"
load_computer "$plan" "$computer"
load_image "$plan" "$COMPUTER_IMAGE"

put_in "$root" /etc/hostname 0644 <<<"$COMPUTER"
{
  cat <<HOSTS
# Written at stamping (Paddock), from Paddock's input.
127.0.0.1	localhost
::1	localhost ip6-localhost ip6-loopback
ff02::1	ip6-allnodes
ff02::2	ip6-allrouters

# The computers in Paddock's input. This computer's own name resolves to its address.
HOSTS
  cat "$plan/hosts"
} | put_in "$root" /etc/hosts 0644
init_write_machine_id "$root" "$(derived_hex "paddock machine-id/$REPOSITORY/$COMPUTER")"
network_write "$root" "$COMPUTER" "$ADDRESS" "$PREFIX" "$GATEWAY" "$DNS" "$REPOSITORY"

# The computer's own files, replacing what the image has there.
own=$plan/computers/$COMPUTER.files
own_files=()
if [[ -f $own/list ]]; then
  while IFS=$'\t' read -r nn to mode <&3; do
    put_in "$root" "$to" "$mode" <"$own/$nn"
    own_files+=("$(printf '{"to": "%s", "sha256": "%s"}' "$to" "$(sha256sum <"$own/$nn" | cut -c1-64)")")
  done 3<"$own/list"
fi

# os-release: /etc/os-release, or the file it links to, resolved inside the image.
path=/etc/os-release
for _ in 1 2 3 4 5 6 7 8; do
  [[ -L $root$path ]] || break
  link=$(readlink "$root$path")
  [[ $link == /* ]] || link=$(dirname "$path")/$link
  path=$(realpath -m -s "$link")
done
[[ ! -L $root$path ]] || die "/etc/os-release goes through too many links"
if [[ ! -e $root$path && -f $root/usr/lib/os-release ]]; then
  path=/usr/lib/os-release
fi
[[ -f $root$path ]] || die "the image has no /etc/os-release to label"
text=$(mktemp)
{
  grep -Ev "^(IMAGE_ID|IMAGE_VERSION|PADDOCK_[A-Z0-9_]*)=|^# Paddock: " "$root$path" || true
  echo "$OS_RELEASE_MARK"
  printf 'IMAGE_ID="%s"\n' "$IMAGE"
  printf 'IMAGE_VERSION="%s"\n' "$RELEASE"
  printf 'PADDOCK_BUILT_AT="%s"\n' "$BUILT_AT"
  printf 'PADDOCK_COMMIT="%s"\n' "$COMMIT"
} >"$text"
put_in "$root" "$path" 0644 <"$text"
rm -f "$text"

# The record for the release's manifest. plan.sh checked every value, so none needs JSON escaping.
if [[ -n $stamp_out ]]; then
  packages=() downloads=() dns=()
  while IFS=$'\t' read -r kind a b c _ <&3; do
    case $kind in
      package) packages+=("$(printf '{"url": "%s", "sha256": "%s"}' "$b" "$a")") ;;
      download) downloads+=("$(printf '{"url": "%s", "sha256": "%s", "to": "%s"}' "$b" "$a" "$c")") ;;
    esac
  done 3<"$IMAGE_DIR/steps.list"
  for server in $DNS; do
    dns+=("\"$server\"")
  done
  join() {
    local IFS=,
    echo "$*"
  }
  {
    printf '{\n'
    printf '  "hostname": "%s",\n' "$COMPUTER"
    printf '  "image": "%s",\n' "$IMAGE"
    printf '  "address": "%s/%s",\n' "$ADDRESS" "$PREFIX"
    printf '  "gateway": "%s",\n' "$GATEWAY"
    printf '  "dns": [%s],\n' "$(join "${dns[@]}")"
    printf '  "release": "%s",\n' "$RELEASE"
    printf '  "commit": "%s",\n' "$COMMIT"
    printf '  "builtAt": "%s",\n' "$BUILT_AT"
    printf '  "base": {"url": "%s", "sha256": "%s"},\n' "$BASE_URL" "$BASE_SHA256"
    printf '  "packages": [%s],\n' "$(join "${packages[@]}")"
    printf '  "downloads": [%s],\n' "$(join "${downloads[@]}")"
    printf '  "files": [%s]\n' "$(join "${own_files[@]}")"
    printf '}\n'
  } | put "$stamp_out" 0644
fi
say "stamped $COMPUTER: $ADDRESS/$PREFIX"
