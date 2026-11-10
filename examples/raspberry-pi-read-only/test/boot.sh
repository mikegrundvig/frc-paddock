#!/bin/bash
# The image's boot check (paddock.yaml's boot.check): run by Paddock's workflow as root, inside a
# copy of the image booted in a container, once its boot has finished. Each line is a promise this
# example makes (README.md); the check fails, naming each one broken, if any is.
set -u
failed=0

fail() {
  echo "boot check: $*" >&2
  failed=1
}

# The root as the board has it: read-only.
if touch /.paddock-boot-check 2>/dev/null; then
  rm -f /.paddock-boot-check
  fail "the root is writable"
fi
# What paddock.yaml keeps is on the data partition, so it lasts.
for path in /var/log/journal /etc/ssh /home/pi; do
  mountpoint -q "$path" || fail "$path isn't mounted from the data partition"
done
# Logging in: SSH is up, with this computer's own host keys.
systemctl is-active --quiet ssh.service || fail "ssh.service isn't active ($(systemctl is-active ssh.service))"
[[ -f /etc/ssh/ssh_host_ed25519_key ]] || fail "no SSH host key was made"

exit "$failed"
