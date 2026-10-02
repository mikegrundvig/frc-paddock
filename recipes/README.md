# Recipes

A recipe says how to make one kind of coprocessor image: which base image, which software, and
which packs. Paddock's engine (`engine/`) does what every recipe shares: it checks the inputs,
downloads them against their locks, installs Spotter's agent and the packs, lays out the drive,
stamps each computer, and writes the release with its checksums, manifest, and license notice. A
team picks a recipe in its table (`image.recipe`) or in the workflow's `recipe` input; without
either, it's `photonvision-orangepi`.

| Recipe | What |
|---|---|
| `photonvision-orangepi` | PhotonVision on an Orange Pi 5-family board: PhotonVision's own image for the board, its jar pinned by the lock, a read-only root and `/data` |

## What a recipe provides

A folder, `recipes/<name>/`, holding:

| File | What | Who runs it |
|---|---|---|
| `recipe.env` | Its facts, as bash variables: `RECIPE_TITLE`; `RECIPE_BOARDS`, the boards it builds for; `RECIPE_ARCH` and `RECIPE_RUNNER`, the images' architecture and the GitHub runner that provisions them natively; `RECIPE_LOCK`, its lock's file name; `RECIPE_INPUTS`, the lock's inputs to download besides the base image, as `name=.path` (the lock's member holding its `url` and `sha256`); `RECIPE_VERSION_LABEL`, the stamp label the lock's version goes under; `RECIPE_PACKS`, the packs Paddock builds that it installs; `RECIPE_SSH_USER`, the login SSH keys go to | Every engine script |
| `boards/<board>.env` | Each board's facts: `BOARD_TITLE`; `BOARD_BASE_ASSET`, its base image's file name (the lock's URL must end in it); `BOARD_ROOT_LOCATION` and `BOARD_MINIMUM_FREE_MB`, for photon-image-runner; `BOARD_ROOT_PARTITION` and `BOARD_BOOT_PATH`, the base image's layout | `plan.sh`, `layout.sh`, `stamp-image.sh`, the recipe's own scripts |
| The lock (`RECIPE_LOCK`) | JSON: `version`, the software's; each input's `url` and `sha256`; and `images.<board>.url` and `.sha256`, each board's base image. Nothing is used unchecked | `plan.sh`, `fetch.sh` |
| `provision.sh` | Runs as root in a chroot of the board's base image and makes it the common image. Takes `--board`, `--inputs DIR` (the lock's inputs, downloaded and checked), `--agent-deb FILE`, `--pack DIR` (any number), `--hook FILE` (the team's, run last), and `--out DIR` (what it leaves for stamping). It installs Spotter's agent and the packs with the engine's `install-spotter.sh` | The workflow, through photon-image-runner |
| `stamp-data.sh` (optional) | Writes a computer's own data onto its data partition, and prints stamp labels as `NAME=VALUE` lines. Takes `--computer`, `--data DIR`, `--settings DIR` (the team's settings folder), and `--inputs DIR` (what `provision.sh` left, and the tools) | `stamp.sh` |
| `notice.sh` | Prints the release's `NOTICE.md`: the software in the images under the GPL and other licenses, its exact versions, and where its source is. Takes `--boards` and `--spotter-lock` | The workflow |
| `test/*_test.sh` | Its tests, run with the engine's (`engine/test/run.sh`) | `./gradlew ci` |

A new recipe (plain Raspberry Pi OS with Spotter and the team's hook, say) is a new folder with
these files: the engine and the workflow need no change.
