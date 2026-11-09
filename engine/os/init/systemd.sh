# shellcheck shell=bash
# The systemd adapter (os: init: systemd): the machine ID, and the state systemd writes while the
# computer runs.

init_check_base() {
  local root=${1%/}
  [[ -x $root/usr/lib/systemd/systemd || -x $root/lib/systemd/systemd ]] ||
    echo "no systemd (/usr/lib/systemd/systemd): the systemd adapter needs it"
  return 0
}

init_stamped_paths() {
  echo /etc/machine-id
}

init_ram_paths() {
  echo /var/lib/systemd
}

# The image every computer is stamped from carries no machine ID.
init_clear_machine_id() {
  local root=${1%/}
  put "$root/etc/machine-id" 0444 </dev/null
  if [[ -d $root/var/lib/dbus ]]; then
    ln -sfn /etc/machine-id "$root/var/lib/dbus/machine-id"
  fi
}

# Fixed in the image: on a read-only root systemd would otherwise make a new one at every boot,
# treat each boot as the first, and start the journal afresh.
init_write_machine_id() {
  put_in "${1%/}" /etc/machine-id 0444 <<<"$2"
}

# --- Inspecting a built image (inspect-root.sh), from outside it, with the build machine's
# systemd-analyze and fstab generator. Each prints a problem a line. ---

# Where systemd finds units, in the image.
SYSTEMD_UNIT_DIRS="/etc/systemd/system /usr/local/lib/systemd/system /usr/lib/systemd/system /lib/systemd/system"
SYSTEMD_FSTAB_GENERATOR=/usr/lib/systemd/system-generators/systemd-fstab-generator

init_inspect_tools() {
  command -v systemd-analyze >/dev/null ||
    echo "the build machine has no systemd-analyze, which inspecting a systemd image needs"
  [[ -x $SYSTEMD_FSTAB_GENERATOR ]] ||
    echo "the build machine has no $SYSTEMD_FSTAB_GENERATOR, which inspecting a systemd image needs"
  return 0
}

# Whether a unit dir in the image has a file of that name (not a link).
systemd_unit_file() {
  local root=$1 name=$2 dir
  for dir in $SYSTEMD_UNIT_DIRS; do
    [[ -f $root$dir/$name && ! -L $root$dir/$name ]] && return 0
  done
  return 1
}

# Whether the image has a unit of that name (a template's, for an instance): its file, or an alias
# (a link to another unit's file, as autovt@.service is getty@.service's), not just a mask.
systemd_has_unit() {
  local root=$1 unit=$2 dir name names=$2 link
  if [[ $unit =~ ^([^@]+@)[^.]+(\..+)$ ]]; then
    names+=" ${BASH_REMATCH[1]}${BASH_REMATCH[2]}"
  fi
  for name in $names; do
    systemd_unit_file "$root" "$name" && return 0
    for dir in $SYSTEMD_UNIT_DIRS; do
      [[ -L $root$dir/$name ]] || continue
      link=$(readlink "$root$dir/$name")
      [[ $link != /dev/null ]] || continue
      systemd_unit_file "$root" "${link##*/}" && return 0
    done
  done
  return 1
}

# The units the image masks: links to /dev/null in /etc/systemd/system.
systemd_masks() {
  local root=$1 link
  for link in "$root"/etc/systemd/system/*; do
    [[ -L $link && $(readlink "$link") == /dev/null ]] && basename "$link"
  done
  return 0
}

# A unit through systemd-analyze verify: its file, its drop-ins, and the programs it runs. A key or
# section systemd doesn't know is a problem too, in the image's own configuration (/etc).
systemd_verify() {
  local root=$1 unit=$2 output status=0
  output=$(systemd-analyze verify --root="$root" --man=no --recursive-errors=no "$unit" 2>&1) || status=$?
  # Paths as the image has them.
  output=${output//"$root"/}
  if ((status != 0)); then
    echo "$unit doesn't pass systemd-analyze verify: ${output//$'\n'/; }"
  elif grep -E '^/etc/.*Unknown (key|section)' <<<"$output" >/dev/null; then
    echo "$unit: $(grep -E '^/etc/.*Unknown (key|section)' <<<"$output" | paste -sd ';' -) (this build machine's systemd is $(systemd-analyze --version | awk 'NR == 1 { print $2 }'))"
  fi
  return 0
}

# What any systemd image's configuration must pass: each unit file and drop-in the image's own
# configuration has (/etc/systemd/system) verified, each mask a unit the image has (a misspelt name
# in `systemctl mask` makes a mask of nothing), and the fstab read by systemd's generator.
init_inspect() {
  local root=${1%/} path name units=() masks
  masks=" $(systemd_masks "$root" | paste -sd ' ') "
  for path in "$root"/etc/systemd/system/*; do
    name=${path##*/}
    if [[ -f $path && ! -L $path ]] && is_unit_name "$name"; then
      units+=("$name")
    elif [[ -d $path && ! -L $path && $name == *.d ]] && is_unit_name "${name%.d}"; then
      name=${name%.d}
      # A template's drop-ins apply to its instances, which systemd-analyze can't verify unnamed.
      [[ $name != *@.* && $masks != *" $name "* ]] || continue
      if systemd_has_unit "$root" "$name"; then
        units+=("$name")
      else
        echo "/etc/systemd/system/$name.d has drop-ins for $name, but the image has no $name"
      fi
    fi
  done
  for name in $(printf '%s\n' "${units[@]}" | sort -u); do
    systemd_verify "$root" "$name"
  done
  for name in $masks; do
    systemd_has_unit "$root" "$name" ||
      echo "$name is masked, but the image has no unit of that name: is it spelt right?"
  done

  local out log status=0
  out=$(mktemp -d)
  log=$(SYSTEMD_FSTAB=$root/etc/fstab SYSTEMD_PROC_CMDLINE="" "$SYSTEMD_FSTAB_GENERATOR" "$out" "$out" "$out" 2>&1) ||
    status=$?
  rm -rf "$out"
  if ((status != 0)); then
    echo "systemd's fstab generator fails on /etc/fstab: ${log//$'\n'/; }"
  elif [[ -n $log ]]; then
    echo "systemd's fstab generator complains on /etc/fstab: ${log//$'\n'/; }"
  fi
  return 0
}
