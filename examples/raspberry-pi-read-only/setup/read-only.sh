#!/bin/sh
# Run by Paddock as root inside the image, after login.sh: turns off what Raspberry Pi OS does that a
# read-only root can't have. Each part says why.
set -eu

# Raspberry Pi OS grows the root partition early in every boot when cmdline.txt says "resize". The
# data partition sits right after the root now, so that has to stop.
sed -i 's/ resize\b//' /boot/firmware/cmdline.txt
if grep -qw resize /boot/firmware/cmdline.txt; then
  echo "cmdline.txt still asks for a resize" >&2
  exit 1
fi

# The boot partition read-only too, so a power cut can't damage it either. EEPROM updates are staged
# there, so they're done by hand now (sudo mount -o remount,rw /boot/firmware; sudo rpi-eeprom-update -a).
awk '$2 == "/boot/firmware" { $4 = $4 ",ro" } { print }' /etc/fstab >/etc/fstab.new
mv /etc/fstab.new /etc/fstab
systemctl mask rpi-eeprom-update.service

# Jobs that only write the root: package lists and upgrades, man pages, dpkg backups, and log
# rotation (the logs are in RAM). Bluetooth keeps its pairings on the root, and robots don't use it.
systemctl mask apt-daily.timer apt-daily-upgrade.timer man-db.timer dpkg-db-backup.timer \
  logrotate.timer bluetooth.service

# No clock battery: systemd never starts the clock earlier than this file's time, the build's.
touch /usr/lib/clock-epoch
