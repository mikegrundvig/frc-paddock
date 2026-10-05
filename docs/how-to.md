# How-to

One task per section. [The reference](reference.md) has the exact rules for every key.

## Control who can log in

Logging in works the same way in every example: SSH with keys, and no password that works. Each
person who should get in has their own key pair. The **private key** stays on their laptop and
never goes anywhere else. The **public key** goes in your repository's `keys/authorized_keys`, one
line per key, and the next release bakes those lines into the images. Public keys are safe to
share, so a public repository and public releases are fine. Nothing secret is ever in your
repository or your images.

- **Adding someone.** They make a key on their own laptop
  (`ssh-keygen -t ed25519 -C "programming-laptop-2"`, as in
  [Getting started](getting-started.md#4-your-ssh-key)) and send you the public half: the one line
  in `~/.ssh/id_ed25519.pub`. Add it to `keys/authorized_keys`, release, and reflash. Never accept
  a file without `.pub` on the end: that's the private key, and it should never leave their laptop.
- **A shared laptop,** like the driver station, gets its own key and its own line, labelled for
  the machine.
- **Removing someone,** or a lost laptop. Delete the line, release, and reflash every computer.
  Until a computer is reflashed, the old key still gets in, so don't wait on a lost laptop.
- **Labels are public.** The comment at the end of each line (the `-C` label) is visible to
  anyone who can see the repository. Name the machine, not the person.
- **Every key is root** in the examples: `pi` can `sudo` without a password, so anyone whose key is
  listed can do anything on the computer. To give someone a login without that, add another user
  in a step without the `sudo` rule.

Each computer makes its own SSH *host* key the first time it starts, which is how your laptop knows
it's talking to the right computer. That key isn't in the public image either. After a reflash it's
new, so SSH warns you once: `ssh-keygen -R ADDRESS` clears the old one.

## Add things to an image

Steps run in order, as root, inside the image. Paths to your files are relative to
`paddock.yaml`'s folder.

```yaml
steps:
  # A file from your repository. mode is optional ("0644" if you leave it out).
  - file: config/tool.yaml
    to: /etc/tool/tool.yaml
    mode: "0600"
  # A file you want pinned but don't want in Git, like a release's jar.
  - download: https://github.com/owner/tool/releases/download/v1.2.0/tool.jar
    sha256: 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
    to: /opt/tool/tool.jar
  # A .deb package. apt installs it, along with anything it depends on.
  - package: https://github.com/sharkdp/fd/releases/download/v10.5.0/fd_10.5.0_arm64.deb
    sha256: a3128d8e206dd646a27f4637ca081f311df2d6f21cd87bbead7fc92cc0952192
  # A script from your repository, run inside the image.
  - run: setup/tool.sh
```

A `file` or `download` replaces whatever's already there, and `to:` is the file's full path, not
its folder. A script can do anything you'd do as root on the computer: `apt-get install` from the
base's sources, `systemctl enable` or `mask` a service, edit config. It runs in `paddock.yaml`'s
folder with `PADDOCK_CONFIG_DIR` and `PADDOCK_IMAGE` set. Anything a script downloads on its own
isn't checked by Paddock, so pin its versions or use a `download` step instead.

While the steps run, nothing is actually booted: services don't start (so `systemctl start` won't
work, but `enable` will), and anything a step leaves running gets stopped at the end.

## Run your own program

Put the program and its systemd unit in with `file` steps (or a `download` step, for a single file
from a release), then in a script install anything it needs with `apt-get` and
`systemctl enable` the unit. It starts on the computer's first boot and every boot after.
The [raspberry-pi-service example](../examples/raspberry-pi-service/) does exactly this.

## Update a version

Change the `url` and its `sha256` together. If the SHA-256 doesn't match the file, the build fails,
so a stale digest can't sneak through. GitHub shows each file's SHA-256 on its release page; for
anything else, download it and run `Get-FileHash FILE` in PowerShell (or `sha256sum FILE`). Then
release under a new name and reflash.

## Use your own base image

If the image you want to start from isn't published anywhere (one you've customized yourself, say),
put it in a release in your own repository and point `from.url` at it:

1. Compress it if it isn't already: `xz -T0 base.img` gives `base.img.xz`. Each file in a GitHub
   release has to be under 2 GiB.
2. In your repository, **Releases → Draft a new release**. Give it a tag that won't trigger your
   images workflow, like `base-2027.1` (not `images-*`), attach the file, and publish.
3. Copy the file's link from the release page
   (`https://github.com/OWNER/REPO/releases/download/base-2027.1/base.img.xz`) into `from.url`,
   and its SHA-256, shown next to it, into `from.sha256`.

This works for public repositories: Paddock downloads without logging in. Keep that release around,
since rebuilding any image made from it needs it.

## Give computers different images

Each computer names its image, so a robot's computers don't all have to be the same:

```yaml
images:
  vision:
    from: ...
  logger:
    from: ...
computers:
  - hostname: vision-front
    image: vision
    address: 10.12.34.11/24
  - hostname: logger
    image: logger
    address: 10.12.34.21/24
```

Each image is built once, however many computers use it, and an image nobody uses isn't built.

## Give each computer its own files

Camera calibration is the classic case: every vision computer runs the same image, but each one's
camera has its own calibration. List a computer's own files under it, and they're put in place when
that computer is stamped:

```yaml
computers:
  - hostname: vision-front
    image: vision
    address: 10.12.34.11/24
    files:
      - file: computers/vision-front/calibration.json
        to: /etc/vision/calibration.json
  - hostname: vision-back
    image: vision
    address: 10.12.34.12/24
    files:
      - file: computers/vision-back/calibration.json
        to: /etc/vision/calibration.json
```

Your program reads the same path on every computer and gets that computer's own file. A
computer's file replaces whatever the image has at that path, so the image can carry a default.
When you recalibrate, commit the new file and release: the image is built once, and each computer
gets its own files on top. The
[raspberry-pi-service example](../examples/raspberry-pi-service/) does this for two cameras.

## Make the root read-only

```yaml
read-only:
  data: 2G
  keep: [/opt/tool/settings, /var/log/journal]
  ram: [/var/cache/tool]
```

The root gets mounted read-only, so pulling the power can't damage the system. A data partition of
size `data:` goes right after the root and is mounted at `/data`. Each `keep` path lives there and
survives reboots, starting out with whatever the image had in it. `/tmp`, `/var/tmp`, and
`/var/log` are in RAM and start empty at every boot, along with `/var/lib/systemd`,
`/var/lib/NetworkManager`, and anything you list in `ram:`.

Anything else that tries to write fails loudly instead of quietly losing data. Find it with
`journalctl -b -p warning` on the computer, then keep its path, put it in RAM, or turn it off in a
step. The [raspberry-pi-read-only example](../examples/raspberry-pi-read-only/) does all of this for
Raspberry Pi OS, and says why for each part. A few things to watch on any base:

- **Resizing at boot.** Some bases grow their root to fill the drive. With a read-only root the data
  partition sits right after the root, so turn that off in a step. (Raspberry Pi OS does it from
  `cmdline.txt` on every boot; systemd's own first-boot units don't run on a Paddock image anyway,
  see [the reference](reference.md#stamping).)
- **Swap files and other state on the root.** Anything a base keeps writing to the root, like a
  swap file, needs moving to RAM or turning off.
- **The data partition is flashed whole,** so keep `data:` about as big as what you keep needs.
- **No clock battery.** Many boards come back at an old time after a power cut, which can make the
  boot-time check refuse `/data`. The read-only example's `files/e2fsck.conf` shows the fix.

## Check a change without releasing

Run the workflow without a release name. Each computer's image is kept as an artifact of the run
for a week, and nothing gets published. To do this for pull requests too, add `pull_request:` to
your workflow's `on:`.

## Release from Git

```
git tag images-2027.2
git push origin images-2027.2
```

A tag named `images-*` releases under its own name, built from the commit it points at.

## Use a private repository

It works just like a public one, except builds use your plan's Actions minutes (arm64 images build
on GitHub's ARM runners). Only people with access to the repository can download its releases.

## Upgrade Paddock

Change `@v1.0.0-beta.1` in your workflow to the new version and read its release notes: a new major
version may mean changes to `paddock.yaml`. If you'd rather pin an exact commit than a tag, use
`@<full commit SHA>`.

## Build on your own Linux machine

`engine/local-build.sh` does what the workflow does, without publishing anything. It needs root in
a privileged container with the machine's `/dev`, since it mounts images:

```
git clone https://github.com/mikegrundvig/frc-paddock.git
docker run --rm -it --privileged -v /dev:/dev -v "$PWD:/work" -w /work debian:trixie bash
apt-get update && apt-get install -y ca-certificates curl xz-utils fdisk e2fsprogs git mount
curl -fsSLo /usr/local/bin/yq https://github.com/mikefarah/yq/releases/download/v4.54.1/yq_linux_amd64
chmod +x /usr/local/bin/yq
frc-paddock/engine/local-build.sh --team robot-images --release images-test
```

The images end up in `frc-paddock/build/local/release`. Everything the build runs (the base's
programs, packages' scripts, your scripts) runs as root with your machine's devices, so only build
repositories you trust, on a machine you wouldn't mind reinstalling. Building an arm64 image on an
amd64 machine also needs qemu-user-static registered with binfmt_misc's `F` flag.

## Ask for something Paddock doesn't do

[Open an issue](https://github.com/mikegrundvig/frc-paddock/issues) and describe what your images
need. Paddock grows with the teams using it, and pull requests are welcome
([CONTRIBUTING.md](../CONTRIBUTING.md)).
