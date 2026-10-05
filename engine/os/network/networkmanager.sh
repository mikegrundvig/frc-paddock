# shellcheck shell=bash
# The NetworkManager adapter (os: network: networkmanager): each computer's address as a
# NetworkManager profile that any Ethernet port takes.

NM_PROFILE=/etc/NetworkManager/system-connections/paddock.nmconnection

network_check_base() {
  local root=${1%/}
  [[ -x $root/usr/sbin/NetworkManager ]] ||
    echo "no NetworkManager (/usr/sbin/NetworkManager): the networkmanager adapter writes each computer's address for it"
  return 0
}

# After the steps: anything else that would configure Ethernet and fight NetworkManager for it.
network_check_result() {
  local root=${1%/} file
  network_check_base "$root"
  # systemd-networkd, enabled by any target and not masked (a mask wins over the links).
  if [[ $(readlink "$root/etc/systemd/system/systemd-networkd.service" 2>/dev/null) != /dev/null ]] &&
    [[ -n $(find "$root/etc/systemd/system" -path '*.wants/systemd-networkd.*' 2>/dev/null | head -1) ]]; then
    echo "systemd-networkd is enabled: mask it in a step (systemctl mask systemd-networkd.service systemd-networkd.socket)"
  fi
  # netplan without NetworkManager as its renderer hands Ethernet to systemd-networkd.
  for file in "$root"/etc/netplan/*.y*ml "$root"/lib/netplan/*.y*ml "$root"/usr/lib/netplan/*.y*ml; do
    [[ -f $file ]] || continue
    grep -Eq '^[[:space:]]*renderer:[[:space:]]*NetworkManager[[:space:]]*$' "$file" ||
      echo "${file#"$root"} configures the network with netplan for systemd-networkd: move it aside in a step"
  done
  for file in "$root/etc/network/interfaces" "$root"/etc/network/interfaces.d/*; do
    [[ -f $file ]] || continue
    if grep -Eq '^[[:space:]]*(auto|allow-hotplug|iface)[[:space:]]+(e|eth)' "$file"; then
      echo "${file#"$root"} configures an Ethernet port (ifupdown): remove it in a step"
    fi
  done
  return 0
}

network_stamped_paths() {
  echo "$NM_PROFILE"
}

network_ram_paths() {
  echo /var/lib/NetworkManager
}

# A computer's address: ROOT HOSTNAME ADDRESS PREFIX GATEWAY "DNS..." SEED (gateway and DNS may be
# empty). Root-only, as NetworkManager requires; its top priority wins over the base's profiles.
network_write() {
  local root=${1%/} hostname=$2 address=$3 prefix=$4 gateway=$5 dns=$6 seed=$7 servers=""
  if [[ -n $dns ]]; then
    servers="dns=${dns// /;};"
  fi
  put_in "$root" "$NM_PROFILE" 0600 <<PROFILE
# Written at stamping (Paddock): $hostname's address. Any Ethernet port takes it.
[connection]
id=paddock
uuid=$(derived_uuid "paddock connection/$seed/$hostname")
type=ethernet
autoconnect=true
autoconnect-priority=100
autoconnect-retries=0

[ethernet]

[ipv4]
method=manual
address1=$address/$prefix${gateway:+,$gateway}
$servers
# Duplicate-address detection: a second drive stamped for this computer stays off the address.
dad-timeout=3000
may-fail=false

[ipv6]
method=disabled
PROFILE
}
