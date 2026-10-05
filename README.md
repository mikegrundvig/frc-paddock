# Paddock

Paddock builds the disk images for your robot's computers from a Git repository. You describe each
image in a `paddock.yaml`: a base image to start from (Raspberry Pi OS, say) and what to add to it.
Paddock builds it on GitHub, stamps a copy for each computer with its own hostname and address, and
publishes them as a release you can flash.

**Paddock is in beta.** It's built and tested in CI, but it needs real robots. If you have
coprocessor hardware and want to try it,
[open an issue](https://github.com/mikegrundvig/frc-paddock/issues): we'll help you get set up and
work with you to add what your team needs.

```yaml
images:
  pi:
    from:
      url: https://downloads.raspberrypi.com/raspios_lite_arm64/images/raspios_lite_arm64-2026-09-15/2026-09-15-raspios-trixie-arm64-lite.img.xz
      sha256: cdf4f3bfac35ae947b46e4e767f935453810549779ac3290e05a6754aee627e5
    steps:
      - file: files/motd
        to: /etc/motd
      - run: setup/login.sh
computers:
  - hostname: pi-front
    image: pi
    address: 10.12.34.21/24
```

## How it works

Paddock is a reusable GitHub Actions workflow. There's nothing to install and no server to run.
Your repository holds two things:

- `paddock.yaml`, plus any files and scripts it uses;
- a short workflow file that calls Paddock's, pinned to a Paddock version.

Run it (push a tag, or click **Run workflow** on GitHub) and Paddock's workflow checks your
`paddock.yaml`, downloads the base, runs your steps inside it on GitHub's own machines, stamps each
computer's copy, and publishes the images as a release in your repository. To change a computer,
change the repository, run it again, and reflash.

## What it does

- Starts from the base image you point it at and adds your steps, in order: files from your
  repository, downloads, `.deb` packages, and scripts that run inside the image.
- Checks everything it downloads against the SHA-256 you give it, and checks all of `paddock.yaml`
  before building anything, listing every problem at once.
- Can make the root read-only, with a small data partition for what has to survive a reboot, so
  pulling the power can't wreck the system.
- Gives each computer its own files on top of the shared image, like its camera's calibration.
- Labels each image with the release and commit it came from.

## What it doesn't do (yet)

- **Know what's in your image.** It doesn't have recipes or know about any particular software. If
  your base has quirks, like a default user or resizing itself on first boot, you deal with them in
  your steps.
- **Touch a running computer.** No deploying, settings, or monitoring. To change a computer, you
  change the repository, release, and reflash.
- **Build from every base.** Today a base has to be a disk image whose last partition is an ext4
  root, with apt, systemd, and NetworkManager, for arm64 or amd64. Raspberry Pi OS and Armbian-based
  images fit; plain Ubuntu Server doesn't yet, since it uses netplan.
- **Wi-Fi or DHCP.** Each computer gets a static IPv4 address on Ethernet.

## This is a starting point

What's here is what's been needed so far, not where Paddock stops. If you need something it doesn't
do, like another OS, Wi-Fi, or a different filesystem, [open an
issue](https://github.com/mikegrundvig/frc-paddock/issues) and tell us about it. We're happy to
work with teams to add what they need, and pull requests are welcome: supporting another OS is
usually one small file ([CONTRIBUTING.md](CONTRIBUTING.md)).

## Docs

| | |
|---|---|
| [Getting started](docs/getting-started.md) | Your first images, from an empty repository to a computer you can log into |
| [How-to](docs/how-to.md) | Adding steps, running your own program, per-computer files, your own base image, read-only roots, building locally |
| [Reference](docs/reference.md) | Every key of `paddock.yaml`, the workflow, what's stamped, what a release holds |
| [Troubleshooting](docs/troubleshooting.md) | What each error means and what to do about it |
| [Examples](examples/README.md) | Complete inputs to read and borrow from, each one built by Paddock's CI |
| [Contributing](CONTRIBUTING.md) | How Paddock is built and tested |

## License

MIT (`LICENSE`). The images hold your software, not Paddock's: see `THIRD-PARTY.md`.
