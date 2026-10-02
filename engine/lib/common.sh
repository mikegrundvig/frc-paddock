# shellcheck shell=bash disable=SC2034 # the scripts that source this use its values
# Shared by the engine's scripts and the recipes: the names, sizes, and paths every step agrees on,
# and the readers of Paddock's input (paddock.yaml), the recipe, and the locks. Sourced, never run.
#
# A recipe's provision.sh sources this inside the image's chroot, where there's no yq: only the
# functions that say so need it.

# ---------------------------------------------------------------------------------------------
# The drive's layout, the same on every board (a recipe's board files hold what differs).
# ---------------------------------------------------------------------------------------------
COPROC_LABEL=COPROC          # small FAT partition: the stamp record, readable on Windows
COPROC_MIB=32
DATA_LABEL=coproc-data       # ext4: everything that's written while the computer runs
DATA_MIB=${COPROC_DATA_MIB:-8192}  # the tests set COPROC_DATA_MIB to keep their images small
ALIGN_MIB=16                 # partitions start on 16 MiB, as Armbian's own do

# On the image.
IMG_DATA=/data
IMG_JOURNAL=/var/log/journal
IMG_CONNECTION=/etc/NetworkManager/system-connections/robot.nmconnection
# The files stamping writes into the root, which none of the team's files may be.
IMG_STAMPED="/etc/hostname /etc/hosts /etc/machine-id /etc/os-release /usr/lib/os-release $IMG_CONNECTION"
# On /data.
DATA_JOURNAL=journal
DATA_SSH=ssh

# The robot network (docs.wpilib.org, "IP Configurations"): static addresses for on-robot
# devices are 10.TE.AM.6 to 10.TE.AM.19, netmask 255.255.255.0, gateway 10.TE.AM.4.
ADDRESS_MIN=6
ADDRESS_MAX=19
NETMASK_BITS=24
GATEWAY_OCTET=4

# The recipe used when the caller names none.
DEFAULT_RECIPE=photonvision-orangepi

# ---------------------------------------------------------------------------------------------
# Helpers.
# ---------------------------------------------------------------------------------------------
die() {
  printf '%s: %s\n' "${0##*/}" "$*" >&2
  exit 1
}

say() {
  printf '%s: %s\n' "${0##*/}" "$*" >&2
}

# mikefarah's yq, version 4: the one the workflow's runners have. The Debian and Ubuntu "yq"
# package is a different program with a different language.
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

# A recipe's or board's name: lowercase letters, digits, and hyphens.
is_name() {
  [[ $1 =~ ^[a-z0-9]([a-z0-9-]{0,62}[a-z0-9])?$ ]]
}

# Sources a recipe's recipe.env, from its folder; sets RECIPE_DIR to the folder.
load_recipe() {
  local dir=$1
  [[ -f $dir/recipe.env ]] || die "no recipe at $dir (no recipe.env)"
  RECIPE_DIR=$(cd "$dir" && pwd)
  # shellcheck source=../../recipes/photonvision-orangepi/recipe.env
  . "$RECIPE_DIR/recipe.env"
  [[ -n ${RECIPE_BOARDS:-} ]] || die "$RECIPE_DIR/recipe.env names no boards (RECIPE_BOARDS)"
}

# Whether the loaded recipe builds for this board.
is_board() {
  local b
  for b in $RECIPE_BOARDS; do
    [[ $b == "$1" ]] && return 0
  done
  return 1
}

# Sources the loaded recipe's file for a board.
load_board() {
  is_board "$1" || die "board '$1' isn't one of the recipe's: $RECIPE_BOARDS"
  # shellcheck source=../../recipes/photonvision-orangepi/boards/orangepi-5.env
  . "$RECIPE_DIR/boards/$1.env"
}

# A computer's name becomes its hostname: lowercase letters, digits, and hyphens, starting and
# ending with a letter or digit.
is_hostname() {
  [[ $1 =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]
}

# "10.TE.AM" for a team number: TE is all but the last two digits, AM the last two.
team_prefix() {
  printf '10.%d.%d' $((10#$1 / 100)) $((10#$1 % 100))
}

# 32 hex digits derived from text: stable, so stamping the same computer twice writes the same files.
derived_hex() {
  printf '%s' "$1" | sha256sum | cut -c1-32
}

# A UUID (version 5 layout) derived from text.
derived_uuid() {
  local h variant
  h=$(printf '%s' "$1" | sha256sum | cut -c1-32)
  variant=$(printf '%x' $(((16#${h:16:1} & 3) | 8)))
  printf '%s-%s-5%s-%s%s-%s' "${h:0:8}" "${h:8:4}" "${h:13:3}" "$variant" "${h:17:3}" "${h:20:12}"
}

# Reads a value from Paddock's input (needs yq). Prints nothing for a missing value.
config_get() {
  yq -r "$1 // \"\"" "$2"
}

# Reads a value from a lock, JSON or YAML (needs yq). Per-board values take the board in BOARD.
lock_get() {
  yq -p yaml -o yaml -r "$1 // \"\"" "$2"
}

# A file's mode in octal, as Paddock's input writes it ("0644", 0644, or 644): four digits.
file_mode() {
  printf '%04o' $((8#$1))
}

# A path in the team's repository, from its root: names of letters, digits, '.', '_', '@', '+',
# and '-', joined by '/', none of them '.' or '..'. With a leading '/', a path in the image.
is_relative_path() {
  [[ /$1 =~ ^(/[A-Za-z0-9._@+-]+)+$ && ! /$1/ =~ /\.\.?/ ]]
}

is_image_path() {
  [[ $1 == /* ]] && is_relative_path "${1#/}"
}

# Checks Paddock's input (paddock.yaml) whole, for the loaded recipe (needs yq), and dies listing
# every problem it found, or prints nothing. REPO, when given, is the team's repository, where each
# of the files' paths must be a file. The input holds:
#   team        the team number
#   computers   each computer's hostname, address (the last number of 10.TE.AM.x), and board
#   packages    each package (.deb) the images get: its https url and its sha256
#   files       each file the images get: its path in the team's repository, its destination in
#               the image, and its mode
# and nothing else: a key it doesn't know, or a key given twice, is a problem too. Numbers are
# written plainly (no leading zeros, which bash would read as octal), and compared as numbers.
check_config() {
  local config=$1 repo=${2-} kind value n i what hostname address board url path destination mode
  local -a problems=()
  local -A hostnames=() addresses=() urls=() destinations=()
  [[ -f $config ]] || die "no input at $config"
  kind=$(yq -r 'tag' "$config" 2>&1) || die "$config isn't YAML: $kind"
  [[ $kind == '!!map' ]] || die "$config: expected team, computers, packages, and files"

  # Keys of the map at a path that aren't allowed, or are given twice (yq keeps both; YAML forbids
  # it).
  config_keys() {
    local key
    while IFS= read -r key; do
      [[ " $2 " == *" $key "* ]] || problems+=("$3: unknown key '$key' (it takes: ${2// /, })")
    done < <(yq -r "$1 | keys | .[]" "$config")
    while IFS= read -r key; do
      problems+=("$3: '$key' is given twice")
    done < <(yq -r "$1 | keys | group_by(.) | map(select(length > 1) | .[0]) | .[]" "$config")
  }
  # A scalar's text at a path, or nothing for a missing value, a list, or a mapping.
  scalar() {
    case $(yq -r "$1 | tag" "$config") in
      '!!null' | '!!map' | '!!seq') ;;
      *) yq -r "$1" "$config" ;;
    esac
  }

  config_keys . "team computers packages files" "$config"
  value=$(scalar .team)
  if ! [[ $(yq -r '.team | tag' "$config") == '!!int' && $value =~ ^[1-9][0-9]{0,4}$ ]] ||
    ((10#$value > 25599)); then
    problems+=("team '$value' isn't a team number (1 to 25599, no leading zeros): set your team's")
  fi

  kind=$(yq -r '.computers | tag' "$config")
  if [[ $kind != '!!seq' ]]; then
    problems+=("computers must be a list of computers, each a hostname, address, and board")
  else
    n=$(yq -r '.computers | length' "$config")
    ((n > 0)) || problems+=("computers lists none: list each computer")
    for ((i = 0; i < n; i++)); do
      what="computers[$i]"
      if [[ $(yq -r ".computers[$i] | tag" "$config") != '!!map' ]]; then
        problems+=("$what must be a computer: its hostname, address, and board")
        continue
      fi
      config_keys ".computers[$i]" "hostname address board" "$what"
      hostname=$(scalar ".computers[$i].hostname")
      address=$(scalar ".computers[$i].address")
      board=$(scalar ".computers[$i].board")
      if [[ -z $hostname ]]; then
        problems+=("$what has no hostname")
      elif ! is_hostname "$hostname"; then
        problems+=("$what: '$hostname' can't be a hostname: lowercase letters, digits, and hyphens, starting and ending with a letter or digit")
      else
        what=$hostname
        [[ -z ${hostnames[$hostname]:-} ]] || problems+=("two computers have the hostname $hostname")
        hostnames[$hostname]=1
      fi
      if [[ -z $address ]]; then
        problems+=("$what has no address (the last number of 10.TE.AM.x, $ADDRESS_MIN to $ADDRESS_MAX)")
      elif ! [[ $(yq -r ".computers[$i].address | tag" "$config") == '!!int' && $address =~ ^[1-9][0-9]?$ ]] ||
        ((10#$address < ADDRESS_MIN || 10#$address > ADDRESS_MAX)); then
        problems+=("$what's address '$address' is outside FRC's range for on-robot devices, $ADDRESS_MIN to $ADDRESS_MAX (the last number of 10.TE.AM.x, no leading zeros)")
      elif [[ -n ${addresses[$address]:-} ]]; then
        problems+=("two computers have the address $address (${addresses[$address]} and $what)")
      else
        addresses[$address]=$what
      fi
      if [[ -z $board ]]; then
        problems+=("$what has no board (one of: $RECIPE_BOARDS)")
      elif ! is_board "$board"; then
        problems+=("$what's board '$board' isn't one of the recipe's: $RECIPE_BOARDS")
      fi
    done
  fi

  kind=$(yq -r '.packages | tag' "$config")
  if [[ $kind == '!!seq' ]]; then
    n=$(yq -r '.packages | length' "$config")
    for ((i = 0; i < n; i++)); do
      what="packages[$i]"
      if [[ $(yq -r ".packages[$i] | tag" "$config") != '!!map' ]]; then
        problems+=("$what must be a package: its url and sha256")
        continue
      fi
      config_keys ".packages[$i]" "url sha256" "$what"
      url=$(scalar ".packages[$i].url")
      if ! [[ $url =~ ^https://[A-Za-z0-9:/._~%+-]+\.deb$ ]]; then
        problems+=("$what: url '$url' isn't the https:// address of a .deb")
      elif [[ -n ${urls[$url]:-} ]]; then
        problems+=("$what: $url is listed twice")
      else
        urls[$url]=1
      fi
      is_sha256 "$(scalar ".packages[$i].sha256")" ||
        problems+=("$what: sha256 '$(scalar ".packages[$i].sha256")' isn't a SHA-256 (64 lowercase hex digits)")
    done
  elif [[ $kind != '!!null' ]]; then
    problems+=("packages must be a list of packages, each a url and sha256")
  fi

  kind=$(yq -r '.files | tag' "$config")
  if [[ $kind == '!!seq' ]]; then
    n=$(yq -r '.files | length' "$config")
    for ((i = 0; i < n; i++)); do
      what="files[$i]"
      if [[ $(yq -r ".files[$i] | tag" "$config") != '!!map' ]]; then
        problems+=("$what must be a file: its path, destination, and mode")
        continue
      fi
      config_keys ".files[$i]" "path destination mode" "$what"
      path=$(scalar ".files[$i].path")
      destination=$(scalar ".files[$i].destination")
      mode=$(scalar ".files[$i].mode")
      if ! is_relative_path "$path"; then
        problems+=("$what: path '$path' isn't a path in the team's repository, from its root (no leading '/', no '..')")
      elif [[ -n $repo ]]; then
        # A file of the repository's own: not a link, which could reach outside it.
        if [[ ! -f $repo/$path || -L $repo/$path ]] ||
          [[ $(realpath -e "$repo/$path") != "$(realpath -e "$repo")"/* ]]; then
          problems+=("$what: $path isn't a file in the team's repository")
        fi
      fi
      if ! is_image_path "$destination"; then
        problems+=("$what: destination '$destination' isn't a path in the image, from its root (such as /etc/team/settings.yaml)")
      elif [[ $destination == "$IMG_DATA" || $destination == "$IMG_DATA"/* ]]; then
        problems+=("$what: destination $destination is on the data partition, which stamping fills: give a place on the root")
      elif [[ " $IMG_STAMPED " == *" $destination "* ]]; then
        problems+=("$what: destination $destination is written at stamping, with the computer's identity")
      elif [[ -n ${destinations[$destination]:-} ]]; then
        problems+=("$what: two files have the destination $destination")
      else
        destinations[$destination]=1
      fi
      [[ $(yq -r ".files[$i].mode | tag" "$config") =~ ^!!(int|str)$ && $mode =~ ^0?[0-7]{3}$ ]] ||
        problems+=("$what: mode '$mode' isn't a file's mode in octal, such as \"0644\"")
    done
  elif [[ $kind != '!!null' ]]; then
    problems+=("files must be a list of files, each a path, destination, and mode")
  fi

  if ((${#problems[@]})); then
    printf -v value '\n  - %s' "${problems[@]}"
    die "$config has ${#problems[@]} problem$( ((${#problems[@]} == 1)) || echo s):$value"
  fi
}
