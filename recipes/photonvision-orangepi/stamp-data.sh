#!/usr/bin/env bash
# stamp-data.sh: the PhotonVision recipe's step at stamping (../README.md): PhotonVision's settings
# database for one computer, on its data partition, built from the team's committed settings.
#
#   stamp-data.sh --computer NAME --data DIR --settings DIR --inputs DIR
#
#   --settings  the team's committed settings: one folder per computer, NAME/, holding
#               database.json and a file per row (a computer without one gets PhotonVision's
#               defaults)
#   --inputs    what provisioning left, and the tools: empty-photon.sqlite (the pinned
#               PhotonVision's own empty database, from its smoke test) and settings-tool
#
# The settings tool is PhotonVision's pack's helper (settings-db): run as
#   settings-tool ROWS_DIR EMPTY_DB OUT_DB
# it builds OUT_DB from EMPTY_DB and the committed rows in ROWS_DIR, and prints the settings hash,
# lowercase hex, as its last line. It prints the stamp label settingsHash=HASH (empty with no
# committed settings). Writing the same inputs twice writes the same bytes.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../engine/lib/common.sh
. "$here/../../engine/lib/common.sh"
load_recipe "$here"

computer="" data="" settings="" inputs=""
while (($#)); do
  case $1 in
    --computer) computer=${2:?}; shift 2 ;;
    --data) data=${2:?}; shift 2 ;;
    --settings) settings=${2-}; shift 2 ;;
    --inputs) inputs=${2-}; shift 2 ;;
    *) die "unknown option: $1" ;;
  esac
done
[[ -n $computer && -d $data ]] || die "--computer and --data (an existing folder) are required"

mkdir -p "$data/$DATA_PV_CONFIG"
chmod 0755 "$data/$DATA_PV_CONFIG"
rows=""
if [[ -n $settings ]]; then
  rows="$settings/$computer"
fi
db="$data/$DATA_PV_CONFIG/photon.sqlite"
rm -f "$db"
# A folder with nothing but a placeholder (.gitkeep) holds no settings.
if [[ -n $rows && -d $rows && -n $(find "$rows" -type f ! -name '.*' -print -quit) ]]; then
  tool=$inputs/settings-tool
  [[ -n $inputs && -x $tool ]] || die "$computer has committed settings: --inputs needs settings-tool"
  [[ -f $inputs/empty-photon.sqlite ]] ||
    die "$computer has committed settings: --inputs needs empty-photon.sqlite, PhotonVision's empty database"
  output=$("$tool" "$rows" "$inputs/empty-photon.sqlite" "$db") ||
    die "the settings tool failed for $computer"
  # The hash is its last line. Anything before it is passed on, not taken for the hash: a JVM
  # prints its own warnings to standard output (one about cgroups, in some containers).
  settings_hash=$(tail -n 1 <<<"$output")
  if [[ $output == *$'\n'* ]]; then
    say "the settings tool also said: $(sed '$d' <<<"$output")"
  fi
  is_sha256 "$settings_hash" || die "the settings tool printed '$settings_hash', not a sha256"
  [[ -f $db ]] || die "the settings tool made no database at $db"
  chmod 0644 "$db"
else
  settings_hash=""
  say "$computer has no committed settings: PhotonVision starts with its defaults"
fi
echo "settingsHash=$settings_hash"
