#!/usr/bin/env bash
# run.sh: the engine's and the recipes' tests. Every test_* function in engine/test/*_test.sh and
# recipes/*/test/*_test.sh runs in its own bash, in a fresh temporary directory ($TMP), with
# Paddock's root in $PADDOCK, the engine's folder in $ENGINE, and the PhotonVision recipe's in
# $RECIPE.
#
#   engine/test/run.sh [PATTERN]    # only the tests whose names contain PATTERN
#
# Prints PASS, FAIL (with the test's output), or SKIP (a tool this machine lacks) per test, and
# exits non-zero if any failed. With COPROC_TESTS_STRICT=1 a skip fails too (Linux CI sets it).
# Needs bash and, for most tests, yq (mikefarah's, version 4); the layout tests need sfdisk and
# mkfs.fat, and the provision tests systemctl and dpkg-deb.
set -uo pipefail

test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ENGINE=$(cd "$test_dir/.." && pwd)
PADDOCK=$(cd "$ENGINE/.." && pwd)
RECIPE=$PADDOCK/recipes/photonvision-orangepi
export ENGINE PADDOCK RECIPE
pattern=${1:-}
passed=0
failed=0
skipped=0
for file in "$test_dir"/*_test.sh "$PADDOCK"/recipes/*/test/*_test.sh; do
  [[ -f $file ]] || continue
  names=$(bash -c '. "$1"; . "$2"; declare -F' _ "$test_dir/lib.sh" "$file" | awk '$3 ~ /^test_/ { print $3 }')
  for name in $names; do
    [[ -z $pattern || $name == *"$pattern"* ]] || continue
    tmp=$(mktemp -d)
    output=$(cd "$tmp" && TMP=$tmp bash -c 'set -euo pipefail; . "$1"; . "$2"; "$3"' _ \
      "$test_dir/lib.sh" "$file" "$name" 2>&1)
    status=$?
    rm -rf "$tmp"
    case $status in
      0)
        passed=$((passed + 1))
        printf 'PASS %s\n' "$name"
        ;;
      77)
        skipped=$((skipped + 1))
        printf 'SKIP %s: %s\n' "$name" "$(tail -n 1 <<<"$output")"
        ;;
      *)
        failed=$((failed + 1))
        printf 'FAIL %s\n' "$name"
        while IFS= read -r line; do
          printf '    %s\n' "$line"
        done <<<"$output"
        ;;
    esac
  done
done
printf '%d passed, %d failed, %d skipped\n' "$passed" "$failed" "$skipped"
if [[ ${COPROC_TESTS_STRICT:-0} == 1 ]] && ((skipped > 0)); then
  echo "COPROC_TESTS_STRICT is set: a skipped test fails the run"
  exit 1
fi
((failed == 0))
