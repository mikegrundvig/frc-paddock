#!/usr/bin/env bash
# notice.sh: prints the license notice a release of this recipe's images carries (NOTICE.md),
# naming the exact software in them and where its source is, as the GPL asks of whoever passes the
# images on.
#
#   notice.sh --boards "BOARD..." --packages FILE
#
#   --packages  the team's packages, as the engine's plan.sh lists them (packages.list)
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../engine/lib/common.sh
. "$here/../../engine/lib/common.sh"
load_recipe "$here"

boards="" packages=""
while (($#)); do
  case $1 in
    --boards) boards=${2:?}; shift 2 ;;
    --packages) packages=${2:?}; shift 2 ;;
    *) die "unknown option: $1" ;;
  esac
done
require_yq
lock=$RECIPE_DIR/$RECIPE_LOCK
version=$(lock_get '.version' "$lock")
jar=$(lock_get '.jar.url' "$lock")
[[ -f $packages ]] || die "no package list at '$packages' (--packages)"

cat <<NOTICE
# The software in these images, and its source

These images were built by [Paddock](https://github.com/mikegrundvig/frc-paddock) (MIT), with its
recipe $(basename "$RECIPE_DIR"). They hold software under the GNU General Public License, version
3 (GPL-3.0), and under other licenses, each its own. Whoever passes the images on must offer the
source of the GPL software in them: it's at the links below.

- **PhotonVision $version** (GPL-3.0): the jar from its release, $jar, built from
  https://github.com/PhotonVision/photonvision/tree/$version
- **Each board's base image** (PhotonVision's, from photon-image-modifier, GPL-3.0), built on
  Armbian (built by https://github.com/PhotonVision/opi-image-generator), Debian, and the Linux
  kernel, each under its own licenses (mostly GPL):
NOTICE
for board in $boards; do
  load_board "$board"
  url=$(BOARD=$board lock_get '.images[strenv(BOARD)].url' "$lock")
  tag=$(sed -n 's|.*/releases/download/\([^/]*\)/.*|\1|p' <<<"$url")
  echo "  - $BOARD_TITLE: ${url##*/}, from $url, built from https://github.com/PhotonVision/photon-image-modifier/tree/$tag"
done
if [[ -s $packages ]]; then
  echo "- **The packages the team's images get**, each under its own license (in the image, each"
  echo "  package's /usr/share/doc/<package>/copyright), from:"
  while read -r _ url; do
    [[ -n $url ]] && echo "  - $url"
  done <"$packages"
fi
cat <<NOTICE
- **Debian's packages the recipe adds** (nvme-cli), and those the team's packages depend on, each
  under its own license, their source at https://sources.debian.org/
NOTICE
