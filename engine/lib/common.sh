# shellcheck shell=bash disable=SC2034 # the scripts that source this use its values
# Shared by the engine's scripts: names, helpers, the input check (needs yq), the plan's readers,
# and the OS adapters. Sourced, never run. Everything but the input check runs in an image's chroot.

# ---------------------------------------------------------------------------------------------
# Names and paths.
# ---------------------------------------------------------------------------------------------
DATA_LABEL=paddock-data
IMG_DATA=/data
# Partitions start on 16 MiB boundaries, as Armbian's and Raspberry Pi OS's do.
ALIGN_MIB=16
# What the build brings into the chroot. The chroot's /run is a tmpfs, so none of it stays in the
# image.
RUN_DIR=/run/paddock
# Written at stamping, besides the adapters' own.
IMG_STAMPED="/etc/hostname /etc/hosts /etc/os-release /usr/lib/os-release"
# Kept in RAM on a read-only root, besides the adapters' own and the image's ram: list.
DEFAULT_RAM="/tmp /var/tmp /var/log"
# Never written by a step, kept, or put in RAM: the build's own mounts.
PSEUDO_FS="/dev /proc /sys /run"
DEFAULT_OS_PACKAGES=apt
DEFAULT_OS_INIT=systemd
DEFAULT_OS_NETWORK=networkmanager
DEFAULT_OS_FILESYSTEM=ext4
DEFAULT_ARCH=arm64
DEFAULT_GROW=1G
DEFAULT_MODE=0644
# Markers around what the engine writes into a base's files, so a rerun replaces its own block.
FSTAB_BEGIN="# --- Paddock: read-only root. What's written while the computer runs goes to $IMG_DATA or RAM. ---"
FSTAB_END="# --- end Paddock ---"
OS_RELEASE_MARK="# Paddock: this image's labels (os-release(5): IMAGE_ID, IMAGE_VERSION)."

# ---------------------------------------------------------------------------------------------
# Helpers.
# ---------------------------------------------------------------------------------------------
die() {
  say "$@"
  exit 1
}

say() {
  printf '%s: %s\n' "${0##*/}" "$*" >&2
}

# Prints the calling script's header comment (its usage) and exits.
usage() {
  sed -n '1d; /^#/!q; s/^# \{0,1\}//p' "$0"
  exit 0
}

# For option parsing: dies unless the option ($1) has a value after it.
need_value() {
  (($# >= 2)) || die "$1 needs a value"
}

# mikefarah's yq, version 4. Debian's and Ubuntu's "yq" package is a different program.
require_yq() {
  command -v yq >/dev/null 2>&1 || die "needs yq (mikefarah's, version 4): https://github.com/mikefarah/yq"
  case "$(yq --version 2>&1)" in
    *mikefarah*" v4."* | *mikefarah*" version 4."*) ;;
    *) die "needs mikefarah's yq version 4, found: $(yq --version 2>&1 | head -1)" ;;
  esac
}

is_sha256() {
  [[ $1 =~ ^[0-9a-f]{64}$ ]]
}

# A SHA-256 as GitHub or PowerShell shows it ("sha256:" prefix, upper case), in lower-case hex.
normal_sha256() {
  local sum=${1#sha256:}
  printf '%s' "${sum,,}"
}

# An image's name, which becomes os-release's IMAGE_ID.
is_name() {
  [[ $1 =~ ^[a-z0-9]([a-z0-9-]{0,62}[a-z0-9])?$ ]]
}

is_hostname() {
  [[ $1 =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ && $1 != localhost ]]
}

# A release's name: os-release's IMAGE_VERSION, and part of each image's file name.
is_release() {
  [[ $1 =~ ^[a-z0-9][a-z0-9._-]{0,63}$ ]]
}

# Four numbers 0 to 255, no leading zeros.
is_ipv4() {
  local IFS=. octet
  local -a octets
  [[ $1 =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
  read -r -a octets <<<"$1"
  for octet in "${octets[@]}"; do
    [[ $octet =~ ^(0|[1-9][0-9]*)$ ]] && ((octet <= 255)) || return 1
  done
}

ipv4_number() {
  local IFS=. a b c d
  read -r a b c d <<<"$1"
  echo $(((a << 24) | (b << 16) | (c << 8) | d))
}

same_subnet() {
  local mask=$(((0xffffffff << (32 - $3)) & 0xffffffff))
  ((($(ipv4_number "$1") & mask) == ($(ipv4_number "$2") & mask)))
}

# Why an address can't be a computer's, with its prefix; nothing if it can.
unusable_address() {
  local n first mask
  n=$(ipv4_number "$1")
  first=$((n >> 24))
  if ((first == 0 || first == 127 || first >= 224)); then
    echo "isn't an address a computer can have (0.x, 127.x, multicast, and reserved aren't)"
  elif (($2 <= 30)); then
    mask=$(((0xffffffff << (32 - $2)) & 0xffffffff))
    if (((n & mask) == n)); then
      echo "is its subnet's network address"
    elif (((n | (~mask & 0xffffffff)) == n)); then
      echo "is its subnet's broadcast address"
    fi
  fi
}

# A size such as 512M or 2G.
is_size() {
  [[ $1 =~ ^[1-9][0-9]{0,5}[MG]$ ]]
}

size_mib() {
  case $1 in
    *M) echo "${1%M}" ;;
    *G) echo $((${1%G} * 1024)) ;;
  esac
}

# 32 hex digits derived from text, so stamping twice writes the same files.
derived_hex() {
  printf '%s' "$1" | sha256sum | cut -c1-32
}

# A UUID (version 5 layout) derived from text.
derived_uuid() {
  local h variant
  h=$(derived_hex "$1")
  variant=$(printf '%x' $(((16#${h:16:1} & 3) | 8)))
  printf '%s-%s-5%s-%s%s-%s' "${h:0:8}" "${h:8:4}" "${h:13:3}" "$variant" "${h:17:3}" "${h:20:12}"
}

# A mode as the input writes it ("0644", 0644, or 644), as four octal digits.
file_mode() {
  printf '%04o' $((8#$1))
}

# A path from paddock.yaml's folder: names of letters, digits, '.', '_', '@', '+' and '-', none of
# them '.' or '..'. The engine relies on this to split space-separated path lists (KEEP, RAM)
# unquoted.
is_relative_path() {
  [[ /$1 =~ ^(/[A-Za-z0-9._@+-]+)+$ && ! /$1/ =~ /\.\.?/ ]]
}

# A path in the image, from its root.
is_image_path() {
  [[ $1 == /* ]] && is_relative_path "${1#/}"
}

# Whether path $1 is path $2 or inside it.
is_within() {
  [[ $1 == "$2" || $1 == "${2%/}"/* ]]
}

# Whether two paths are the same or one is inside the other.
overlaps() {
  is_within "$1" "$2" || is_within "$2" "$1"
}

# Replaces FILE atomically (temp file, chmod, rename), from stdin.
put() {
  mkdir -p "$(dirname "$1")"
  rm -f "$1.paddock-new"
  cat >"$1.paddock-new"
  chmod "$2" "$1.paddock-new"
  mv -fT "$1.paddock-new" "$1"
}

# put, for a file inside an image's root from outside it (stamping): refuses a path whose parts are
# links, which would resolve on the build machine instead of in the image.
put_in() {
  local root=$1 path=$2 part=$1 name names
  IFS=/ read -ra names <<<"${path#/}"
  for name in "${names[@]}"; do
    part=$part/$name
    [[ ! -L $part ]] || die "$path in the image goes through a link (${part#"$root"}): stamping won't follow it"
  done
  [[ ! -d $part ]] || die "$path in the image is a folder"
  put "$root$path" "$3"
}

# ---------------------------------------------------------------------------------------------
# Loop devices (build-image.sh, stamp-image.sh).
# ---------------------------------------------------------------------------------------------
# Attaches an image file with its partitions; prints the loop device.
attach_image() {
  local loop
  loop=$(losetup --find --show --partscan "$1") ||
    die "couldn't attach $1 to a loop device: run as root, in a container only if it's privileged with this machine's /dev (--privileged -v /dev:/dev)"
  udevadm settle 2>/dev/null || true
  printf '%s' "$loop"
}

# Waits up to 10 s for a partition's device to appear.
wait_for_device() {
  local i
  for ((i = 0; i < 100; i++)); do
    [[ -b $1 ]] && return 0
    sleep 0.1
  done
  die "$1 didn't appear"
}

# The number of partitions in an image file's table.
partition_count() {
  sfdisk --dump "$1" | grep -c '^[^:]*: *start=' || true
}

# ---------------------------------------------------------------------------------------------
# The OS adapters (engine/os/<axis>/<value>.sh). Every adapter of an axis defines the same
# functions (engine/os/README.md).
# ---------------------------------------------------------------------------------------------
ENGINE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OS_AXES="packages init network filesystem"

os_values() {
  local file
  for file in "$ENGINE_DIR/os/$1"/*.sh; do
    [[ -e $file ]] && basename "$file" .sh
  done
}

is_os_value() {
  is_name "$2" && [[ -f $ENGINE_DIR/os/$1/$2.sh ]]
}

# Calls function $3 of adapter $1/$2 without loading it into this shell.
adapter_says() {
  # shellcheck source=/dev/null
  (. "$ENGINE_DIR/os/$1/$2.sh" && "$3")
}

# Sources the adapters named by OS_PACKAGES, OS_INIT, OS_NETWORK and OS_FILESYSTEM.
load_adapters() {
  local axis value
  for axis in $OS_AXES; do
    value=OS_${axis^^}
    value=${!value:-}
    is_os_value "$axis" "$value" || die "no $axis adapter named '$value'"
    # shellcheck source=/dev/null
    . "$ENGINE_DIR/os/$axis/$value.sh"
  done
}

# ---------------------------------------------------------------------------------------------
# The plan, which plan.sh writes and the later jobs read with bash alone (plan.sh's header says
# what each file holds).
# ---------------------------------------------------------------------------------------------
load_plan() {
  [[ -f $1/plan.env ]] || die "no plan at $1 (plan.sh writes it)"
  # shellcheck source=/dev/null
  . "$1/plan.env"
}

# Sources an image's image.env and loads its adapters; IMAGE_DIR is its folder in the plan.
load_image() {
  IMAGE_DIR=$1/images/$2
  [[ -f $IMAGE_DIR/image.env ]] || die "no image named '$2' in the plan at $1"
  # shellcheck source=/dev/null
  . "$IMAGE_DIR/image.env"
  load_adapters
}

load_computer() {
  [[ -f $1/computers/$2.env ]] || die "no computer named '$2' in the plan at $1"
  # shellcheck source=/dev/null
  . "$1/computers/$2.env"
}

# ---------------------------------------------------------------------------------------------
# The input check (needs yq): check_config FILE dies listing every problem at once, or prints
# nothing. Paths in the input are from FILE's folder. README.md and docs/reference.md say what the
# input holds.
# ---------------------------------------------------------------------------------------------
CFG=""
CFG_DIR=""
PROBLEMS=()

cfg_problem() {
  PROBLEMS+=("$*")
}

# The YAML tag at a path (!!map, !!seq, !!str, !!int, !!null...).
cfg_tag() {
  yq -r "$1 | tag" "$CFG"
}

# A scalar's text, or nothing for a missing value, a list, or a map.
cfg_scalar() {
  case $(cfg_tag "$1") in
    '!!null' | '!!map' | '!!seq') ;;
    *) yq -r "$1" "$CFG" ;;
  esac
}

cfg_length() {
  yq -r "$1 | length" "$CFG"
}

# Names keys of the map at a path that aren't allowed, or are given twice (yq keeps both copies;
# YAML forbids it).
cfg_keys() {
  local key
  while IFS= read -r key; do
    [[ " $2 " == *" $key "* ]] || cfg_problem "$3: unknown key '$key' (it takes: ${2// /, })"
  done < <(yq -r "$1 | keys | .[]" "$CFG")
  while IFS= read -r key; do
    cfg_problem "$3: '$key' is given twice"
  done < <(yq -r "$1 | keys | group_by(.) | map(select(length > 1) | .[0]) | .[]" "$CFG")
}

# A file of paddock.yaml's folder: not a link, which could reach outside it.
cfg_file() {
  [[ -f $CFG_DIR/$1 && ! -L $CFG_DIR/$1 ]] &&
    [[ $(realpath -e "$CFG_DIR/$1") == "$(realpath -e "$CFG_DIR")"/* ]]
}

# A SHA-256 at a path, as typed (prefixed or upper case is fine).
cfg_sha256() {
  local value
  value=$(cfg_scalar "$1")
  if [[ -z $value ]]; then
    cfg_problem "$2 has no sha256"
  elif ! is_sha256 "$(normal_sha256 "$value")"; then
    cfg_problem "$2: sha256 '$value' isn't a SHA-256 (64 hex digits)"
  fi
}

# Why an image path can't be written by a step, kept, or put in RAM; nothing if it can. $2 says
# what it's for.
cfg_bad_path() {
  local path=$1 fs
  if ! is_image_path "$path"; then
    echo "'$path' isn't a path in the image, from its root (such as /etc/team/tool.yaml)"
    return
  fi
  for fs in $PSEUDO_FS; do
    if is_within "$path" "$fs"; then
      echo "$path is under $fs, which the build mounts itself"
      return
    fi
  done
}

# The paths stamping writes for an image with these init and network adapters.
cfg_stamped() {
  printf '%s %s %s' "$IMG_STAMPED" "$(adapter_says init "$1" init_stamped_paths)" \
    "$(adapter_says network "$2" network_stamped_paths)"
}

check_config() {
  local kind name
  CFG=$1
  CFG_DIR=${2:-$(dirname "$1")}
  PROBLEMS=()
  [[ -f $CFG ]] || die "no input at $CFG"
  kind=$(yq -r 'tag' "$CFG" 2>&1) || die "$CFG isn't YAML: $kind"
  [[ $kind == '!!map' ]] || die "$CFG: expected images and computers"
  cfg_keys . "images computers" "$CFG"

  # Each image's stamped, RAM and kept paths, for its computers' files.
  local -A images=() image_stamped=() image_ram=() image_keep=()
  if [[ $(cfg_tag .images) != '!!map' ]]; then
    cfg_problem "images must name each image: its base (from:) and what's added to it (steps:)"
  else
    while IFS= read -r name; do
      if is_name "$name"; then
        images[$name]=1
        check_image "$name"
      else
        cfg_problem "images.$name: '$name' can't be an image's name: lowercase letters, digits, and hyphens"
      fi
    done < <(yq -r '.images | keys | .[]' "$CFG")
    ((${#images[@]})) || cfg_problem "images names none: name at least one"
  fi
  check_computers images

  if ((${#PROBLEMS[@]})); then
    local list
    printf -v list '\n  - %s' "${PROBLEMS[@]}"
    die "$CFG has ${#PROBLEMS[@]} problem$( ((${#PROBLEMS[@]} == 1)) || echo s):$list"
  fi
}

check_image() {
  local name=$1 p=".images[\"$1\"]" what="images.$1"
  local value axis stamped ram=""
  if [[ $(cfg_tag "$p") != '!!map' ]]; then
    cfg_problem "$what must be an image: its from:, and its steps:"
    return
  fi
  cfg_keys "$p" "from os grow steps read-only" "$what"

  if [[ $(cfg_tag "$p.from") != '!!map' ]]; then
    cfg_problem "$what.from must be its base: url and sha256"
  else
    cfg_keys "$p.from" "url sha256 arch" "$what.from"
    value=$(cfg_scalar "$p.from.url")
    [[ $value =~ ^https://[A-Za-z0-9:/._~%+-]+\.img(\.xz|\.gz)?$ ]] ||
      cfg_problem "$what.from.url '$value' isn't the https:// address of a disk image (.img, .img.xz, or .img.gz)"
    cfg_sha256 "$p.from.sha256" "$what.from"
    value=$(cfg_scalar "$p.from.arch")
    [[ -z $value || $value == arm64 || $value == amd64 ]] ||
      cfg_problem "$what.from.arch '$value' isn't arm64 or amd64"
  fi

  local -A os=([packages]=$DEFAULT_OS_PACKAGES [init]=$DEFAULT_OS_INIT
    [network]=$DEFAULT_OS_NETWORK [filesystem]=$DEFAULT_OS_FILESYSTEM)
  case $(cfg_tag "$p.os") in
    '!!map')
      cfg_keys "$p.os" "$OS_AXES" "$what.os"
      for axis in $OS_AXES; do
        [[ $(cfg_tag "$p.os.$axis") == '!!null' ]] && continue
        value=$(cfg_scalar "$p.os.$axis")
        if is_os_value "$axis" "$value"; then
          os[$axis]=$value
        else
          cfg_problem "$what.os.$axis '$value' isn't supported yet (supported: $(os_values "$axis" | paste -sd ' '))"
        fi
      done
      ;;
    '!!null') ;;
    *) cfg_problem "$what.os must say how its base works: $OS_AXES" ;;
  esac
  stamped=$(cfg_stamped "${os[init]}" "${os[network]}")

  value=$(cfg_scalar "$p.grow")
  [[ $(cfg_tag "$p.grow") == '!!null' ]] || is_size "$value" ||
    cfg_problem "$what.grow '$value' isn't a size, such as 512M or 2G"

  case $(cfg_tag "${p}[\"read-only\"]") in
    '!!map')
      ram="$DEFAULT_RAM $(adapter_says init "${os[init]}" init_ram_paths) $(adapter_says network "${os[network]}" network_ram_paths)"
      check_read_only "${p}[\"read-only\"]" "$what.read-only" "$stamped" "$ram"
      ram="$ram $(yq -r "(${p}[\"read-only\"].ram // []) | join(\" \")" "$CFG")"
      image_keep[$name]=$(yq -r "(${p}[\"read-only\"].keep // []) | join(\" \")" "$CFG")
      ;;
    '!!null') ;;
    *) cfg_problem "$what.read-only must give the data partition's size (data:), and what it keeps (keep:)" ;;
  esac
  image_stamped[$name]=$stamped
  image_ram[$name]=$ram

  case $(cfg_tag "$p.steps") in
    '!!seq') check_steps "$p.steps" "$what" "$stamped" "$ram" ;;
    '!!null') ;;
    *) cfg_problem "$what.steps must be a list of steps" ;;
  esac
}

# A file of paddock.yaml's folder, named at a path: WHAT's problem if it isn't one.
cfg_repo_file() {
  local path
  path=$(cfg_scalar "$1")
  if ! is_relative_path "$path"; then
    cfg_problem "$2: '$path' isn't a path from paddock.yaml's folder (no leading '/', no '..')"
  elif ! cfg_file "$path"; then
    cfg_problem "$2: $path isn't a file in paddock.yaml's folder (names are case-sensitive)"
  fi
}

# Where a file goes in the image (the to: at a path), and its mode. STAMPED, RAM and KEEP are the
# image's paths; RAM is empty for an image without a read-only root, KEEP is for computers' files,
# which are written after the kept paths moved to the data partition.
cfg_target() {
  local s=$1 what=$2 stamped=$3 ram=$4 keep=${5-} to why value mode
  to=$(cfg_scalar "$s.to")
  why=$(cfg_bad_path "$to")
  if [[ -z $to ]]; then
    cfg_problem "$what has no to: (where the file goes in the image)"
  elif [[ -n $why ]]; then
    cfg_problem "$what: to $why"
  elif [[ " $stamped " == *" $to "* ]]; then
    cfg_problem "$what: $to is written at stamping, with the computer's identity"
  elif [[ -n $ram ]] && is_within "$to" "$IMG_DATA"; then
    cfg_problem "$what: $to is under $IMG_DATA, where the data partition is mounted"
  else
    for value in $ram; do
      if is_within "$to" "$value"; then
        cfg_problem "$what: $to is under $value, which is in RAM and empty at every boot"
        break
      fi
    done
    for value in $keep; do
      if is_within "$to" "$value"; then
        cfg_problem "$what: $to is under $value, which is kept on the data partition: the root's copy would be hidden"
        break
      fi
    done
  fi
  mode=$(cfg_scalar "$s.mode")
  [[ $(cfg_tag "$s.mode") == '!!null' ]] ||
    [[ $(cfg_tag "$s.mode") =~ ^!!(int|str)$ && $mode =~ ^0?[0-7]{3}$ ]] ||
    cfg_problem "$what: mode '$mode' isn't a file's mode in octal, such as \"0644\""
}

# check_steps PATH WHAT STAMPED RAM: RAM is empty for an image without a read-only root.
check_steps() {
  local p=$1 what=$2 stamped=$3 ram=$4
  local n i s sw kinds path value
  n=$(cfg_length "$p")
  for ((i = 0; i < n; i++)); do
    s="${p}[$i]"
    sw="$what step $((i + 1))"
    if [[ $(cfg_tag "$s") != '!!map' ]]; then
      cfg_problem "$sw must be a step: file:, download:, package:, or run:"
      continue
    fi
    kinds=$(yq -r "$s | keys | map(select(. == \"file\" or . == \"download\" or . == \"package\" or . == \"run\")) | join(\" \")" "$CFG")
    [[ $kinds == file || $kinds == download || $kinds == package || $kinds == run ]] &&
      sw="$sw ($kinds: $(cfg_scalar "$s.$kinds"))"
    case $kinds in
      file | download)
        if [[ $kinds == file ]]; then
          cfg_keys "$s" "file to mode" "$sw"
          cfg_repo_file "$s.file" "$sw"
        else
          cfg_keys "$s" "download sha256 to mode" "$sw"
          value=$(cfg_scalar "$s.download")
          [[ $value =~ ^https://[A-Za-z0-9:/._~%+-]+$ && $value != */ ]] ||
            cfg_problem "$sw: '$value' isn't the https:// address of a file"
          cfg_sha256 "$s.sha256" "$sw"
        fi
        cfg_target "$s" "$sw" "$stamped" "$ram"
        ;;
      package)
        cfg_keys "$s" "package sha256" "$sw"
        value=$(cfg_scalar "$s.package")
        [[ $value =~ ^https://[A-Za-z0-9:/._~%+-]+\.deb$ ]] ||
          cfg_problem "$sw: '$value' isn't the https:// address of a .deb (what apt installs)"
        cfg_sha256 "$s.sha256" "$sw"
        ;;
      run)
        cfg_keys "$s" "run" "$sw"
        path=$(cfg_scalar "$s.run")
        if ! is_relative_path "$path"; then
          cfg_problem "$sw: '$path' isn't a path from paddock.yaml's folder (no leading '/', no '..')"
        elif ! cfg_file "$path"; then
          cfg_problem "$sw: $path isn't a file in paddock.yaml's folder (names are case-sensitive)"
        elif grep -q $'\r' "$CFG_DIR/$path"; then
          cfg_problem "$sw: $path has Windows line endings (CRLF), which bash can't run: save it with LF"
        fi
        ;;
      *)
        cfg_problem "$sw must be exactly one of file:, download:, package:, or run:"
        ;;
    esac
  done
}

# check_read_only PATH WHAT STAMPED DEFAULT_RAM
check_read_only() {
  local p=$1 what=$2 stamped=$3 default_ram=$4
  local list n j path why seen stamp
  cfg_keys "$p" "data keep ram" "$what"
  path=$(cfg_scalar "$p.data")
  is_size "$path" || cfg_problem "$what.data '$path' isn't a size, such as 2G: the data partition's"
  for list in keep ram; do
    case $(cfg_tag "$p.$list") in
      '!!null') continue ;;
      '!!seq') ;;
      *)
        cfg_problem "$what.$list must be a list of paths in the image"
        continue
        ;;
    esac
    seen=" "
    n=$(cfg_length "$p.$list")
    for ((j = 0; j < n; j++)); do
      path=$(cfg_scalar "$p.${list}[$j]")
      why=$(cfg_bad_path "$path")
      if [[ -n $why ]]; then
        cfg_problem "$what.$list: $why"
        continue
      elif is_within "$path" "$IMG_DATA"; then
        cfg_problem "$what.$list: $path is under $IMG_DATA, the data partition itself"
        continue
      elif [[ $seen == *" $path "* ]]; then
        cfg_problem "$what.$list: $path is listed twice"
        continue
      fi
      seen+="$path "
      for stamp in $stamped; do
        if overlaps "$path" "$stamp"; then
          cfg_problem "$what.$list: $path would hide $stamp, which stamping writes for each computer"
          break
        fi
      done
      if [[ $list == keep && " $default_ram " == *" $path "* ]]; then
        cfg_problem "$what.keep: $path is in RAM on a read-only root, so it can't also be kept"
      fi
    done
  done
  # A path both kept and in RAM.
  while IFS= read -r path; do
    [[ -n $path ]] && cfg_problem "$what: $path is both kept and in RAM"
  done < <(yq -r "((.keep // []) - ((.keep // []) - (.ram // [])))[]" <<<"$(yq "$p" "$CFG")")
}

# check_computers IMAGES_ARRAY_NAME
check_computers() {
  local -n known=$1
  local n i c what hostname image text address prefix gateway value why k m
  local -A hostnames=() addresses=()
  if [[ $(cfg_tag .computers) != '!!seq' ]]; then
    cfg_problem "computers must be a list of computers, each a hostname, image, and address"
    return
  fi
  n=$(cfg_length .computers)
  ((n > 0)) || cfg_problem "computers lists none: list each computer"
  for ((i = 0; i < n; i++)); do
    what="computers[$((i + 1))]"
    c=".computers[$i]"
    if [[ $(cfg_tag "$c") != '!!map' ]]; then
      cfg_problem "$what must be a computer: its hostname, image, and address"
      continue
    fi
    cfg_keys "$c" "hostname image address gateway dns files" "$what"
    hostname=$(cfg_scalar "$c.hostname")
    if [[ -z $hostname ]]; then
      cfg_problem "$what has no hostname"
    elif ! is_hostname "$hostname"; then
      cfg_problem "$what: '$hostname' can't be a hostname: lowercase letters, digits, and hyphens (such as $(tr 'A-Z_ ' 'a-z--' <<<"$hostname" | tr -cd 'a-z0-9-'))"
    else
      what=$hostname
      [[ -z ${hostnames[$hostname]:-} ]] || cfg_problem "two computers have the hostname $hostname"
      hostnames[$hostname]=1
    fi
    image=$(cfg_scalar "$c.image")
    if [[ -z $image ]]; then
      cfg_problem "$what has no image (one of images:)"
    elif [[ -z ${known[$image]:-} ]]; then
      cfg_problem "$what's image '$image' isn't one of images:"
    fi
    text=$(cfg_scalar "$c.address")
    address=${text%/*} prefix=${text##*/}
    if [[ -z $text ]]; then
      cfg_problem "$what has no address (an IPv4 address and prefix, such as 10.12.34.11/24)"
    elif [[ $text != */* ]] || ! is_ipv4 "$address" || ! [[ $prefix =~ ^([1-9]|[12][0-9]|3[0-2])$ ]]; then
      cfg_problem "$what's address '$text' isn't an IPv4 address and prefix, such as 10.12.34.11/24"
    elif why=$(unusable_address "$address" "$prefix") && [[ -n $why ]]; then
      cfg_problem "$what's address $text $why"
    elif [[ -n ${addresses[$address]:-} ]]; then
      cfg_problem "two computers have the address $address (${addresses[$address]} and $what)"
    else
      addresses[$address]=$what
      if [[ $(cfg_tag "$c.gateway") != '!!null' ]]; then
        gateway=$(cfg_scalar "$c.gateway")
        if ! is_ipv4 "$gateway"; then
          cfg_problem "$what's gateway '$gateway' isn't an IPv4 address"
        elif [[ $gateway == "$address" ]]; then
          cfg_problem "$what's gateway is its own address"
        elif ! same_subnet "$address" "$gateway" "$prefix"; then
          cfg_problem "$what's gateway $gateway isn't in its subnet, $text"
        elif why=$(unusable_address "$gateway" "$prefix") && [[ -n $why ]]; then
          cfg_problem "$what's gateway $gateway $why"
        fi
      fi
    fi
    case $(cfg_tag "$c.dns") in
      '!!seq')
        m=$(cfg_length "$c.dns")
        for ((k = 0; k < m; k++)); do
          value=$(cfg_scalar "$c.dns[$k]")
          is_ipv4 "$value" || cfg_problem "$what's dns '$value' isn't an IPv4 address"
        done
        ;;
      '!!null') ;;
      *) cfg_problem "$what's dns must be a list of IPv4 addresses" ;;
    esac
    case $(cfg_tag "$c.files") in
      '!!seq') check_computer_files "$c.files" "$what" "$image" ;;
      '!!null') ;;
      *) cfg_problem "$what's files must be a list, each a file: and its to:" ;;
    esac
  done
}

# check_computer_files PATH WHAT IMAGE: a computer's own files, checked like file steps against its
# image's paths, kept paths included.
check_computer_files() {
  local p=$1 what=$2 image=$3 n j f fw to seen=" "
  n=$(cfg_length "$p")
  for ((j = 0; j < n; j++)); do
    f="${p}[$j]"
    fw="$what's file $((j + 1))"
    if [[ $(cfg_tag "$f") != '!!map' ]]; then
      cfg_problem "$fw must be a file: and its to:"
      continue
    fi
    fw="$fw ($(cfg_scalar "$f.file"))"
    cfg_keys "$f" "file to mode" "$fw"
    cfg_repo_file "$f.file" "$fw"
    cfg_target "$f" "$fw" "${image_stamped[$image]:-$IMG_STAMPED}" "${image_ram[$image]:-}" \
      "${image_keep[$image]:-}"
    to=$(cfg_scalar "$f.to")
    [[ -z $to || $seen != *" $to "* ]] || cfg_problem "$fw: $to is listed twice"
    seen+="$to "
  done
}
