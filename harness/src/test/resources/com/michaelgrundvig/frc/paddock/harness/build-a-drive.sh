#!/bin/bash
# Run by BuiltImageContainerTest as root in its privileged builder (Images.builder), with this
# machine's /dev: makes a base like a board's, builds /team's images with local-build.sh, and copies
# the computer's drive's partitions out to /out/p1.fs, p2.fs, ... for the test to read.
set -euo pipefail

# --- The base: /rootfs as a drive's image, a boot partition then the root, named in its fstab as
# Raspberry Pi OS names them (the boot partition by PARTUUID). The root's /var/lib/team has the
# base's own state, for the data partition. ---
mkdir -p /rootfs/boot/firmware /rootfs/var/lib/team /served
echo 'what the base had' >/rootfs/var/lib/team/state
printf 'LABEL=rootfs / ext4 defaults,noatime 0 1\nPARTUUID=0b1c2d3e-01 /boot/firmware ext4 defaults 0 2\n' >/rootfs/etc/fstab
base=/served/base.img
truncate -s 1G "$base"
printf 'label: dos\nlabel-id: 0x0b1c2d3e\nstart=2048, size=65536, type=83\nstart=67584, type=83\n' |
  sfdisk --quiet "$base"
mkfs.ext4 -q -F -L boot -E offset=$((2048 * 512)) "$base" 32768k
mkfs.ext4 -q -F -L rootfs -d /rootfs -E offset=$((67584 * 512)) "$base" $(((2097152 - 67584) / 2))k
gzip -1 "$base"

# --- The team's repository, pinned to the base and its package. ---
cd /team
dpkg-deb --root-owner-group --build package /served/example-tool_1.0.0_all.deb >/dev/null
S=$(sha256sum </served/base.img.gz | cut -c1-64) yq -i '.images.vision.from.sha256 = strenv(S)' paddock.yaml
S=$(sha256sum </served/example-tool_1.0.0_all.deb | cut -c1-64) \
  yq -i '.images.vision.steps[1].sha256 = strenv(S)' paddock.yaml
# Copied in, so owned by whoever the runtime says: Git takes it as this user's.
git config --global --add safe.directory /team
git init --quiet
# Its origin names the repository, which seeds the machine IDs, as on GitHub.
git remote add origin https://github.com/team/robot-images.git
git add --all
git -c user.name=test -c user.email=test@localhost commit --quiet --message team

/paddock/engine/local-build.sh --team /team --release images-test --out /out 2>&1 | tee /out/build.log

# --- The same repository with a step that fails, inside the chroot: the build leaves nothing behind
# (no partial image, no kept paths, no DNS copy in /tmp). ---
cp -a /team /team-broken
cd /team-broken
printf '#!/bin/sh\necho "a step that fails" >&2\nexit 1\n' >setup/mark.sh
git config --global --add safe.directory /team-broken
git -c user.name=test -c user.email=test@localhost commit --quiet --all --message broken
if /paddock/engine/local-build.sh --team /team-broken --release images-broken --out /out-broken >/out/broken.log 2>&1; then
  echo "the broken build passed" >&2
  exit 1
fi
{
  find /out-broken -maxdepth 1 \( -name '*.img' -o -name '*.keep' \)
  find /tmp -maxdepth 1 -type f
} >/out/leftovers.txt

# --- The computer's drive, a partition at a time. ---
xz -dc /out/release/vision-front-images-test.img.xz | dd of=/out/drive.img bs=4M iflag=fullblock conv=sparse status=none
n=0
while read -r start size; do
  n=$((n + 1))
  dd if=/out/drive.img of="/out/p$n.fs" bs=4M iflag=skip_bytes,count_bytes skip=$((start * 512)) \
    count=$((size * 512)) conv=sparse status=none
done < <(sfdisk --json /out/drive.img | yq -p json -o tsv '.partitiontable.partitions[] | [.start, .size]')
