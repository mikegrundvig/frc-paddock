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
