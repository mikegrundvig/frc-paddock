#!/usr/bin/env bash
# install-software.sh: installs what the team's images get into an image: its packages, then its
# files. Every recipe's provisioning runs it. Paddock knows nothing of what they are.
#
#   install-software.sh --packages DIR --files DIR [--root DIR] [--offline]
#
#   --packages  the packages (.deb), downloaded and checked (the engine's fetch.sh), installed in
#               their names' order (fetch.sh numbers them as the input lists them)
#   --files     the files, as plan.sh writes them: files.list (a mode, a destination, and a file's
#               name, a line each) and the files it names
#   --root      the image's root (/ in its chroot, as provisioning runs it)
#   --offline   for the tests, on a directory tree: each package is unpacked with dpkg-deb,
#               instead of installed by apt
#
# In the chroot, apt installs the packages, with what they depend on from the image's own package
# sources (never what they only recommend), and runs their maintainer scripts: with no systemd
# running, those enable units and start nothing. Each must be for the image's architecture, and
# ends up installed at its own version, or this fails. Then each file is copied to its
# destination, root's, with its mode, replacing what was there.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
. "$here/lib/common.sh"

packages="" files="" target=/ offline=no
while (($#)); do
  case $1 in
    --packages) packages=${2:?}; shift 2 ;;
    --files) files=${2:?}; shift 2 ;;
    --root) target=${2:?}; shift 2 ;;
    --offline) offline=yes; shift ;;
    -h | --help) sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
    *) die "unknown option: $1" ;;
  esac
done
[[ -d $packages ]] || die "--packages must be a folder of packages (.deb), even an empty one"
[[ -f $files/files.list ]] || die "--files must be a folder with its files.list (plan.sh's)"
packages=$(cd "$packages" && pwd)
files=$(cd "$files" && pwd)
target=$(cd "$target" && pwd)

# A path inside the target.
t() {
  printf '%s%s' "${target%/}" "$1"
}

debs=()
for deb in "$packages"/*.deb; do
  [[ -e $deb ]] && debs+=("$deb")
done
if ((${#debs[@]})); then
  if [[ $offline == yes ]]; then
    for deb in "${debs[@]}"; do
      dpkg-deb -x "$deb" "$target"
    done
  else
    arch=$(dpkg --print-architecture)
    for deb in "${debs[@]}"; do
      what=$(dpkg-deb -f "$deb" Architecture) || die "${deb##*/} isn't a package (.deb)"
      [[ $what == "$arch" || $what == all ]] || die "${deb##*/} is for $what, but this image is $arch"
    done
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends "${debs[@]}"
    apt-get clean
    rm -rf /var/lib/apt/lists/*
    for deb in "${debs[@]}"; do
      name=$(dpkg-deb -f "$deb" Package)
      version=$(dpkg-deb -f "$deb" Version)
      [[ $(dpkg-query -W -f='${Status} ${Version}' "$name" 2>/dev/null) == "install ok installed $version" ]] ||
        die "${deb##*/} isn't installed at its version, $version"
    done
  fi
fi

count=0
while read -r mode destination name <&3; do
  [[ -n $mode ]] || continue
  [[ $mode =~ ^[0-7]{4}$ ]] && is_image_path "$destination" && [[ $name =~ ^[0-9]+$ ]] ||
    die "$files/files.list: '$mode $destination $name' isn't a mode, a destination, and a file"
  [[ -f $files/$name ]] || die "$files/files.list names $name, which isn't there"
  dest=$(t "$destination")
  mkdir -p "$(dirname "$dest")"
  cp "$files/$name" "$dest.paddock-new"
  chmod "$mode" "$dest.paddock-new"
  if ((EUID == 0)); then
    chown 0:0 "$dest.paddock-new"
  fi
  mv -f "$dest.paddock-new" "$dest"
  count=$((count + 1))
done 3<"$files/files.list"
say "installed ${#debs[@]} package(s) and $count file(s)"
