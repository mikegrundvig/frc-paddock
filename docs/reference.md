# Reference

## `paddock.yaml`

Two keys: `images` (each image, by name) and `computers`. Paths to your files are relative to
`paddock.yaml`'s folder. Paddock checks the whole file before building anything and lists every
problem at once, including any key it doesn't recognize.

### `images.NAME`

`NAME` is lowercase letters, digits, and hyphens (up to 64). It becomes the image's `IMAGE_ID`.

| Key | Default | What |
|---|---|---|
| `from.url` | required | The base: an `https://` link ending in `.img`, `.img.xz`, or `.img.gz` |
| `from.sha256` | required | The base's SHA-256: 64 hex digits, either case, `sha256:` prefix allowed |
| `from.arch` | `arm64` | `arm64` or `amd64`. Paddock checks the base really is that, and builds on a GitHub runner of the same kind |
| `os.packages` | `apt` | How the base installs packages (see *Supported bases*) |
| `os.init` | `systemd` | What starts the base |
| `os.network` | `networkmanager` | What configures its network |
| `os.filesystem` | `ext4` | Its root's filesystem |
| `grow` | `1G` | Extra room added to the root for your steps: a size like `512M` or `2G` |
| `steps` | none | What to add, in order (below) |
| `read-only` | none | Makes the root read-only (below) |

### Steps

Each step is exactly one of these. They run in order, as root, in a chroot of the image:

| Step | Keys | What it does |
|---|---|---|
| `file` | `file`, `to`, `mode` (`"0644"`) | Copies a file from your repository to `to`, owned by root, with `mode` |
| `download` | `download`, `sha256`, `to`, `mode` (`"0644"`) | Downloads an `https://` file, checks its SHA-256, and puts it at `to` the same way |
| `package` | `package`, `sha256` | Downloads an `https://` `.deb`, checks it, and installs it with apt, along with its dependencies from the base's sources. It has to match the image's architecture (or be `all`) |
| `run` | `run` | Runs a script from your repository: directly if it's executable and starts with `#!`, otherwise with bash |

- `to:` is a file's full path in the image. It can't be a folder, anything under `/dev`, `/proc`,
  `/sys`, or `/run`, or a file stamping writes (see *Stamping*). With a read-only root it also can't
  be under `/data` or a RAM path.
- `mode` is octal, in quotes: `"0600"`, `"0755"`.
- A file from your repository has to be in `paddock.yaml`'s folder or below it, and not a link.
  Scripts can't have Windows (CRLF) line endings.
- Packages in a row install in one apt call. They don't start any services during the build, and
  apt's package lists are cleaned up afterwards.
- A script runs in `paddock.yaml`'s folder (read-only), with `PADDOCK_CONFIG_DIR` (that folder) and
  `PADDOCK_IMAGE` (the image's name) set. It has the build machine's network and DNS. Anything it
  starts is stopped when the steps finish.
- The image's other partitions are mounted where its `/etc/fstab` says (by `UUID=`, `PARTUUID=`, or
  `LABEL=`), so a step can write to a boot partition.

### `read-only`

| Key | Default | What |
|---|---|---|
| `data` | required | The data partition's size, like `2G` |
| `keep` | none | Paths kept on the data partition across reboots |
| `ram` | none | Extra paths in RAM, on top of the defaults |

The root is mounted read-only. The data partition, labelled `paddock-data`, comes right after the
root and is mounted at `/data`. It's checked at boot, remounted read-only if something's wrong with
it, and the boot won't wait more than 10 seconds for it. Each `keep` path is bound from
`/data/<path>` and starts out with whatever the image had there. In RAM, empty at every boot:
`/tmp`, `/var/tmp`, `/var/log`, `/var/lib/systemd`, `/var/lib/NetworkManager`, and your `ram:`.

A kept path has to be a folder (or not exist yet). It can't be in the default RAM list, also be in
`ram:`, be under `/data`, or hide a file stamping writes. It can sit under a RAM path
(`/var/log/journal` under `/var/log`): `/etc/fstab` mounts each path after its parent.

### `computers`

| Key | Default | What |
|---|---|---|
| `hostname` | required | Lowercase letters, digits, and hyphens, up to 63. Unique |
| `image` | required | One of your `images` |
| `address` | required | IPv4 address and prefix, like `10.12.34.11/24`. Unique, and not a network or broadcast address, `0.x`, `127.x`, or `224.x` and up |
| `gateway` | none | IPv4 address in the computer's subnet |
| `dns` | none | List of IPv4 addresses |
| `files` | none | The computer's own files, each `file`, `to`, and `mode` (`"0644"`), like a `file` step |

A computer's `files` follow the same rules as a `file` step, and replace whatever the image has at
that path, so an image can carry a default that a computer overrides. They're written when the
computer is stamped, after a read-only image's kept paths have moved to the data partition, so on a
read-only root they also can't go under a kept path. They show up in `manifest.json` with their
SHA-256.

## Supported bases

A base has to be a partitioned disk image (MBR or GPT, 512-byte sectors) whose last partition is
its root, with bash, for arm64 or amd64. A read-only root on an MBR image also needs a free slot, so
at most three partitions. Paddock knows four things about a base, each through a small adapter in
`engine/os/`, picked by `os:`:

| Axis | Supported today | What it does |
|---|---|---|
| `packages` | `apt` | Installs `package` steps; needs `apt-get` and `dpkg` |
| `init` | `systemd` | Writes the machine ID; puts `/var/lib/systemd` in RAM |
| `network` | `networkmanager` | Writes each computer's address as a NetworkManager profile that any Ethernet port picks up; puts `/var/lib/NetworkManager` in RAM |
| `filesystem` | `ext4` | Grows and checks the root; formats the data partition |

Before your steps run, Paddock checks the base has apt, dpkg, and systemd, and an ext4 root. After
they run, nothing but NetworkManager can be configuring Ethernet, so nothing fights over the
stamped address: an enabled systemd-networkd, netplan files that don't hand off to NetworkManager,
and ifupdown Ethernet entries each fail the build. A step can turn those off: the build's message
says how for each.

Need a base that doesn't fit? [Open an issue](https://github.com/mikegrundvig/frc-paddock/issues).
Another value for an axis is usually one new adapter file.

## Stamping

Each computer's copy of its image gets:

- `/etc/hostname`, plus `/etc/hosts` listing every computer's address and hostname;
- `/etc/machine-id`, worked out from the repository and hostname: different for every computer,
  the same in every release;
- its own `files`, if it has any;
- its address, as `/etc/NetworkManager/system-connections/paddock.nmconnection`. That profile wins
  over the base's own, and waits 3 seconds to make sure nothing else has the address before taking
  it;
- the image's labels in `os-release` (`/etc/os-release`, or the file it links to):

```sh
IMAGE_ID="pi"
IMAGE_VERSION="images-2027.1"
PADDOCK_BUILT_AT="2027-01-10T18:30:00Z"   # the commit's time
PADDOCK_COMMIT="4f2c..."                   # your commit
```

Stamping the same computer from the same release writes exactly the same bytes.

**Your images never have a "first boot", as far as systemd is concerned.** systemd decides it's
booting for the first time when `/etc/machine-id` is empty, and Paddock fills it in. That's what
keeps each computer's identity and logs stable, and stops a read-only root from looking like a new
computer at every boot, but it means units with `ConditionFirstBoot=yes` never run. On Raspberry Pi
OS those include making the SSH host keys and growing the root filesystem. To bring one back, add a
drop-in in a step that swaps the condition for one of your own; the
[raspberry-pi example's](../examples/raspberry-pi/setup/login.sh) login step does this for SSH host
keys.

## The workflow

`mikegrundvig/frc-paddock/.github/workflows/build-images.yml@VERSION`, called from a job with
`permissions: contents: write`.

| Input | Default | What |
|---|---|---|
| `config` | `paddock.yaml` | Path to `paddock.yaml` from your repository's root |
| `notice` | `NOTICE.md` | Your notice, next to `paddock.yaml`; skipped if it isn't there |
| `release` | none | The release to publish: lowercase letters, digits, `.`, `_`, `-`, up to 64. Empty means build only |

Its jobs are **Check the input** (all of it, before anything downloads), **Image NAME** for each
image on a runner of its architecture, **Stamp HOSTNAME** for each computer, and **Release**. If a
job fails, its summary ends with the last lines of its log, plus the disk and mounts. Paddock's
scripts are checked out at the same commit as the workflow, so the version after `@` decides
everything that runs.

Without a release name, each computer's image is kept as an artifact of the run for 7 days. With
one, the release holds:

| File | What |
|---|---|
| `<hostname>-<release>.img.xz` | Each computer's image |
| `SHA256SUMS` | The SHA-256 of every image and the notice |
| `manifest.json` | The release, its commit and time, and each computer: address, gateway, DNS, image, base, packages and downloads (each by URL and SHA-256), its own files (each by path and SHA-256), file name, and file SHA-256 (`schema: 1`) |
| your notice | If you have one |

A release is never replaced. Its tag is created at the commit that was built, or, if a tag started
the run, it has to be that tag. Forks build but never release.

## Versions

Paddock's versions are tags, `vMAJOR.MINOR.PATCH`. A patch fixes things; a minor adds things without
changing what an existing `paddock.yaml` builds; a major may need changes to your `paddock.yaml`.
While Paddock is in beta, its versions end in `-beta.N` (`v1.0.0-beta.1`), and a new beta may need
small changes to `paddock.yaml`: its release notes say what.
