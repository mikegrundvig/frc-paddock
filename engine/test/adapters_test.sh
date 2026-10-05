# shellcheck shell=bash disable=SC1090,SC1091 # tests source the engine by computed paths
# The OS adapters (engine/os/): each one alone, on a root shaped like a Debian image's.

adapter() {
  . "$ENGINE/lib/common.sh"
  . "$ENGINE/os/$1/$2.sh"
}

test_every_axis_has_its_default_adapter() {
  . "$ENGINE/lib/common.sh"
  local axis default
  for axis in $OS_AXES; do
    default=DEFAULT_OS_${axis^^}
    is_os_value "$axis" "${!default}" || fail "no $axis adapter for the default, ${!default}"
  done
  assert_eq "$(os_values network | paste -sd ' ')" networkmanager
}

test_apt_checks_the_base() {
  make_root
  adapter packages apt
  assert_eq "$(packages_check_base "$TMP/root")" ""
  rm "$TMP/root/usr/bin/apt-get"
  assert_eq "$(packages_check_base "$TMP/root")" "no /usr/bin/apt-get (the apt adapter installs .deb packages with it)"
}

test_apt_offline_unpacks_packages() {
  make_root
  make_package
  adapter packages apt
  packages_install "$TMP/root" yes "$TMP/inputs/packages/00-example-tool_1.0.0_arm64.deb"
  assert_file "$TMP/root/usr/bin/example-tool"
  assert_file "$TMP/root/usr/lib/systemd/system/example-tool.service"
}

test_apt_installs_only_inside_the_chroot() {
  make_root
  make_package
  adapter packages apt
  assert_fails "installs inside the image's chroot" \
    packages_install "$TMP/root" no "$TMP/inputs/packages/00-example-tool_1.0.0_arm64.deb"
}

test_apt_holds_services_while_the_steps_run() {
  make_root
  adapter packages apt
  mkdir -p "$TMP/root/var/lib/apt/lists"
  echo 'a list' >"$TMP/root/var/lib/apt/lists/example_Packages"
  packages_prepare "$TMP/root"
  local status=0
  "$TMP/root/usr/sbin/policy-rc.d" || status=$?
  assert_eq "$status" 101 "policy-rc.d's exit"
  packages_finish "$TMP/root"
  assert_no_file "$TMP/root/usr/sbin/policy-rc.d"
  assert_no_file "$TMP/root/var/lib/apt/lists/example_Packages"
  echo 'the base'"'"'s' >"$TMP/root/usr/sbin/policy-rc.d"
  packages_prepare "$TMP/root"
  packages_finish "$TMP/root"
  assert_eq "$(cat "$TMP/root/usr/sbin/policy-rc.d")" "the base's"
}

test_systemd_checks_the_base() {
  make_root
  adapter init systemd
  assert_eq "$(init_check_base "$TMP/root")" ""
  rm "$TMP/root/usr/lib/systemd/systemd"
  [[ $(init_check_base "$TMP/root") == "no systemd"* ]] || fail "a root without systemd passes"
  mkdir -p "$TMP/root/lib/systemd"
  printf '#!/bin/sh\n' >"$TMP/root/lib/systemd/systemd"
  chmod +x "$TMP/root/lib/systemd/systemd"
  assert_eq "$(init_check_base "$TMP/root")" "" "systemd at /lib, unmerged"
}

test_systemd_clears_and_writes_the_machine_id() {
  make_root
  adapter init systemd
  init_clear_machine_id "$TMP/root"
  [[ ! -s $TMP/root/etc/machine-id ]] || fail "the machine ID isn't cleared"
  assert_mode "$TMP/root/etc/machine-id" 444
  assert_eq "$(readlink "$TMP/root/var/lib/dbus/machine-id")" /etc/machine-id
  init_write_machine_id "$TMP/root" 0123456789abcdef0123456789abcdef
  assert_eq "$(cat "$TMP/root/etc/machine-id")" 0123456789abcdef0123456789abcdef
  assert_eq "$(init_stamped_paths)" /etc/machine-id
  assert_eq "$(init_ram_paths)" /var/lib/systemd
}

test_networkmanager_checks_the_base() {
  make_root
  adapter network networkmanager
  assert_eq "$(network_check_base "$TMP/root")" ""
  rm "$TMP/root/usr/sbin/NetworkManager"
  [[ $(network_check_base "$TMP/root") == "no NetworkManager"* ]] || fail "a root without NetworkManager passes"
}

test_networkmanager_names_what_would_fight_it() {
  make_root
  adapter network networkmanager
  assert_eq "$(network_check_result "$TMP/root")" ""
  mkdir -p "$TMP/root/etc/netplan" "$TMP/root/etc/network" \
    "$TMP/root/etc/systemd/system/multi-user.target.wants"
  printf 'network:\n  version: 2\n  renderer: NetworkManager\n' >"$TMP/root/etc/netplan/01-nm.yaml"
  assert_eq "$(network_check_result "$TMP/root")" "" "netplan handing the network to NetworkManager"
  printf 'network:\n  ethernets:\n    all:\n      dhcp4: yes\n' >"$TMP/root/etc/netplan/10-dhcp.yaml"
  printf 'auto eth0\niface eth0 inet dhcp\n' >"$TMP/root/etc/network/interfaces"
  ln -s /lib/systemd/system/systemd-networkd.service \
    "$TMP/root/etc/systemd/system/multi-user.target.wants/systemd-networkd.service"
  local problems
  problems=$(network_check_result "$TMP/root")
  assert_eq "$(wc -l <<<"$problems")" 3 "problems: $problems"
  [[ $problems == *"systemd-networkd is enabled"* ]] || fail "networkd isn't named: $problems"
  [[ $problems == *"/etc/netplan/10-dhcp.yaml configures the network with netplan"* ]] || fail "netplan isn't named: $problems"
  [[ $problems == *"/etc/network/interfaces configures an Ethernet port"* ]] || fail "ifupdown isn't named: $problems"
  # Masked, as a step does it, systemd-networkd stays off whatever links enable it.
  ln -s /dev/null "$TMP/root/etc/systemd/system/systemd-networkd.service"
  [[ $(network_check_result "$TMP/root") != *"systemd-networkd is enabled"* ]] || fail "a masked networkd is named"
}

# netplan's three folders, ifupdown's interfaces.d, and networkd enabled through its socket.
test_networkmanager_looks_everywhere_the_others_are_configured() {
  make_root
  adapter network networkmanager
  mkdir -p "$TMP/root/lib/netplan" "$TMP/root/usr/lib/netplan" "$TMP/root/etc/network/interfaces.d" \
    "$TMP/root/etc/systemd/system/sockets.target.wants"
  printf 'network:\n  ethernets:\n    all:\n      dhcp4: yes\n' >"$TMP/root/lib/netplan/10-dhcp.yaml"
  printf 'network:\n  ethernets:\n    all:\n      dhcp4: yes\n' >"$TMP/root/usr/lib/netplan/20-dhcp.yml"
  printf 'allow-hotplug end0\niface end0 inet dhcp\n' >"$TMP/root/etc/network/interfaces.d/end0"
  ln -s /lib/systemd/system/systemd-networkd.socket \
    "$TMP/root/etc/systemd/system/sockets.target.wants/systemd-networkd.socket"
  local problems
  problems=$(network_check_result "$TMP/root")
  assert_eq "$(wc -l <<<"$problems")" 4 "problems: $problems"
  [[ $problems == *"/lib/netplan/10-dhcp.yaml"* && $problems == *"/usr/lib/netplan/20-dhcp.yml"* ]] ||
    fail "netplan outside /etc isn't named: $problems"
  [[ $problems == *"/etc/network/interfaces.d/end0 configures an Ethernet port"* ]] || fail "interfaces.d isn't named: $problems"
  [[ $problems == *"systemd-networkd is enabled"* ]] || fail "networkd's socket isn't named: $problems"
}

test_networkmanager_writes_the_address() {
  make_root
  adapter network networkmanager
  network_write "$TMP/root" vision-front 10.12.34.11 24 10.12.34.4 "" team/robot-images
  local profile=$TMP/root/etc/NetworkManager/system-connections/paddock.nmconnection
  assert_file "$profile"
  # NetworkManager ignores a profile others can read.
  assert_mode "$profile" 600
  assert_contains "$profile" 'type=ethernet'
  assert_contains "$profile" 'method=manual'
  assert_contains "$profile" 'address1=10.12.34.11/24,10.12.34.4'
  assert_contains "$profile" 'autoconnect-priority=100'
  assert_contains "$profile" 'dad-timeout=3000'
  assert_not_contains "$profile" 'dns='
  grep -Eq '^uuid=[0-9a-f]{8}-[0-9a-f]{4}-5[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' "$profile" ||
    fail "the profile's uuid isn't a UUID"
  assert_eq "$(network_stamped_paths)" /etc/NetworkManager/system-connections/paddock.nmconnection
  assert_eq "$(network_ram_paths)" /var/lib/NetworkManager
}

test_networkmanager_writes_no_gateway_when_there_is_none_and_dns_when_there_is() {
  make_root
  adapter network networkmanager
  network_write "$TMP/root" bench 192.168.1.50 24 "" "192.168.1.1 1.1.1.1" team/robot-images
  local profile=$TMP/root/etc/NetworkManager/system-connections/paddock.nmconnection
  assert_contains "$profile" $'address1=192.168.1.50/24\n'
  assert_contains "$profile" 'dns=192.168.1.1;1.1.1.1;'
}

test_ext4_says_what_fstab_needs() {
  adapter filesystem ext4
  assert_eq "$(fs_type)" ext4
  [[ $(fs_data_options) == *errors=remount-ro* ]] || fail "the data partition doesn't turn read-only on an error"
}

test_ext4_makes_a_filesystem_from_a_folder() {
  need mkfs.ext4 debugfs
  adapter filesystem ext4
  mkdir -p "$TMP/src/var/lib/team"
  echo 'kept' >"$TMP/src/var/lib/team/state"
  truncate -s 32M "$TMP/fs.img"
  fs_make "$TMP/fs.img" 0 $((32 * 1024)) paddock-data "$TMP/src"
  assert_eq "$(debugfs -R 'cat /var/lib/team/state' "$TMP/fs.img" 2>/dev/null)" kept
  e2fsck -fn "$TMP/fs.img" >/dev/null || fail "the filesystem has errors"
}
