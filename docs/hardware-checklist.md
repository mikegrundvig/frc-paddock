# Hardware checklist

The things only a real computer can show. Run through it on each kind of board before you trust a
new base or a new Paddock version on a robot. Each check is a command on the computer (over SSH) or
something to do to it.

## Every image

1. **It boots and shows up.** `ping ADDRESS` answers within a minute of power-on.
2. **It's the computer it says it is.** `hostnamectl` shows its hostname; `cat /etc/os-release`
   shows the release's `IMAGE_ID`, `IMAGE_VERSION`, and `PADDOCK_COMMIT`.
3. **Nothing failed.** `systemctl --failed` lists nothing, and `systemctl is-system-running` says
   `running`.
4. **It has its stamped address, on any port.** `nmcli -g ipv4.addresses connection show paddock`
   shows it. If the board has another Ethernet port, move the cable over: it comes back.
5. **Just the one address.** `ip -4 addr` shows no DHCP address next to it.
6. **A second drive for the same computer stays off the address.** Flash the same image to a second
   drive and boot it in a second board on the same network: the first keeps answering, and the
   second's `journalctl -u NetworkManager` reports the duplicate.
7. **Its machine ID is its own.** `cat /etc/machine-id` matches the same computer's in the previous
   release, and no other computer's.
8. **SSH works the way the image says.** Your key gets you in, and a password doesn't
   (`ssh -o PubkeyAuthentication=no USER@ADDRESS` is refused). Two drives' `ssh-keyscan ADDRESS`
   differ, and a reboot keeps each drive's.

## A read-only root

1. **The root is read-only.** `findmnt -n -o OPTIONS /` starts with `ro`, and `touch /etc/x` fails.
2. **The data partition is mounted.** `findmnt /data` shows `LABEL=paddock-data`, ext4.
3. **Kept paths survive.** Change something kept (a setting in your application, say), reboot, and
   it's still there. `findmnt PATH` shows each kept path coming from `/data`.
4. **RAM paths are in RAM.** `findmnt -n -o FSTYPE /var/log` says `tmpfs`.
5. **Nothing writes the root.** `journalctl -b -p warning` shows no "Read-only file system" errors.
6. **The root stayed its size.** `lsblk` shows the root and data partitions as built, not the root
   grown to fill the drive.
7. **Pulling the power costs nothing.** While the computer's busy (your application running and
   saving things), pull the power. Plug it back in: it boots, `journalctl -b -1` has the previous
   boot's last seconds, and `journalctl -b -u systemd-fsck@*` shows `/data` checked clean.
8. **The clock.** On a board without a clock battery, boot it after a power cut with no network
   connected: `/data` still mounts.

## The examples

Each example's README lists the checks for what it sets up, like
[photonvision-orangepi](../examples/photonvision-orangepi/README.md#on-the-board).
