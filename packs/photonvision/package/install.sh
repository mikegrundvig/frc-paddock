#!/bin/sh
# Installs PhotonVision's pack (docs/photonvision-pack.md): this folder, as built
# (./gradlew :photonvision-pack:packFolder), into /usr/lib/frc-spotter/packs/photonvision, and
# its polkit rule. Spotter's agent must be installed too; a computer runs the pack once its
# configuration (/etc/frc-spotter/agent.json) names it, and the agent restarts.
#
#   install.sh [--root DIR]    DIR: an image's root, being built (a chroot); / when not given
set -eu
root=/
while [ $# -gt 0 ]; do
  case $1 in
    --root) root=${2:?--root needs a folder}; shift 2 ;;
    *) echo "install.sh: unknown option $1" >&2; exit 2 ;;
  esac
done
here=$(cd "$(dirname "$0")" && pwd)
target="$root/usr/lib/frc-spotter/packs/photonvision"
mkdir -p "$target/bin" "$target/lib" "$root/usr/share/polkit-1/rules.d"
install -m 0644 "$here/pack.json" "$target/pack.json"
install -m 0755 "$here/bin/photonvision-helper" "$target/bin/photonvision-helper"
install -m 0644 "$here/lib/photonvision-helper.jar" "$target/lib/photonvision-helper.jar"
install -m 0644 "$here/61-frc-spotter-photonvision.rules" \
  "$root/usr/share/polkit-1/rules.d/61-frc-spotter-photonvision.rules"
echo "install.sh: PhotonVision's pack installed in $target"
