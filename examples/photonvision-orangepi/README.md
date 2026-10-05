# PhotonVision on an Orange Pi 5

An example of a computer locked down for a robot: PhotonVision on an Orange Pi 5-family board, with
a read-only root, SSH by key only, and no default passwords. It's a good one to read for how a
read-only root and a vendor's image fit together, whatever you end up running.

## What you get

- **PhotonVision**, the version `paddock.yaml` pins, started at boot with its dashboard at
  `http://ADDRESS:5800`. Its settings live on the data partition. It leaves the network alone
  (`-n`), and gets at most 15 seconds to stop when you power off.
- **A read-only root,** with a 2 GB data partition at `/data` for PhotonVision's settings and the
  journal (written to disk every 10 seconds). Logs, `/tmp`, and other scratch space are in RAM.
- **The stamped address** on any Ethernet port, set by NetworkManager alone: no DHCP, netplan, or
  systemd-networkd. No DNS either (`files/NetworkManager.conf`), so `dns:` does nothing here.
- **Logins:** SSH as `photon` with your keys, and that's it. No password works for any account (the
  bases' defaults are public), nobody else can SSH in, and the board's screen has no login. Each
  drive makes its own SSH host key the first time it starts. `photon` can `sudo` without a password,
  the way the base sets it up, so anyone with one of your keys has root.
- **Turned off:** anything that writes the root or does its own thing at boot: cloud-init, Armbian's
  first-run, resize, and RAM logging, apt's timers, unattended upgrades, snaps, and rsyslog.

## Two images

`vision` is PhotonVision's base image for the board (from photon-image-modifier, on Armbian), with
the PhotonVision release downloaded in, which is how PhotonVision builds its own images for 2027.
`vision-release` is PhotonVision's own release image as it comes (up to 2027.0.0-alpha-2, built on
Ubuntu). Paddock's CI builds both; keep whichever you want and point your computers at it.

## Make it yours

1. **Addresses** in `paddock.yaml`: `10.TE.AM.11/24`, gateway `10.TE.AM.4`. One computer per
   board.
2. **Your board's base.** `photonvision_opi5.img.xz` is the Orange Pi 5; photon-image-modifier's
   releases have one per board (`_opi5b`, `_opi5plus`, `_opi5pro`, `_opi5max`), each with its
   SHA-256.
3. **PhotonVision's version:** the `download` step's jar, from
   [PhotonVision's releases](https://github.com/PhotonVision/photonvision/releases). Match the
   PhotonLib version your robot code uses.
4. **Your SSH public keys** in `keys/authorized_keys`, one per line: each person's own, never a
   private key ([Control who can log in](../../docs/how-to.md#control-who-can-log-in)).
5. **`NOTICE.md`**, kept up to date with what's in your images.

## What's here

| Path | What |
|---|---|
| `paddock.yaml` | The images and the computers stamped from them |
| `setup/photonvision-orangepi.sh` | The last step: everything above that isn't a file. Each part says why, and checks it worked |
| `files/sshd.conf`, `files/ssh-hostkey.service` | SSH by key, for `photon` only, with each drive's own host key on `/data` |
| `files/NetworkManager.conf` | NetworkManager running the network, with no DHCP profile or DNS |
| `files/journald.conf` | The journal kept on `/data`, written every 10 seconds |
| `files/e2fsck.conf` | Lets the boot-time check of `/data` run even when the clock is behind (no clock battery) |
| `keys/authorized_keys` | Your SSH public keys |
| `NOTICE.md` | What the images hold, and where its source is |

## On the board

On top of [the hardware checklist](../../docs/hardware-checklist.md):

1. **PhotonVision runs.** Its dashboard answers at `http://ADDRESS:5800` and shows the version
   pinned in `paddock.yaml`.
2. **Its settings stick.** Change a camera setting and reboot: it's still there.
3. **It leaves the network alone.** Changing the network settings in its dashboard doesn't change
   the address.
4. **Only `photon` gets in.** `ssh root@ADDRESS` and `ssh pi@ADDRESS` are refused, even with your
   key.
5. **No console login.** The board's screen shows no login prompt.
