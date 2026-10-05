#!/usr/bin/env bash
# run-steps.sh: runs an image's steps in order, as root inside its chroot (build-image.sh runs it).
#
#   run-steps.sh --plan DIR --image NAME --config-dir DIR --inputs DIR [--root DIR] [--offline]
#
#   --config-dir  paddock.yaml's folder, where the steps' files and scripts are
#   --inputs      what fetch.sh downloaded: packages/ and downloads/
#   --offline     for the tests, on a folder: packages are unpacked, scripts only logged
#
# The packages and init adapters check the base first. The network adapter's check comes after the
# steps (finish-root.sh), so a step can install what it needs. Consecutive package steps install in
# one apt call. A script runs in the config folder (read-only), with PADDOCK_CONFIG_DIR and
# PADDOCK_IMAGE set.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
. "$here/lib/common.sh"

plan="" image="" config_dir="" inputs="" target=/ offline=no
while (($#)); do
  case $1 in
    --plan) need_value "$@"; plan=$2; shift 2 ;;
    --image) need_value "$@"; image=$2; shift 2 ;;
    --config-dir) need_value "$@"; config_dir=$2; shift 2 ;;
    --inputs) need_value "$@"; inputs=$2; shift 2 ;;
    --root) need_value "$@"; target=$2; shift 2 ;;
    --offline) offline=yes; shift ;;
    -h | --help) usage ;;
    *) die "unknown option: $1" ;;
  esac
done
[[ -n $plan && -n $image ]] || die "--plan and --image are required"
[[ -n $config_dir && -d $config_dir ]] || die "--config-dir must be paddock.yaml's folder"
[[ -n $inputs && -d $inputs ]] || die "--inputs must be what fetch.sh downloaded"
if [[ $offline == no && $EUID -ne 0 ]]; then
  die "run as root, inside the image's chroot"
fi
load_image "$plan" "$image"
target=$(cd "$target" && pwd)
root=${target%/}
packages=$inputs/packages downloads=$inputs/downloads

problems=$(
  packages_check_base "$target" || true
  init_check_base "$target" || true
)
if [[ -n $problems ]]; then
  die "$image's base isn't one its adapters (os:) can build on:"$'\n'"  - ${problems//$'\n'/$'\n'  - }"
fi

packages_prepare "$target"
trap 'packages_finish "$target"' EXIT

pending=()
flush_packages() {
  ((${#pending[@]})) || return 0
  say "installing ${pending[*]##*/}"
  packages_install "$target" "$offline" "${pending[@]}"
  pending=()
}

# Puts a file in the image, root's, with its mode, replacing what was there.
place() {
  local dest=$root$2
  [[ ! -d $dest ]] || die "step $4: $2 is a folder in the image: give the file's full path (such as $2/${1##*/})"
  mkdir -p "$(dirname "$dest")"
  cp "$1" "$dest.paddock-new"
  chmod "$3" "$dest.paddock-new"
  if ((EUID == 0)); then
    chown 0:0 "$dest.paddock-new"
  fi
  mv -fT "$dest.paddock-new" "$dest"
}

count=0 package_number=0 download_number=0
while IFS=$'\t' read -r kind a b c d <&3; do
  [[ -n $kind ]] || continue
  count=$((count + 1))
  case $kind in
    file) # a=path b=to c=mode
      flush_packages
      place "$config_dir/$a" "$b" "$c" "$count"
      say "step $count: $a to $b"
      ;;
    download) # a=sha256 b=url c=to d=mode
      flush_packages
      files=("$downloads/$(printf '%02d' "$download_number")"-*)
      [[ -f ${files[0]} ]] || die "step $count: download ${b##*/} isn't in $downloads (fetch.sh downloads it)"
      place "${files[0]}" "$c" "$d" "$count"
      download_number=$((download_number + 1))
      say "step $count: ${b##*/} to $c"
      ;;
    package) # a=sha256 b=url
      files=("$packages/$(printf '%02d' "$package_number")"-*)
      [[ -f ${files[0]} ]] || die "step $count: package ${b##*/} isn't in $packages (fetch.sh downloads it)"
      pending+=("${files[0]}")
      package_number=$((package_number + 1))
      ;;
    run) # a=path
      flush_packages
      script=$config_dir/$a
      if [[ $offline == yes ]]; then
        say "step $count: would run $a"
        continue
      fi
      say "step $count: running $a"
      if [[ -x $script && $(head -c 2 "$script") == '#!' ]]; then
        set -- "$script"
      else
        set -- bash "$script"
      fi
      (cd "$config_dir" && PADDOCK_CONFIG_DIR=$config_dir PADDOCK_IMAGE=$image "$@") ||
        die "step $count: $a failed"
      ;;
    *)
      die "$IMAGE_DIR/steps.list: unknown step '$kind'"
      ;;
  esac
done 3<"$IMAGE_DIR/steps.list"
flush_packages
say "ran $image's $count step(s)"
