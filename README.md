# Paddock

Paddock builds reproducible coprocessor images for an FRC robot, on top of
[Spotter](https://github.com/mikegrundvig/frc-spotter), which watches the coprocessors from the
robot. A team keeps only its own data in its own repository (the table of its coprocessors, their
committed settings, its SSH keys) and calls Paddock's image workflow, pinned to a version. Paddock
builds one image per computer, stamped with that computer's identity and settings, and publishes
them as a release of the team's repository, with their checksums, a manifest, and a license notice.

- **Per-computer stamping.** Each image knows which computer it is: its hostname, its static
  address on the robot network, Spotter's agent's configuration, its committed PhotonVision
  settings, and a stamp the robot checks against its own build.
- **A read-only root.** What's written while a computer runs goes to a data partition or to RAM, so
  a power cut can't damage the system.
- **A version lock.** Every input (each board's base image, PhotonVision's jar, Spotter's agent) is
  pinned by its SHA-256 and checked before it's used.

The fastest start is [frc-paddock-starter](https://github.com/mikegrundvig/frc-paddock-starter), a
template repository with an example table and the ten-line workflow that calls Paddock.

## Using Paddock

A team's repository calls the workflow, pinned to a version (`@v1` follows the latest 1.x):

```yaml
on:
  push:
    tags: ["coprocessors-*"]
  workflow_dispatch:
jobs:
  images:
    uses: mikegrundvig/frc-paddock/.github/workflows/build-images.yml@v1
    permissions:
      contents: write
    with:
      release: ${{ github.ref_type == 'tag' && github.ref_name || '' }}
```

| Input | Default | What |
|---|---|---|
| `table` | `coprocessors.yaml` | The team's table of coprocessors (Spotter's format, its `docs/agent.md`): each computer's name, address, cameras, packs, and `image.board` |
| `settings` | `settings` | Committed PhotonVision settings: one folder per computer, `settings/<computer>/` (a computer without one gets PhotonVision's defaults) |
| `ssh-keys` | `authorized_keys` | The team's SSH public keys (none there: no SSH logins) |
| `packs` | none | A folder of the team's own packs, each `<name>/` with its `pack.yaml` and its programs |
| `provision-hook` | none | A script of the team's, run last as root in each common image (its `$1`: the image's root) |
| `recipe` | the table's `image.recipe`, else `photonvision-orangepi` | Which recipe builds the images (`recipes/`) |
| `vendordep` | none | The robot code's PhotonLib vendordep: its version must be the lock's |
| `release` | none | The release to cut, `coprocessors-<something>`; without one, the images are the run's artifacts only |
| `paddock-ref` | `v1` | The Paddock whose engine and recipes build the images: keep it the same as the workflow's `@ref` |

With a release name, the workflow publishes in the team's repository a release holding every
computer's image (`<team>-<computer>-<release>.img.xz`), `SHA256SUMS`, `manifest.json`, and
`NOTICE.md`. A release is never replaced, and is cut only in the team's own repository, never a
fork. The calling job needs `contents: write` for that.

**Runners.** Each board's common image is provisioned natively on the recipe's runner: GitHub's
ARM runners for PhotonVision on Orange Pi, free for public repositories. A private repository needs
paid ARM runners, or a mentor's machine (below). **Private repositories:** a private repository's
reusable workflow can be called by another private repository of the same owner only when its
Settings, Actions, Access allows it. Paddock is public, so any repository can call it.

## What's here

| Path | What |
|---|---|
| `engine/` | What every recipe shares: `plan.sh` (the inputs checked), `fetch.sh` (each input downloaded and checked against its lock), `install-spotter.sh` (Spotter's agent and the packs), `layout.sh` (the data partitions), `stamp.sh` and `stamp-image.sh` (each computer's identity), `manifest.sh` (the release's checksums and manifest), `recipe-hash.sh`, `local-build.sh`, and the tests |
| `recipes/` | One folder per kind of image; `recipes/README.md` says what a recipe provides |
| `recipes/photonvision-orangepi/` | PhotonVision on an Orange Pi 5-family board: the first recipe, and its README (what's on a drive, flashing, the bootloader) |
| `packs/photonvision/` | PhotonVision's pack for Spotter's agent, and its helper (`docs/photonvision-pack.md`) |
| `core/` | PhotonVision's settings in their canonical form, the AprilTag layout's fingerprint, the lock, the table's rules, and Paddock's build tool |
| `harness/` | The container tests: PhotonVision's pack against the real PhotonVision, on Spotter's harness |
| `spotter.lock` | Spotter's version, and its agent's `.deb` per architecture, by URL and SHA-256 |
| `fixtures/` | A team's repository for Paddock's own CI, which builds its image end to end |
| `.github/workflows/build-images.yml` | The image workflow teams call |

## Building

Paddock builds on Spotter's source, checked out beside it (`../frc-spotter`, at the version
`spotter.lock` pins; `-PspotterBuild=DIR` for another place), through a Gradle composite build. That
becomes Spotter's released artifacts later; the images already install Spotter's released `.deb`.

```bash
git clone https://github.com/mikegrundvig/frc-spotter ../frc-spotter
git -C ../frc-spotter checkout v0.2.0
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

Paddock is released as `v1.x` tags, with a moving `v1` tag on the latest, so a team pins `@v1` and
gets fixes, or a `v1.x` tag to hold still.

## License

MIT: see `LICENSE`. The images Paddock builds hold GPL-3.0 software (PhotonVision, and the base
images), and each release carries a notice naming it and its source: see `THIRD-PARTY.md`.
