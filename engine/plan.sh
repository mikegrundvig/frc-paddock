#!/usr/bin/env bash
# plan.sh: checks paddock.yaml whole, then writes the plan the later jobs follow.
#
#   plan.sh --config FILE --out DIR [--repo DIR] [--release NAME] [--commit SHA] \
#       [--built-at TIME] [--repository NAME]
#
#   --repo        the Git repository, for the commit and its time (default: paddock.yaml's folder)
#   --release     the release to cut (default: build-<commit>, not published)
#   --repository  owner/name, which seeds the machine IDs (default: Git's origin)
#
# The plan is plain bash, so later jobs need no yq:
#   plan.env                RELEASE, PUBLISH (yes|no), COMMIT, BUILT_AT, REPOSITORY
#   images/NAME/image.env   IMAGE, BASE_URL, BASE_SHA256, BASE_FORMAT (xz|gz|img), ARCH, GROW_MB,
#                           OS_PACKAGES, OS_INIT, OS_NETWORK, OS_FILESYSTEM, READ_ONLY (yes|no),
#                           DATA_MB, KEEP and RAM (space-separated paths)
#   images/NAME/steps.list  a step a line, tab-separated: file PATH TO MODE | download SHA256 URL TO
#                           MODE | package SHA256 URL | run PATH
#   computers/HOST.env      COMPUTER, COMPUTER_IMAGE, ADDRESS, PREFIX, GATEWAY, DNS
#   computers/HOST.files/   the computer's own files (NN), and list: a file a line, NN TO MODE
#   hosts                   every computer's address and hostname
# Only images some computer uses are planned. Prints release=, publish=, images= (JSON: image,
# runner) and computers= (JSON: hostname, image), to $GITHUB_OUTPUT in Actions.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
. "$here/lib/common.sh"

config="" out="" repo="" release="" commit="" built_at="" repository=""
while (($#)); do
  case $1 in
    --config) need_value "$@"; config=$2; shift 2 ;;
    --out) need_value "$@"; out=$2; shift 2 ;;
    --repo) need_value "$@"; repo=$2; shift 2 ;;
    --release) need_value "$@"; release=$2; shift 2 ;;
    --commit) need_value "$@"; commit=$2; shift 2 ;;
    --built-at) need_value "$@"; built_at=$2; shift 2 ;;
    --repository) need_value "$@"; repository=$2; shift 2 ;;
    -h | --help) usage ;;
    *) die "unknown option: $1" ;;
  esac
done
require_yq
[[ -n $config ]] || die "--config is required: paddock.yaml"
[[ -n $out ]] || die "--out is required: where the plan goes"
[[ -f $config ]] || die "no input at $config"
dir=$(cd "$(dirname "$config")" && pwd)
repo=${repo:-$dir}
[[ -d $repo ]] || die "--repo '$repo' isn't a folder"
# --out is replaced whole: refuse anything that isn't empty or an earlier plan.
if [[ -e $out && ! -f $out/plan.env && -n $(ls -A "$out" 2>/dev/null) ]]; then
  die "--out $out isn't empty and isn't an earlier plan: give a new folder"
fi

check_config "$config" "$dir"

if [[ -z $commit ]]; then
  commit=$(git -C "$repo" rev-parse HEAD 2>/dev/null) || die "--commit is required: $repo isn't a Git repository"
fi
[[ $commit =~ ^[0-9a-f]{7,64}$ ]] || die "--commit '$commit' isn't a commit"
if [[ -z $built_at ]]; then
  if seconds=$(git -C "$repo" log -1 --format=%ct "$commit" 2>/dev/null); then
    built_at=$(date -u -d "@$seconds" +%Y-%m-%dT%H:%M:%SZ)
  else
    built_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  fi
fi
[[ $built_at =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] ||
  die "--built-at '$built_at' isn't a UTC time such as 2027-01-10T18:30:00Z"
if [[ -z $repository ]]; then
  remote=$(git -C "$repo" remote get-url origin 2>/dev/null || true)
  if [[ $remote =~ [:/]([A-Za-z0-9._-]+/[A-Za-z0-9._-]+)$ ]]; then
    repository=${BASH_REMATCH[1]%.git}
  else
    repository=$(basename "$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null || echo "$repo")")
  fi
fi
[[ $repository =~ ^[A-Za-z0-9._/-]{1,200}$ ]] || die "--repository '$repository' has unexpected characters"
if [[ -n $release ]]; then
  publish=yes
else
  publish=no
  release="build-${commit:0:12}"
fi
is_release "$release" ||
  die "release name '$release': up to 64 lowercase letters, digits, '.', '_', '-', starting with a letter or digit"

rm -rf "$out"
mkdir -p "$out/images" "$out/computers"
{
  printf 'RELEASE=%q\n' "$release"
  printf 'PUBLISH=%q\n' "$publish"
  printf 'COMMIT=%q\n' "$commit"
  printf 'BUILT_AT=%q\n' "$built_at"
  printf 'REPOSITORY=%q\n' "$repository"
} >"$out/plan.env"

# The computers, and the images they use.
declare -A used=()
computers_json=()
: >"$out/hosts"
n=$(yq -r '.computers | length' "$config")
for ((i = 0; i < n; i++)); do
  c=".computers[$i]"
  hostname=$(yq -r "$c.hostname" "$config")
  image=$(yq -r "$c.image" "$config")
  text=$(yq -r "$c.address" "$config")
  used[$image]=1
  {
    printf 'COMPUTER=%q\n' "$hostname"
    printf 'COMPUTER_IMAGE=%q\n' "$image"
    printf 'ADDRESS=%q\n' "${text%/*}"
    printf 'PREFIX=%q\n' "${text##*/}"
    printf 'GATEWAY=%q\n' "$(yq -r "$c.gateway // \"\"" "$config")"
    printf 'DNS=%q\n' "$(yq -r "($c.dns // []) | join(\" \")" "$config")"
  } >"$out/computers/$hostname.env"
  printf '%s\t%s\n' "${text%/*}" "$hostname" >>"$out/hosts"
  files=$(yq -r "($c.files // []) | length" "$config")
  if ((files > 0)); then
    mkdir -p "$out/computers/$hostname.files"
    for ((j = 0; j < files; j++)); do
      f="$c.files[$j]"
      cp "$dir/$(yq -r "$f.file" "$config")" "$out/computers/$hostname.files/$(printf '%02d' "$j")"
      printf '%02d\t%s\t%s\n' "$j" "$(yq -r "$f.to" "$config")" \
        "$(file_mode "$(yq -r "$f.mode // \"$DEFAULT_MODE\"" "$config")")"
    done >"$out/computers/$hostname.files/list"
  fi
  computers_json+=("$(H=$hostname I=$image yq -n -o=json -I=0 '{"hostname": strenv(H), "image": strenv(I)}')")
done

get() {
  yq -r "$p$1 // \"${2-}\"" "$config"
}

images_json=()
while IFS= read -r name; do
  if [[ -z ${used[$name]:-} ]]; then
    say "image $name: no computer uses it, so it isn't built"
    continue
  fi
  p=".images[\"$name\"]"
  dir_out=$out/images/$name
  mkdir -p "$dir_out"
  url=$(get .from.url)
  case $url in
    *.img.xz) format=xz ;;
    *.img.gz) format=gz ;;
    *) format=img ;;
  esac
  arch=$(get .from.arch "$DEFAULT_ARCH")
  OS_PACKAGES=$(get .os.packages "$DEFAULT_OS_PACKAGES")
  OS_INIT=$(get .os.init "$DEFAULT_OS_INIT")
  OS_NETWORK=$(get .os.network "$DEFAULT_OS_NETWORK")
  OS_FILESYSTEM=$(get .os.filesystem "$DEFAULT_OS_FILESYSTEM")
  read_only=no data_mb=0 keep="" ram=""
  if [[ $(yq -r "${p}[\"read-only\"] | tag" "$config") == '!!map' ]]; then
    read_only=yes
    data_mb=$(size_mib "$(get '["read-only"].data')")
    keep=$(yq -r "(${p}[\"read-only\"].keep // []) | join(\" \")" "$config")
    # The defaults, the adapters' own, then the image's own, each once.
    ram=$(load_adapters && echo "$DEFAULT_RAM $(init_ram_paths) $(network_ram_paths)")
    ram+=" $(yq -r "(${p}[\"read-only\"].ram // []) | join(\" \")" "$config")"
    ram=$(tr ' ' '\n' <<<"$ram" | awk 'NF && !seen[$0]++' | paste -sd ' ')
  fi
  {
    printf 'IMAGE=%q\n' "$name"
    printf 'BASE_URL=%q\n' "$url"
    printf 'BASE_SHA256=%q\n' "$(normal_sha256 "$(get .from.sha256)")"
    printf 'BASE_FORMAT=%q\n' "$format"
    printf 'ARCH=%q\n' "$arch"
    printf 'GROW_MB=%q\n' "$(size_mib "$(get .grow "$DEFAULT_GROW")")"
    printf 'OS_PACKAGES=%q\n' "$OS_PACKAGES"
    printf 'OS_INIT=%q\n' "$OS_INIT"
    printf 'OS_NETWORK=%q\n' "$OS_NETWORK"
    printf 'OS_FILESYSTEM=%q\n' "$OS_FILESYSTEM"
    printf 'READ_ONLY=%q\n' "$read_only"
    printf 'DATA_MB=%q\n' "$data_mb"
    printf 'KEEP=%q\n' "$keep"
    printf 'RAM=%q\n' "$ram"
  } >"$dir_out/image.env"
  # A step at a time: yq groups a whole list's matches by expression, not by item.
  steps=$(yq -r "($p.steps // []) | length" "$config")
  for ((i = 0; i < steps; i++)); do
    s="$p.steps[$i]"
    if [[ $(yq -r "$s | has(\"file\")" "$config") == true ]]; then
      printf 'file\t%s\t%s\t%s\n' "$(yq -r "$s.file" "$config")" "$(yq -r "$s.to" "$config")" \
        "$(file_mode "$(yq -r "$s.mode // \"$DEFAULT_MODE\"" "$config")")"
    elif [[ $(yq -r "$s | has(\"download\")" "$config") == true ]]; then
      printf 'download\t%s\t%s\t%s\t%s\n' "$(normal_sha256 "$(yq -r "$s.sha256" "$config")")" \
        "$(yq -r "$s.download" "$config")" "$(yq -r "$s.to" "$config")" \
        "$(file_mode "$(yq -r "$s.mode // \"$DEFAULT_MODE\"" "$config")")"
    elif [[ $(yq -r "$s | has(\"package\")" "$config") == true ]]; then
      printf 'package\t%s\t%s\n' "$(normal_sha256 "$(yq -r "$s.sha256" "$config")")" \
        "$(yq -r "$s.package" "$config")"
    else
      printf 'run\t%s\n' "$(yq -r "$s.run" "$config")"
    fi
  done >"$dir_out/steps.list"
  case $arch in
    arm64) runner=ubuntu-24.04-arm ;;
    amd64) runner=ubuntu-24.04 ;;
  esac
  images_json+=("$(I=$name R=$runner yq -n -o=json -I=0 '{"image": strenv(I), "runner": strenv(R)}')")
done < <(yq -r '.images | keys | .[]' "$config")

join_json() {
  local IFS=,
  echo "[$*]"
}
output=${GITHUB_OUTPUT:-/dev/stdout}
{
  echo "release=$release"
  echo "publish=$publish"
  echo "images=$(join_json "${images_json[@]}")"
  echo "computers=$(join_json "${computers_json[@]}")"
} >>"$output"
