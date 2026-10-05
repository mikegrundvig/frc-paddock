#!/usr/bin/env bash
# release.sh: publishes a release's files as a GitHub release, at the commit they were built from.
#
#   release.sh --dir DIR --release NAME --commit SHA --repository OWNER/NAME [--notice FILE] \
#       [--tag-name NAME]
#
#   --dir       the images, SHA256SUMS and manifest.json (manifest.sh's), and the notice
#   --tag-name  the tag that started the run, if a tag did: the release must be named the same
#
# A release is never replaced. Its tag is created at --commit, or must already point there. Needs gh
# (with GH_TOKEN) and yq.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
. "$here/lib/common.sh"

dir="" release="" commit="" repository="" notice="" tag_name=""
while (($#)); do
  case $1 in
    --dir) need_value "$@"; dir=$2; shift 2 ;;
    --release) need_value "$@"; release=$2; shift 2 ;;
    --commit) need_value "$@"; commit=$2; shift 2 ;;
    --repository) need_value "$@"; repository=$2; shift 2 ;;
    --notice) need_value "$@"; notice=$2; shift 2 ;;
    --tag-name) need_value "$@"; tag_name=$2; shift 2 ;;
    -h | --help) usage ;;
    *) die "unknown option: $1" ;;
  esac
done
[[ -d $dir && -n $release && -n $commit && -n $repository ]] ||
  die "--dir, --release, --commit, and --repository are required"
[[ -f $dir/manifest.json && -f $dir/SHA256SUMS ]] || die "$dir has no manifest.json and SHA256SUMS (manifest.sh writes them)"
[[ -z $notice || -f $dir/$notice ]] || die "no notice $notice in $dir"
require_yq
command -v gh >/dev/null || die "needs gh, GitHub's CLI"

if [[ -n $tag_name && $tag_name != "$release" ]]; then
  die "tag $tag_name started this run, but the release is named $release: they must be the same"
fi
if draft=$(gh release view "$release" --repo "$repository" --json isDraft 2>/dev/null); then
  if [[ $(yq -p json -o yaml -r '.isDraft' <<<"$draft") == true ]]; then
    die "a draft release $release is left from a run that stopped: delete it on the Releases page, then run again"
  fi
  die "release $release already exists, and a release is never replaced: use a new name"
fi

# The tag: made at the commit built, or already there.
if ref=$(gh api "repos/$repository/git/ref/tags/$release" 2>/dev/null); then
  type=$(yq -p json -o yaml -r '.object.type' <<<"$ref")
  sha=$(yq -p json -o yaml -r '.object.sha' <<<"$ref")
  if [[ $type == tag ]]; then
    sha=$(gh api "repos/$repository/git/tags/$sha" | yq -p json -o yaml -r '.object.sha')
  fi
  [[ $sha == "$commit" ]] ||
    die "tag $release points at ${sha:0:12}, but these images were built from ${commit:0:12}: use a new name"
else
  gh api --method POST "repos/$repository/git/refs" -f "ref=refs/tags/$release" -f "sha=$commit" >/dev/null
fi

notes=$(mktemp)
{
  echo "One image per computer, built by Paddock from ${commit:0:12}. Check a download against SHA256SUMS before flashing it."
  echo
  echo "| Computer | Address | Image | File |"
  echo "|---|---|---|---|"
  yq -p json -o yaml -r '.computers[] | "| " + .hostname + " | " + .address + " | " + .image + " | " + .file + " |"' \
    "$dir/manifest.json"
} >"$notes"
files=("$dir"/*.img.xz "$dir/SHA256SUMS" "$dir/manifest.json")
if [[ -n $notice ]]; then
  files+=("$dir/$notice")
fi
gh release create "$release" --repo "$repository" --verify-tag --title "Images $release" \
  --notes-file "$notes" "${files[@]}"
rm -f "$notes"
say "released $release"
