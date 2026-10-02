# shellcheck shell=bash
# Helpers and fixtures for the engine's and the recipes' tests; run.sh sources this into each test.
# $PADDOCK is Paddock's root, $ENGINE the engine's folder, $RECIPE the PhotonVision recipe's, and
# $TMP the test's own temporary directory.

fail() {
  printf 'FAILED: %s\n' "$*" >&2
  exit 1
}

# Ends the test as skipped, saying why.
skip() {
  printf '%s\n' "$*"
  exit 77
}

need() {
  local tool
  for tool; do
    command -v "$tool" >/dev/null 2>&1 || skip "needs $tool"
  done
}

need_yq() {
  need yq
  case "$(yq --version 2>&1)" in
    *mikefarah*" v4."* | *mikefarah*" version 4."*) ;;
    *) skip "needs mikefarah's yq, version 4" ;;
  esac
}

assert_eq() {
  [[ $1 == "$2" ]] || fail "${3:-value}: expected '$2', got '$1'"
}

assert_file() {
  [[ -f $1 ]] || fail "no file $1"
}

assert_no_file() {
  [[ ! -e $1 && ! -L $1 ]] || fail "$1 exists"
}

assert_contains() {
  grep -qF -- "$2" "$1" || fail "$1 doesn't contain '$2'; it holds:$(printf '\n'; cat "$1")"
}

assert_not_contains() {
  if grep -qF -- "$2" "$1"; then
    fail "$1 contains '$2'"
  fi
}

assert_mode() {
  local mode
  mode=$(stat -c %a "$1")
  [[ $mode == "$2" ]] || fail "$1 has mode $mode, expected $2"
}

# A symlink to /dev/null: a masked unit.
assert_masked() {
  [[ $(readlink "$1/etc/systemd/system/$2") == /dev/null ]] || fail "$2 isn't masked"
}

# Runs a command that must fail, saying something that contains TEXT.
assert_fails() {
  local text=$1 output
  shift
  if output=$("$@" 2>&1); then
    fail "expected to fail: $*"
  fi
  [[ $output == *"$text"* ]] || fail "failed, but without '$text': $output"
}

# Every path in a tree with its type, mode, symlink target, and content's sha256: equal digests
# mean equal trees, whatever the files' times.
tree_digest() {
  (
    cd "$1" || exit 1
    find . -printf '%p %y %m %l\n' | LC_ALL=C sort
    find . -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum
  )
}

# A team's repository, as the starter lays it out: Paddock's input (team 1234, two computers on two
# boards, a package, and a file), settings for one computer, and an SSH key. Prints nothing; the
# repository is $TMP/team.
make_team() {
  local team=$TMP/team
  mkdir -p "$team/settings/vision-front/cameras" "$team/packs"
  cat >"$team/paddock.yaml" <<'EOF'
team: 1234
computers:
  - hostname: vision-front
    address: 11
    board: orangepi-5
  - hostname: vision-back
    address: 12
    board: orangepi-5-plus
packages:
  - url: https://example.org/releases/example-tool_1.0.0_arm64.deb
    sha256: 1111111111111111111111111111111111111111111111111111111111111111
files:
  - path: packs/example.yaml
    destination: /etc/example/packs/example.yaml
    mode: "0644"
EOF
  echo 'checks: [example]' >"$team/packs/example.yaml"
  echo '{"userVersion": 2}' >"$team/settings/vision-front/database.json"
  echo '{"name": "front-left", "calibration": [1, 2, 3]}' \
    >"$team/settings/vision-front/cameras/front-left.json"
  echo 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleKeyForTestsOnly team-laptop' \
    >"$team/authorized_keys"
}

# Paddock's engine and recipes, copied to $TMP/paddock, so a test may change a lock.
make_paddock_copy() {
  mkdir -p "$TMP/paddock"
  cp -R "$ENGINE" "$PADDOCK/recipes" "$TMP/paddock/"
}

# The settings tool's stand-in: copies the empty database, appends the rows (so a test can see
# they arrived), logs its arguments to $TMP/tool.log, and prints a hash of the rows; into
# $TMP/inputs, with the empty database, as stamping finds them.
make_settings_tool() {
  mkdir -p "$TMP/inputs"
  cat >"$TMP/inputs/settings-tool" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
rows=$1 empty=$2 out=$3
printf '%s\n' "$@" >"${TOOL_LOG:?}"
cp "$empty" "$out"
rows_text() {
  if [[ -d $rows ]]; then
    (cd "$rows" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 -r cat)
  fi
}
rows_text >>"$out"
rows_text | sha256sum | cut -c1-64
EOF
  chmod +x "$TMP/inputs/settings-tool"
  printf 'SQLite format 3 (empty, for the tests)\n' >"$TMP/inputs/empty-photon.sqlite"
}

# The root of an image as stamping finds it, in $TMP/out/root: its os-release, Debian's way (a link
# from /etc to /usr/lib).
make_stamp_root() {
  local root=$TMP/out/root
  mkdir -p "$root/etc" "$root/usr/lib" "$TMP/out/coproc" "$TMP/out/data"
  if [[ ! -e $root/usr/lib/os-release ]]; then
    printf 'PRETTY_NAME="Armbian (fixture)"\nNAME="Debian GNU/Linux"\nID=debian\n' \
      >"$root/usr/lib/os-release"
  fi
  [[ -e $root/etc/os-release || -L $root/etc/os-release ]] || ln -s ../usr/lib/os-release "$root/etc/os-release"
}

# Runs stamp.sh for a computer of make_team's input into $TMP/out/{root,coproc,data}, with any
# extra options after the name.
run_stamp() {
  local name=$1
  shift
  make_stamp_root
  TOOL_LOG=$TMP/tool.log "$ENGINE/stamp.sh" --computer "$name" --config "$TMP/team/paddock.yaml" \
    --recipe-dir "$RECIPE" --root "$TMP/out/root" --coproc "$TMP/out/coproc" --data "$TMP/out/data" \
    --release coprocessors-1 \
    --recipe-hash 2222222222222222222222222222222222222222222222222222222222222222 \
    --label photonvisionVersion=v2027.0.0-alpha-2 \
    --keys "$TMP/team/authorized_keys" --settings "$TMP/team/settings" --inputs "$TMP/inputs" "$@"
}

# A root shaped like PhotonVision's Armbian image, as far as provision.sh looks at it, in
# $TMP/root; and a PhotonVision jar, a team's package, and a team's file, in $TMP.
make_image_root() {
  local root=$TMP/root
  mkdir -p "$root"/{boot,root,usr/lib,var/lib/dbus,etc/default,etc/netplan,etc/ssh/sshd_config.d} \
    "$root/etc/NetworkManager/system-connections" "$root/etc/systemd/system" "$root/lib/systemd/system"
  printf 'PRETTY_NAME="Armbian (fixture)"\nID=debian\n' >"$root/etc/os-release"
  mkdir -p "$root/usr/sbin"
  printf '#!/bin/sh\n' >"$root/usr/sbin/NetworkManager"
  chmod +x "$root/usr/sbin/NetworkManager"
  : >"$root/boot/boot.scr"
  printf 'verbosity=1\nrootdev=UUID=0b1c2d3e-0000-4000-8000-000000000000\nrootfstype=ext4\n' \
    >"$root/boot/armbianEnv.txt"
  cat >"$root/etc/systemd/system/photonvision.service" <<'EOF'
[Unit]
Description=Service that runs PhotonVision
After=network.target

[Service]
WorkingDirectory=/opt/photonvision
Nice=-10
AllowedCPUs=4-7
ExecStart=/usr/bin/java -Xmx512m -jar /opt/photonvision/photonvision.jar
Type=simple
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
  printf 'Include /etc/ssh/sshd_config.d/*.conf\nKbdInteractiveAuthentication no\nUsePAM yes\n' \
    >"$root/etc/ssh/sshd_config"
  echo 'not a real key' >"$root/etc/ssh/ssh_host_ed25519_key"
  echo 'not a real key' >"$root/etc/ssh/ssh_host_ed25519_key.pub"
  cat >"$root/etc/fstab" <<'EOF'
# <file system> <mount point> <type> <options> <dump> <pass>
UUID=0b1c2d3e-0000-4000-8000-000000000000 / ext4 defaults,noatime,commit=120,errors=remount-ro 0 1
tmpfs /tmp tmpfs defaults,nosuid 0 0
proc /proc proc defaults 0 0
EOF
  printf 'ENABLED=true\nSIZE=50M\nUSE_RSYNC=true\n' >"$root/etc/default/armbian-ramlog"
  printf 'network:\n  version: 2\n  renderer: networkd\n  ethernets:\n    all-eth:\n      match:\n        name: "e*"\n      dhcp4: yes\n' \
    >"$root/etc/netplan/10-dhcp-all-interfaces.yaml"
  printf '[connection]\nid=Wired connection 1\ntype=ethernet\n' \
    >"$root/etc/NetworkManager/system-connections/old.nmconnection"
  echo 0123456789abcdef0123456789abcdef >"$root/etc/machine-id"
  # The logins, as PhotonVision's Orange Pi image ships them: the console logs root in with no
  # password, and root and photon have the public default passwords (stand-in hashes here).
  local getty
  for getty in getty serial-getty; do
    mkdir -p "$root/etc/systemd/system/$getty@.service.d"
    # shellcheck disable=SC2016 # $TERM is the unit's, as the base image writes it
    printf '[Service]\nExecStart=\nExecStart=-/sbin/agetty --noissue --autologin root %%I $TERM\nType=idle\n' \
      >"$root/etc/systemd/system/$getty@.service.d/override.conf"
  done
  mkdir -p "$root/etc/systemd/system/getty.target.wants" "$root/etc/sudoers.d"
  ln -s /lib/systemd/system/getty@.service "$root/etc/systemd/system/getty.target.wants/getty@tty1.service"
  ln -s /lib/systemd/system/serial-getty@.service \
    "$root/etc/systemd/system/getty.target.wants/serial-getty@ttyFIQ0.service"
  cat >"$root/etc/shadow" <<'EOF'
root:$y$j9T$fixture$NotARealHashRoot:20718:0:99999:7:::
daemon:*:20697:0:99999:7:::
sshd:!*:20697::::::
photon:$y$j9T$fixture$NotARealHashPhoton:20718:0:99999:7:::
EOF
  cp "$root/etc/shadow" "$root/etc/shadow-"
  chmod 0640 "$root/etc/shadow" "$root/etc/shadow-"
  echo 'photon ALL=(ALL) NOPASSWD: ALL' >"$root/etc/sudoers.d/010_photon-nopasswd"

  mkdir -p "$TMP/inputs"
  echo 'photonvision jar' >"$TMP/inputs/photonvision.jar"
  make_software
}

# A team's package, as a .deb: example-tool, a program and its unit, with maintainer scripts (which
# --offline doesn't run), in $TMP/packages/00-example-tool_1.0.0_arm64.deb.
make_package() {
  need dpkg-deb
  local pkg=$TMP/example-package
  rm -rf "$pkg"
  mkdir -p "$pkg/DEBIAN" "$pkg/usr/bin" "$pkg/usr/lib/systemd/system" "$TMP/packages"
  printf '#!/bin/sh\necho example\n' >"$pkg/usr/bin/example-tool"
  chmod 0755 "$pkg/usr/bin/example-tool"
  printf '[Service]\nExecStart=/usr/bin/example-tool\n[Install]\nWantedBy=multi-user.target\n' \
    >"$pkg/usr/lib/systemd/system/example-tool.service"
  printf '#!/bin/sh\nset -e\ndeb-systemd-helper enable example-tool.service\n' >"$pkg/DEBIAN/postinst"
  chmod 0755 "$pkg/DEBIAN/postinst"
  printf 'Package: example-tool\nVersion: 1.0.0\nArchitecture: arm64\nMaintainer: nobody <nobody@localhost>\nDescription: a team'"'"'s package, for the tests\n' \
    >"$pkg/DEBIAN/control"
  dpkg-deb --root-owner-group --build "$pkg" "$TMP/packages/00-example-tool_1.0.0_arm64.deb" >/dev/null
}

# The team's files, as plan.sh writes them: a pack read by root alone, and a script others may run,
# in $TMP/software/files.
make_files() {
  local files=$TMP/software/files
  mkdir -p "$files"
  echo 'checks: [example]' >"$files/0"
  printf '#!/bin/sh\necho checked\n' >"$files/1"
  printf '0600 /etc/example/packs/example.yaml 0\n0755 /opt/team/check.sh 1\n' >"$files/files.list"
}

# What a team's images get: a package and two files.
make_software() {
  make_package
  make_files
}

# Runs the recipe's provision.sh on make_image_root's tree, offline, with any extra options.
run_provision() {
  "$RECIPE/provision.sh" --board orangepi-5 --target "$TMP/root" --offline \
    --inputs "$TMP/inputs" --packages "$TMP/packages" --files "$TMP/software/files" "$@"
}
