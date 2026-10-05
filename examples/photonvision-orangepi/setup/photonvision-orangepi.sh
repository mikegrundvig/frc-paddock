#!/bin/sh
# Run by Paddock as root inside a PhotonVision image for the Orange Pi (paddock.yaml's last step),
# after the files are in place. It turns off what a read-only root, NetworkManager owning the
# network, and a computer anyone could download can't have. PhotonVision's images have been built on
# Armbian (2027 onward) and on Ubuntu (Joshua Riek's, through 2027.0.0-alpha-2); each part below
# does nothing where its base's habit isn't there.
set -eu

# keys/authorized_keys logs in as photon: a base without that user would let no one in.
if ! id -u photon >/dev/null 2>&1; then
  echo "this base has no user photon, whom keys/authorized_keys and files/sshd.conf are for" >&2
  exit 1
fi

# --- First boot: cloud-init (Ubuntu's) would make users, write the network, and grow the root at
# first boot; none of that belongs on an image built from Git. ---
if [ -d /etc/cloud ]; then
  touch /etc/cloud/cloud-init.disabled
fi

# --- The network: NetworkManager alone, with the address Paddock stamps. ---
# Netplan's files (DHCP on every port, for systemd-networkd) move aside, and systemd-networkd is
# masked. PhotonVision runs with -n, so it leaves the network alone too.
mkdir -p /etc/netplan.disabled
for file in /etc/netplan/*.yaml; do
  if [ -e "$file" ]; then
    mv "$file" /etc/netplan.disabled/
  fi
done
systemctl mask systemd-networkd.service systemd-networkd.socket systemd-networkd-wait-online.service

# --- PhotonVision: its own command with -n, its settings on the data partition, and a bounded
# stop (a power-off waits for it to save its settings, 15 s at most rather than systemd's 90). ---
unit=/etc/systemd/system/photonvision.service
[ -f "$unit" ] || unit=/lib/systemd/system/photonvision.service
exec_line=$(sed -n 's/^ExecStart=//p' "$unit" | tail -1 | sed -E 's/ (-n|--disable-networking)( |$)/\2/g; s/[[:space:]]+$//')
mkdir -p /etc/systemd/system/photonvision.service.d
cat >/etc/systemd/system/photonvision.service.d/10-team.conf <<EOF
[Unit]
RequiresMountsFor=/opt/photonvision/photonvision_config

[Service]
ExecStart=
ExecStart=$exec_line -n
TimeoutStopSec=15s
EOF

# PhotonVision extracts its native libraries under root's home the first time it runs, which a
# read-only root refuses: its smoke test runs here, so they're already there. It writes its
# settings in its working folder, a temporary one.
smoke=$(mktemp -d)
(cd "$smoke" && java -Djava.io.tmpdir="$smoke" -jar /opt/photonvision/photonvision.jar --smoketest -n \
  --platform=LINUX_RK3588_64)
rm -rf "$smoke"
[ -d /root/.wpilib/nativecache ] || { echo "the smoke test left no native libraries" >&2; exit 1; }

# --- A read-only root: Armbian's RAM logging (it would hide the kept journal), its first-boot
# resize (the data partition follows the root), and its first-run tasks (they write the root) off;
# what only writes the root masked (package lists, man pages, log rotation, dpkg backups, unattended
# upgrades, snaps); the journal is the log, so rsyslog goes. ---
if [ -f /etc/default/armbian-ramlog ]; then
  sed -i 's/^ENABLED=.*/ENABLED=false/' /etc/default/armbian-ramlog
fi
touch /root/.no_rootfs_resize
systemctl mask armbian-ramlog.service armbian-resize-filesystem.service armbian-firstrun.service \
  armbian-led-state.service
systemctl mask apt-daily.timer apt-daily-upgrade.timer man-db.timer logrotate.timer dpkg-db-backup.timer \
  unattended-upgrades.service snapd.service snapd.socket snapd.seeded.service
systemctl mask rsyslog.service syslog.socket fake-hwclock-save.timer fake-hwclock-save.service
# With no clock battery, systemd starts the clock no earlier than this file's time: the build's.
touch /usr/lib/clock-epoch

# --- Logins: none on the board's own screen, no password that works (the base images' are public
# defaults), and SSH by key only (files/sshd.conf), with each drive's own host key. ---
rm -f /etc/systemd/system/getty@.service.d/override.conf /etc/systemd/system/serial-getty@.service.d/override.conf
systemctl mask getty@.service serial-getty@.service autovt@.service console-getty.service
mkdir -p /etc/systemd/logind.conf.d
printf '[Login]\nNAutoVTs=0\nReserveVT=0\n' >/etc/systemd/logind.conf.d/70-team.conf
# "*" matches no password, for every account that has one; a key still logs in ("!" would lock the
# account, which sshd refuses even for a key).
for shadow in /etc/shadow /etc/shadow-; do
  [ -f "$shadow" ] || continue
  awk -F: -v OFS=: '$2 !~ /^[*!]/ { $2 = "*" } { print }' "$shadow" >"$shadow.new"
  chmod --reference="$shadow" "$shadow.new"
  chown --reference="$shadow" "$shadow.new"
  mv -f "$shadow.new" "$shadow"
done
# The base image's host keys are in every copy of it, and published: each drive makes its own.
rm -f /etc/ssh/ssh_host_*
systemctl enable ssh-hostkey.service

# --- Checked: no password that works, and no console that logs in by itself. ---
if awk -F: '$2 !~ /^[*!]/ { found = 1 } END { exit !found }' /etc/shadow; then
  echo "a login still has a usable password (or none)" >&2
  exit 1
fi
if grep -rls -e '--autologin' /etc/systemd/system/*getty* 2>/dev/null; then
  echo "a console still logs in by itself" >&2
  exit 1
fi
# sshd's settings as it reads them, base's lines and all, for photon: a throwaway host key stands in
# for the drive's own, which is made at first boot.
key=$(mktemp -u)
ssh-keygen -q -t ed25519 -N "" -f "$key"
mkdir -p /run/sshd
settings=$(/usr/sbin/sshd -T -h "$key" -C user=photon,host=check,addr=127.0.0.1 2>/dev/null)
rm -f "$key" "$key.pub"
for want in "allowusers photon" "passwordauthentication no" "kbdinteractiveauthentication no" "permitrootlogin no"; do
  if ! printf '%s\n' "$settings" | grep -qx "$want"; then
    echo "sshd's settings for photon don't say '$want': a base's line or drop-in comes before files/sshd.conf" >&2
    exit 1
  fi
done
