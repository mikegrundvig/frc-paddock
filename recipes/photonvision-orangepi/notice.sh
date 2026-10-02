#!/usr/bin/env bash
# notice.sh: prints the license notice a release of this recipe's images carries (NOTICE.md),
# naming the exact software in them and where its source is, as the GPL asks of whoever passes the
# images on.
#
#   notice.sh --boards "BOARD..." --spotter-lock FILE
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../engine/lib/common.sh
. "$here/../../engine/lib/common.sh"
load_recipe "$here"

boards="" spotter_lock=""
while (($#)); do
  case $1 in
    --boards) boards=${2:?}; shift 2 ;;
    --spotter-lock) spotter_lock=${2:?}; shift 2 ;;
    *) die "unknown option: $1" ;;
  esac
done
require_yq
lock=$RECIPE_DIR/$RECIPE_LOCK
version=$(lock_get '.version' "$lock")
jar=$(lock_get '.jar.url' "$lock")
spotter=$(lock_get '.version' "$spotter_lock")

cat <<NOTICE
# The software in these images, and its source

These images were built by [Paddock](https://github.com/mikegrundvig/frc-paddock) (MIT), with its
recipe $(basename "$RECIPE_DIR"). They hold software under the GNU General Public License, version
3 (GPL-3.0), and under other licenses, each its own. Whoever passes the images on must offer the
source of the GPL software in them: it's at the links below.

- **PhotonVision $version** (GPL-3.0): the jar from its release, $jar, built from
  https://github.com/PhotonVision/photonvision/tree/$version
- **Each board's base image** (PhotonVision's, from photon-image-modifier, GPL-3.0), built on
  Armbian, Debian, and the Linux kernel, each under its own licenses (mostly GPL):
NOTICE
for board in $boards; do
  load_board "$board"
  url=$(BOARD=$board lock_get '.images[strenv(BOARD)].url' "$lock")
  tag=$(sed -n 's|.*/releases/download/\([^/]*\)/.*|\1|p' <<<"$url")
  echo "  - $BOARD_TITLE: ${url##*/}, from $url, built from https://github.com/PhotonVision/photon-image-modifier/tree/$tag"
done
cat <<NOTICE
- **Spotter's agent $spotter** (MIT): https://github.com/mikegrundvig/frc-spotter/tree/v$spotter,
  with its own Java runtime, OpenJDK's (GPL-2.0 with the Classpath Exception), whose source is at
  https://github.com/openjdk/jdk
- **PhotonVision's pack** (MIT): Paddock's, https://github.com/mikegrundvig/frc-paddock, with
  xerial's sqlite-jdbc (Apache-2.0)
- **Debian's packages the recipe adds** (nvme-cli, polkitd), each under its own license, their
  source at https://sources.debian.org/
NOTICE
