# PhotonVision on Orange Pi

The recipe for a vision coprocessor running PhotonVision on an Orange Pi 5-family board. It takes
PhotonVision's official image for the board, adds a read-only root, a data partition, Spotter's
agent, and PhotonVision's pack, and then Paddock's engine makes one copy per computer in the team's
table, stamped with that computer's name, address, and committed settings. One GitHub Release of
the team's repository holds every computer's image.

So to change a coprocessor, change the team's repository and cut a release; to replace a broken
one, flash its image from the release onto a drive. A drive knows which computer it is.

| File | What it does |
|---|---|
| `recipe.env` | The recipe's facts: its boards, architecture and runner, lock, inputs, label, packs, SSH login |
| `photonvision.lock` | PhotonVision's version and its arm64 jar, and each board's base image, by URL and SHA-256 |
| `boards/*.env` | What differs per board |
| `provision.sh` | Makes PhotonVision's image into the common image, in a chroot of it: installs the pinned jar, `nvme-cli` and `polkitd` at pinned versions, Spotter's agent and the packs (the engine's `install-spotter.sh`); the read-only root's `/etc/fstab`; the journal; the logins and SSH; Armbian's RAM logging, first-boot resize, and first-run tasks off, and rsyslog and fake-hwclock's saving; the team's hook. Runs PhotonVision's `--smoketest`, which leaves an empty settings database in that version's schema and PhotonVision's native libraries extracted in the image, then checks the result. Safe to rerun |
| `stamp-data.sh` | Builds each computer's settings database from its committed settings, and labels its stamp with their hash |
| `notice.sh` | The release's `NOTICE.md`: PhotonVision's version and each base image, with their source |
| `files/` | The configuration and units `provision.sh` installs |
| `bench-procedures.md` | The bench checks a new board, power setup, or release passes |
| `test/` | Its tests, run with the engine's (`engine/test/run.sh`) |

**The version lock.** `photonvision.lock` pins PhotonVision (its version, and its arm64 jar by
SHA-256) and each board's base image, PhotonVision's own from the
[photon-image-modifier](https://github.com/PhotonVision/photon-image-modifier) release the pinned
version builds on, whose file name it keeps (`BOARD_BASE_ASSET`). The robot code's PhotonLib must be
the same version: give the workflow the vendordep (`vendordep:`) and it checks. To move to another
PhotonVision, a new Paddock release updates the lock, with the new jar's and images' checksums from
their releases.

## What's on a drive

| Partition | What | While running |
|---|---|---|
| 1, the root | PhotonVision's image for the board (Armbian), with PhotonVision pinned to the robot code's version, Spotter's agent, and this computer's identity | Read-only |
| 2, `COPROC` | 32 MiB, FAT: `stamp.json` and `README.txt`, saying which computer the drive is. Windows can open it | Not mounted |
| 3, `coproc-data` | 8 GiB, ext4: PhotonVision's whole config folder (`photon.sqlite`, logs, calibration images) and the journal. Checked at boot; on an error it turns read-only rather than spread the damage | Read-write |

The rest of the drive stays unpartitioned, so nothing resizes at first boot. `/tmp`, `/var/tmp`,
`/var/log` (but for the journal), and NetworkManager's and systemd's state live in RAM.

A read-only root means a power cut can't damage the system, and every writer is deliberate: one
we missed fails loudly in the journal instead of writing quietly. It also enforces the version
lock: PhotonVision's "offline update" can't replace its jar.

**Identity** (written at stamping, by the engine's `stamp.sh`): the hostname; the address, `10.TE.AM.<address>`, netmask
`255.255.255.0`, gateway `10.TE.AM.4` (FRC's documented static range for on-robot devices is
`.6` to `.19`: [IP Configurations](https://docs.wpilib.org/en/latest/docs/networking/networking-introduction/ip-configurations.html));
`/etc/hosts` naming every computer in the table; a machine ID; the team's SSH public keys
(`authorized_keys`, if the team's repository has one); Spotter's agent's configuration
(`/etc/frc-spotter/agent.json`); and `/etc/coprocessor/stamp.json`, Spotter's stamp:

```json
{
  "name": "vision-front",
  "team": 1234,
  "address": "10.12.34.11",
  "version": "coprocessors-2027.1",
  "recipeHash": "…",
  "builtAt": "2027-01-10T18:30:00Z",
  "labels": {
    "board": "orangepi-5",
    "photonvisionVersion": "v2027.0.0-alpha-2",
    "settingsHash": "…"
  },
  "agentPort": 5808
}
```

That's Spotter's `Stamp` (its `docs/agent.md`) less what the agent adds as it answers, plus the
port it listens on; `version` is the release. A computer with no committed settings gets an empty
`settingsHash`, and no settings database: PhotonVision starts with its defaults.

PhotonVision runs with `-n`, so it never changes the network: the address is the image's.

**Logging in.** The only way in is SSH with one of the team's keys, as the user `photon`
(`ssh photon@10.TE.AM.11`; Windows has the OpenSSH client built in), who can use `sudo` without a
password for maintenance. Nothing else logs in:
- No password works for any account. PhotonVision's image ships public default passwords for
  `root` and `photon`; the image replaces both with `*`, which matches no password but still lets
  a key in.
- No console. PhotonVision's image logs `root` in on the HDMI screen and the serial port with no
  password at all (Armbian's autologin, which its first-login script would have removed); the image
  removes that and turns the consoles' login prompts off. Boot messages still show on both.
- No root login over SSH, and no X11 forwarding.

The build checks itself and fails if any account keeps a usable password or any console logs in
by itself, and in the chroot it reads `sshd -T`'s effective settings.

The team's public keys go in `authorized_keys`, at its repository's root. With none there, nobody can log in at
all: reflash to recover. Put only public keys there (it's in every image, and the images are
public); stamping drops each key's comment, which is often a name or an email address. The team's
password manager records where the private key lives. Each drive makes its own SSH host key on
`/data` at first boot.

**Soft-off.** The coprocessor agent runs unprivileged, never as root, as `frc-spotter`.
Its package's polkit rule lets that account power the board off, also while someone is logged in
over SSH; PhotonVision's pack's rule lets it stop and restart `photonvision.service` (its step
before a power-off, so the settings are saved); the package's last rule refuses it everything
else. Its `POST /v1/shutdown` is accepted only from the robot controller its configuration names
(10.TE.AM.2).

## Flashing from Windows

You need a laptop where you have administrator rights (every tool that writes a raw disk needs
them), a USB-to-M.2 NVMe enclosure (M-key, NVMe; a SATA-only enclosure won't take an NVMe drive),
and from the release: the computer's `.img.xz` and `SHA256SUMS`. It's a shop job: at an event,
swap in that computer's pre-flashed spare instead.

1. **Check the download.** In PowerShell, in the download folder:

   ```powershell
   $image = "1234-vision-front-<release>.img.xz"   # the file's name
   $expected = ((Get-Content SHA256SUMS) -match [regex]::Escape($image)).Split(" ")[0]
   (Get-FileHash $image -Algorithm SHA256).Hash -eq $expected
   ```

   `True` means the file is exactly what CI built. `False`: download it again.
2. **Write it**, with either:
   - **Raspberry Pi Imager**, which PhotonVision recommends. It must be installed, and use
     **version 2.0.0 or earlier**: PhotonVision warns that 2.0.2 and later fail to write images.
     *Choose OS*, *Use custom*, pick the `.img.xz`; *Choose Storage*, pick the enclosure; when it
     offers OS customization, choose *No*.
   - **Rufus**, whose portable `.exe` runs without installing. It hides USB hard drives, which is
     how an enclosure appears: press **Alt-F** to list them (its FAQ calls them unsupported). Pick
     the `.img.xz` and the enclosure, and write it.

   Double-check the drive you pick: everything on it is replaced.
3. **Check the drive.** Windows opens its `COPROC` partition: `README.txt` and `stamp.json` name the
   computer. If Windows offers to format any of the drive's partitions, choose *Cancel*: it can't
   read the other two, and formatting one would erase it.
4. Put the drive in **that computer's** board, and only that one: two drives with one image would
   share an address. Label the drive with the computer and the release.

After it boots, the computer answers at `http://10.TE.AM.<address>:5808/v1/stamp` (Spotter's
agent) and PhotonVision at `http://10.TE.AM.<address>:5800`.

The **Orange Pi 5B** has no M.2 slot: its image goes on the soldered eMMC, so there's no enclosure
step, and its spare is a spare board. Orange Pi documents writing the eMMC with RKDevTool over USB
in MaskROM mode (Rockchip's USB driver), or from a board booted from an SD card.

## The bootloader, once per board

The RK3588's boot ROM looks for a bootloader in SPI flash, then eMMC, then the SD card, never on
NVMe ([rk2aw](https://xnux.eu/rk2aw/)). So a board that boots from an NVMe drive needs a bootloader
in its SPI flash first, once per board. All of this is **unverified** per board; check it on the
bench with the board you have:

| Board | Bootloader | |
|---|---|---|
| Orange Pi 5 | SPI flash, 16 MB | Install once |
| Orange Pi 5 Plus | SPI flash, 16/32 MB | Install once |
| Orange Pi 5 Max | SPI flash, 16 MB | Install once |
| Orange Pi 5 Pro | SPI flash *or* an eMMC module: which ships is unverified | Check the board |
| Orange Pi 5B | No SPI flash listed; boots its eMMC | Nothing to install |

Two ways to install it:
- **Orange Pi's documented way** (its wiki, per board): RKDevTool on Windows with the board in
  MaskROM mode, which needs Rockchip's USB driver.
- **From the board itself:** boot PhotonVision's own SD card image for the board once, log in, and
  use Armbian's `armbian-install` (*Install/Update the bootloader on SPI Flash*), if PhotonVision's
  image includes it.

Keep one spare board with its bootloader installed. A stale SPI bootloader is a known trap
(PhotonVision's own image adds a tool to read its version: `sudo strings /dev/mtd0 | grep "^U-Boot"`),
and Spotter's agent reports the version in SPI flash.

## What's unverified

Nothing here has run on a board yet. The tests cover what
runs without one: stamping, the layout, the plan, the manifest, `provision.sh`'s
file changes and self-checks on a tree shaped like PhotonVision's image (its logins as that image
ships them), and the soft-off rule, run under Node against the requests it must allow and refuse.
Still to check:
- **PhotonVision starting on the read-only root:** its native libraries are extracted during the
  build's smoke test (`/root/.wpilib/nativecache`), and PhotonVision should load them from there
  without writing.
- **The sandboxes:** the drive-health helper writing `/run/coprocessor` with only read access to
  `/dev/nvme0` and `/dev/mtd0`; polkit applying the soft-off rule to the agent's account.
- **Soft-off's timing:** PhotonVision's stop is bounded at 15 s (a drop-in for
  `photonvision.service`), so the agent's "safe to switch off" comes quickly; bench test B3 checks
  it stops well inside that.

- **Booting it:** from NVMe with the SPI bootloader, per board (`boards/*.env`, `BOARD_VERIFIED=no`);
  Armbian's boot with the root read-only; `/data` mounted, checked, and bind-mounted before
  PhotonVision starts; the journal kept across a power cut (bench test B3).
- **PhotonVision's image as `provision.sh` expects it:** its partition layout (one root partition,
  then free space; the engine's `layout.sh` handles MBR or GPT), the Armbian units it turns off, netplan and
  systemd-networkd, and that the smoke test leaves `photon.sqlite` (PhotonVision's own CI suggests
  so).
- **The network:** NetworkManager taking the robot profile on whichever Ethernet port is plugged in
  (the 5 Plus has two), and its duplicate-address detection keeping a second drive for the same
  computer off the address.
- **Windows:** that it opens `COPROC` from a USB enclosure and leaves the other partitions alone;
  Imager and Rufus writing through an enclosure.
- **Sizes and times:** the raw image is about the base image plus 1 GiB of root headroom plus 8 GiB
  of data; whether CI's runners have the room and time for several boards at once.
- **The bootloader** steps, per board, above.
