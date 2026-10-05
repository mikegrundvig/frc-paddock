# Getting started

This walks you from an empty repository to a Raspberry Pi you can SSH into, using nothing but the
GitHub website and a flashing tool. Your repository ends up with four files:

```
paddock.yaml                  what to build
setup/login.sh                a step: lets you log in
keys/authorized_keys          your SSH public keys
.github/workflows/images.yml  calls Paddock
```

That's all a Paddock repository is. The same files, plus a couple more steps, are the
[raspberry-pi example](../examples/raspberry-pi/).

## 1. Make a repository

Create a new repository on GitHub, say `robot-images`. Public repositories build for free; private
ones use your plan's Actions minutes. Either way, don't put anything secret in it: anyone who can
download a release can read every file in your images.

You'll add each file below with **Add file → Create new file**: type its path (folders and all)
as the name, paste the contents, and commit.

## 2. `paddock.yaml`

```yaml
images:
  pi:
    from:
      url: https://downloads.raspberrypi.com/raspios_lite_arm64/images/raspios_lite_arm64-2026-09-15/2026-09-15-raspios-trixie-arm64-lite.img.xz
      sha256: cdf4f3bfac35ae947b46e4e767f935453810549779ac3290e05a6754aee627e5
    steps:
      - run: setup/login.sh
computers:
  - hostname: pi-front
    image: pi
    address: 10.12.34.21/24
    gateway: 10.12.34.4
```

`from` is the image you start from, here Raspberry Pi OS Lite, with the SHA-256 that proves it's
the right file. `steps` is what Paddock does to it. Each computer gets its own hostname and address:
on an FRC robot that's `10.TE.AM.x/24`, so team 1234 uses `10.12.34.x`, with the radio at
`10.12.34.4` as the gateway.

## 3. A way to log in

Raspberry Pi OS comes with no way to log in, so a step makes one: SSH, with keys only, no
passwords. Create `setup/login.sh` from the
[raspberry-pi example's](../examples/raspberry-pi/setup/login.sh) (it's short, and each part says
what it's for). It keeps the `pi` user, gives it your keys, and turns SSH on.

## 4. Your SSH key

This is how you'll get in, so it's worth getting right. An SSH key comes in two halves:

- the **private key** stays on your laptop and never goes anywhere else: not in the repository, not
  in a message, not on a USB stick;
- the **public key** goes in your repository. It's safe to share; it only lets in whoever holds the
  matching private key.

Make one on your laptop, if you don't have one already. In PowerShell (Windows 10 and later), or a
terminal on macOS or Linux:

```
ssh-keygen -t ed25519 -C "programming-laptop-2"
```

Press Enter to save it in the usual place, and give it a passphrase if it's your own laptop. The
`-C` label ends up in your public repository, so name the machine, not the person: something that
tells keys apart without anyone's name or email in it. Then show the public half:

```
cat ~/.ssh/id_ed25519.pub
```

That works in PowerShell too. Create `keys/authorized_keys` in your repository with that one line.
Everyone who should be able to log in adds their own line, from their own laptop: never share one
key between people. [Control who can log in](how-to.md#control-who-can-log-in) covers adding
teammates, a shared laptop like the driver station, and removing someone.

## 5. The workflow

Create `.github/workflows/images.yml`:

```yaml
name: Images
on:
  push:
    tags: ["images-*"]
  workflow_dispatch:
    inputs:
      release:
        description: "Release name, such as images-2027.1 (empty: build only)"
        type: string
        default: ""
jobs:
  images:
    uses: mikegrundvig/frc-paddock/.github/workflows/build-images.yml@v1.0.0-beta.1
    permissions:
      contents: write
    with:
      release: ${{ github.ref_type == 'tag' && github.ref_name || inputs.release }}
```

This is the only place Paddock shows up in your repository. `@v1.0.0-beta.1` pins the version, so
your images only change when your repository does.

## 6. Build and release

Go to **Actions → Images → Run workflow**, enter a release name like `images-2027.1`, and run it.
The first job checks your `paddock.yaml` and, if anything's off, lists every problem in the run's
summary ([Troubleshooting](troubleshooting.md) explains them). Then the image builds, each
computer's copy gets stamped, and a release shows up under **Releases** with:

- `pi-front-images-2027.1.img.xz`, one per computer;
- `SHA256SUMS`, to check your download;
- `manifest.json`, what went into each image.

Pushing a tag named `images-*` from Git does the same thing. Releases are never replaced, so if
something's wrong, fix it and release again under a new name, like `images-2027.1.1`.

## 7. Flash

Download your computer's `.img.xz`. It's worth checking before you flash: in PowerShell,
`(Get-FileHash .\pi-front-images-2027.1.img.xz).Hash.ToLower()` should print the same digits as
its line in `SHA256SUMS` (`sha256sum FILE` on Linux, `shasum -a 256 FILE` on macOS).

Flash it with [Raspberry Pi Imager](https://www.raspberrypi.com/software/) (**Choose OS → Use
custom**, then pick the `.img.xz`) or [balenaEtcher](https://etcher.balena.io/). If Raspberry Pi
Imager offers OS customisation, say **No**: Paddock already set the hostname and address.

Each image is for one computer. Two cards flashed from the same image would share an address.

## 8. Boot and log in

Put the card in, plug the Pi into the robot's network, and power it up. From a laptop on the same
network, with an address in the same subnet:

```
ping 10.12.34.21
ssh pi@10.12.34.21
```

You're in. `cat /etc/os-release` shows which release and commit it was built from.

## Next

To change a computer, change your repository, release under a new name, and reflash.
[How-to](how-to.md) covers adding files, packages, and scripts, updating versions, read-only roots,
and more, and [the examples](../examples/README.md) show complete setups.
