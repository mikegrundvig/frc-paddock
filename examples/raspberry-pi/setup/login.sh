#!/bin/sh
# Run by Paddock as root inside the image (paddock.yaml's last step): lets you log in as pi, by SSH
# key only.
#
# Raspberry Pi OS Lite comes with pi as a placeholder, which a first-boot wizard renames by asking
# at the board's screen, and with SSH off. This keeps pi, gives it your keys, and turns SSH on.
set -eu

# The wizard and its SSH banner off; the screen gets its login prompt back.
systemctl disable userconfig.service
systemctl enable getty@tty1.service
rm -f /etc/ssh/sshd_config.d/rename_user.conf
# cloud-init would set up users and the network from files on the boot partition: your repository
# does that instead.
touch /etc/cloud/cloud-init.disabled

# pi: a shell, no password that works (a key still does), sudo without one, and your keys.
usermod --shell /bin/bash --password '*' pi
echo 'pi ALL=(ALL) NOPASSWD: ALL' >/etc/sudoers.d/010_pi-nopasswd
chmod 0440 /etc/sudoers.d/010_pi-nopasswd
install -d -m 0700 -o pi -g pi /home/pi/.ssh
install -m 0600 -o pi -g pi "$PADDOCK_CONFIG_DIR/keys/authorized_keys" /home/pi/.ssh/authorized_keys

# SSH by key only. Each computer makes its own host keys when it first starts: Debian's
# sshd-keygen does that only on systemd's "first boot", which a Paddock image never has (its
# machine ID is stamped), so it runs whenever there are no keys instead.
printf 'PasswordAuthentication no\nKbdInteractiveAuthentication no\n' >/etc/ssh/sshd_config.d/10-keys-only.conf
mkdir -p /etc/systemd/system/sshd-keygen.service.d
printf '[Unit]\nConditionFirstBoot=\nConditionPathExists=!/etc/ssh/ssh_host_ed25519_key\n' \
  >/etc/systemd/system/sshd-keygen.service.d/10-when-no-keys.conf
systemctl enable ssh.service
