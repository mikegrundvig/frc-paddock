# Paddock

Paddock builds reproducible coprocessor images for an FRC robot. A team keeps only its own data
in its own repository (Paddock's input, `paddock.yaml`; its computers' committed settings; its SSH
keys; and any files its images get) and calls Paddock's image workflow, pinned to a version.
Paddock builds one image per computer, stamped with that computer's identity and settings, and
publishes them as a release of the team's repository, with their checksums, a manifest, and a
license notice.

- **Per-computer stamping.** Each image knows which computer it is: its hostname, its static
  address on the robot network, its committed PhotonVision settings, and labels in
  `/etc/os-release` saying what it is.
- **A read-only root.** What's written while a computer runs goes to a data partition or to RAM, so
  a power cut can't damage the system.
- **A version lock.** Every input (each board's base image, PhotonVision's jar, each of the team's
  packages) is pinned by its SHA-256 and checked before it's used.
- **Whatever software the team lists.** Paddock installs the packages (`.deb`) and copies the files
  the input lists, and knows nothing of what they are. A monitor such as
  [Spotter](https://github.com/mikegrundvig/frc-spotter) is one package and its pack files, like
  any other: Paddock doesn't depend on it.

The fastest start is [frc-paddock-starter](https://github.com/mikegrundvig/frc-paddock-starter), a
template repository with an example input and the short workflow that calls Paddock.

## Using Paddock

A team's repository calls the workflow, pinned to a version (`@v2` follows the latest 2.x):

```yaml
on:
  push:
    tags: ["coprocessors-*"]
  workflow_dispatch:
jobs:
  images:
    uses: mikegrundvig/frc-paddock/.github/workflows/build-images.yml@v2
    permissions:
      contents: write
    with:
      release: ${{ github.ref_type == 'tag' && github.ref_name || '' }}
```

| Input | Default | What |
|---|---|---|
| `config` | `paddock.yaml` | Paddock's input (below) |
| `settings` | `settings` | Committed PhotonVision settings: one folder per computer, `settings/<hostname>/` (a computer without one gets PhotonVision's defaults) |
| `ssh-keys` | `authorized_keys` | The team's SSH public keys (none there: no SSH logins) |
| `provision-hook` | none | A script of the team's, run last as root in each common image (its `$1`: the image's root) |
| `recipe` | `photonvision-orangepi` | Which recipe builds the images (`recipes/`) |
| `vendordep` | none | The robot code's PhotonLib vendordep: its version must be the lock's |
| `release` | none | The release to cut, `coprocessors-<something>` in lowercase; without one, the images are the run's artifacts only |
| `paddock-ref` | `v2` | The Paddock whose engine and recipes build the images: keep it the same as the workflow's `@ref` |

With a release name, the workflow publishes in the team's repository a release holding every
computer's image (`<team>-<hostname>-<release>.img.xz`), `SHA256SUMS`, `manifest.json`, and
`NOTICE.md`. A release is never replaced, and is cut only in the team's own repository, never a
fork. The calling job needs `contents: write` for that.

**Runners.** Each board's common image is provisioned natively on the recipe's runner: GitHub's
ARM runners for PhotonVision on Orange Pi, free for public repositories. A private repository needs
paid ARM runners, or a mentor's machine (below). **Private repositories:** a private repository's
reusable workflow can be called by another private repository of the same owner only when its
Settings, Actions, Access allows it. Paddock is public, so any repository can call it.

## The input: `paddock.yaml`

```yaml
team: 1234                 # addresses are 10.TE.AM.x (team 1234: 10.12.34.x)
computers:
  - hostname: vision-front # lowercase letters, digits, hyphens
    address: 11            # 10.TE.AM.11: FRC's static range for robot devices is .6 to .19
    board: orangepi-5      # one of the recipe's boards
packages:                  # .deb packages every image gets, installed with what they depend on
  - url: https://example.org/releases/tool_1.0.0_arm64.deb
    sha256: 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
files:                     # files every image gets: a path in the repository, from its root
  - path: config/tool.yaml
    destination: /etc/tool/tool.yaml
    mode: "0644"
```

That's all of it: the team number; each computer's hostname, address, and board; and the packages
and files every image gets, in order. Paddock checks it whole before anything is built, and names
every problem at once: a key it doesn't know (or one given twice), a team number that isn't one,
an address outside FRC's range or shared, a board the recipe doesn't build, a package that isn't
an https `.deb` with its SHA-256, a file that isn't in the repository (a link isn't), a destination
on the data partition or one stamping writes (`/etc/hostname`, `/etc/hosts`, `/etc/machine-id`,
`/etc/os-release`, the robot network's profile), or a mode that isn't octal. Each package is
downloaded and checked against its SHA-256, then installed by apt in the image, with what it
depends on from the image's own Debian sources; each file is copied in, root's, with its mode.

The robot code describes the same computers (hostname and address) for itself; Paddock doesn't
read it.

## What's on each image

Besides the recipe's software and the team's, each image carries at stamping (`engine/stamp.sh`):
its hostname, `/etc/hosts`, a machine ID, its robot address, the team's SSH keys, its committed
settings, and its labels in `/etc/os-release`, as
[os-release(5)](https://www.freedesktop.org/software/systemd/man/latest/os-release.html) has an
image builder label an image:

```sh
IMAGE_ID="paddock-photonvision-orangepi"
IMAGE_VERSION="coprocessors-2027.1"
PADDOCK_BOARD="orangepi-5"
PADDOCK_BUILT_AT="2027-01-10T18:30:00Z"
PADDOCK_PHOTONVISION_VERSION="v2027.0.0-alpha-2"
PADDOCK_RECIPE="photonvision-orangepi"
PADDOCK_RECIPE_HASH="…"
PADDOCK_SETTINGS_HASH="…"
```

Anything on the computer can read them, as a monitor reporting the computer's identity does. The
same, as JSON, is Paddock's stamp record, `stamp.json`, on the drive's small `COPROC` partition,
for people to read (Windows opens it), and in the release's `manifest.json`.

## What's here

| Path | What |
|---|---|
| `engine/` | What every recipe shares: `plan.sh` (the input checked, and what the images get), `fetch.sh` (each download checked), `install-software.sh` (the team's packages and files), `layout.sh` (the data partitions), `stamp.sh` and `stamp-image.sh` (each computer's identity and labels), `manifest.sh` (the release's checksums and manifest), `recipe-hash.sh`, `local-build.sh`, and the tests |
| `recipes/` | One folder per kind of image; `recipes/README.md` says what a recipe provides |
| `recipes/photonvision-orangepi/` | PhotonVision on an Orange Pi 5-family board: the first recipe, and its README (what's on a drive, flashing, the bootloader) |
| `core/` | PhotonVision's settings in their canonical form, the AprilTag layout's fingerprint, the lock, and Paddock's build tool (`docs/photonvision-settings.md`) |
| `packs/photonvision/` | PhotonVision's settings tool, which stamping runs to build each computer's settings database |
| `harness/` | The container tests: the real PhotonVision under systemd, set up as an image runs it |
| `fixtures/` | A team's repository for Paddock's own CI, which builds its image end to end |
| `.github/workflows/build-images.yml` | The image workflow teams call |

## Building

```bash
./gradlew ci
```

`./gradlew ci` runs every check: formatting, static analysis, the tests (with the container tests,
when Docker or Podman is there: they download the pinned PhotonVision jar once), the engine's and
the recipes' tests (`engine/test/run.sh`: bash and mikefarah's yq, version 4; the layout tests need
sfdisk and mkfs.fat), and coverage.

**Building on your own machine.** `engine/local-build.sh --team DIR` does what the workflow does,
as root in a privileged container (`--privileged -v /dev:/dev`), with the tools its header lists;
on an x86 machine the recipe's ARM programs also need qemu-user-static registered with its "F"
flag. It mounts images and bind-mounts the machine's `/dev`, so it refuses to run outside a
container unless told `--outside-container`.

## Versions

Paddock is released as `v2.x` tags, with a moving `v2` tag on the latest, so a team pins `@v2` and
gets fixes, or a `v2.x` tag to hold still. Paddock 1 (`v1`, `v1.x`) read the team's
`coprocessors.yaml` and stays where it is.

## License

MIT: see `LICENSE`. The images Paddock builds hold GPL-3.0 software (PhotonVision, and the base
images), and each release carries a notice naming it and its source: see `THIRD-PARTY.md`.
