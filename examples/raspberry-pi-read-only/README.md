# A read-only Raspberry Pi

Raspberry Pi OS Lite with a read-only root, so pulling the power can't damage the system. That's
the usual way a robot computer gets turned off. What has to last lives on a small data partition;
everything else starts fresh at every boot. You log in as `pi` with your SSH keys, as in the
[raspberry-pi example](../raspberry-pi/).

**Not yet checked on a real Pi.** CI builds it, but nobody has run
[the hardware checklist](../../docs/hardware-checklist.md) on it yet. Treat it as a strong starting
point, and please [tell us](https://github.com/mikegrundvig/frc-paddock/issues) how it goes.

## What you get

- **A read-only root,** and a read-only boot partition too.
- **A 512 MB data partition at `/data`,** keeping:
  - the journal, written to disk every 10 seconds, so you can read what happened before a power
    cut (`journalctl -b -1`);
  - `/etc/ssh`, so each board makes its own SSH host keys once and keeps them;
  - `pi`'s home folder.
- **In RAM, empty at every boot:** `/tmp`, `/var/tmp`, `/var/log`, systemd's and NetworkManager's
  state, and swap (compressed RAM only).

## What's turned off, and why

Raspberry Pi OS does a few things a read-only root can't have. `setup/read-only.sh` handles each
one:

- **Growing the root on every boot.** `cmdline.txt`'s `resize` would grow the root partition into
  the data partition that now follows it.
- **Swap backed by a file on the root.** `files/swap.conf` keeps swap in compressed RAM only.
- **Firmware (EEPROM) updates at boot.** They're staged on the boot partition, which is read-only
  now, so do them by hand when you need to (the script says how).
- **Jobs that only write the root:** apt's daily updates, man pages, dpkg backups, and log
  rotation. Bluetooth too, since it keeps its pairings on the root.
- **Starting the clock too early.** Without a clock battery a Pi starts at an old time, so the
  clock never starts before the build's time, and `files/e2fsck.conf` lets the boot-time check of
  `/data` run even when the clock is behind.

## Make it yours

1. Your addresses in `paddock.yaml`: `10.TE.AM.x/24`, gateway `10.TE.AM.4`.
2. Your SSH public keys in `keys/authorized_keys`, one per line: each person's own, never a private
   key ([Control who can log in](../../docs/how-to.md#control-who-can-log-in)).
3. Your own steps, and in `keep:` whatever your programs need to remember. Keep it small: the data
   partition is flashed whole, so a bigger one makes every flash slower.

If something fails to write after you add your own steps, `journalctl -b -p warning` will name it:
keep its path, put it in RAM (`ram:`), or turn it off.

## What's here

| Path | What |
|---|---|
| `paddock.yaml` | The image, what it keeps, and its computer |
| `setup/read-only.sh` | Turns off what a read-only root can't have. Each part says why |
| `setup/login.sh`, `keys/authorized_keys` | Logging in as `pi` with your keys |
| `files/journald.conf` | The journal kept on `/data`, written every 10 seconds |
| `files/swap.conf` | Swap in compressed RAM only |
| `files/e2fsck.conf` | Lets the boot-time check of `/data` run when the clock is behind |
| `NOTICE.md` | What's in the image, and where its source is |

## On the board

On top of [the hardware checklist](../../docs/hardware-checklist.md), including its read-only
section:

1. `cat /proc/cmdline` has no `resize`, and `findmnt -n -o OPTIONS /boot/firmware` includes `ro`.
2. `swapon --show` lists only `/dev/zram0`.
3. Reboot twice: `ssh-keyscan ADDRESS` gives the same host key each time.
