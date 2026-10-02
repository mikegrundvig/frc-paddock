# shellcheck shell=bash
# Helpers and fixtures for the engine's and the recipes' tests; run.sh sources this into each test.
# $PADDOCK is Paddock's root, $ENGINE the engine's folder, $RECIPE the PhotonVision recipe's, and
# $TMP the test's own temporary directory. $SPOTTER is Spotter's checkout, beside Paddock's.

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

# A team's repository, as the starter lays it out: the table (team 1234, two computers on two
# boards), settings for one computer, and an SSH key; and each computer's agent configuration, as
# Spotter's build tool writes them. Prints nothing; the repository is $TMP/team.
make_team() {
  local team=$TMP/team
  mkdir -p "$team/settings/vision-front/cameras" "$TMP/agent-configs"
  cat >"$team/coprocessors.yaml" <<'EOF'
team: 1234
agentPort: 5808
computers:
  - name: vision-front
    address: 11
    cameras: [front-left, front-right]
    image:
      board: orangepi-5
  - name: vision-back
    address: 12
    cameras: [back]
    agentPort: 5809
    image:
      board: orangepi-5-plus
EOF
  echo '{"userVersion": 2}' >"$team/settings/vision-front/database.json"
  echo '{"name": "front-left", "calibration": [1, 2, 3]}' \
    >"$team/settings/vision-front/cameras/front-left.json"
  echo 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleKeyForTestsOnly team-laptop' \
    >"$team/authorized_keys"
  local name
  for name in vision-front vision-back; do
    printf '{"name": "%s", "controller": "10.12.34.2", "port": 5808, "packs": ["photonvision"],\n "cameras": [], "probes": []}\n' \
      "$name" >"$TMP/agent-configs/$name.json"
  done
}

# Paddock's engine and recipes, copied to $TMP/paddock, so a test may change a lock.
make_paddock_copy() {
  mkdir -p "$TMP/paddock"
  cp -R "$ENGINE" "$PADDOCK/recipes" "$PADDOCK/spotter.lock" "$TMP/paddock/"
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

# Runs stamp.sh for a computer of make_team's table into $TMP/out/{root,coproc,data}, with any
# extra options after the name.
run_stamp() {
  local name=$1
  shift
  mkdir -p "$TMP/out/root" "$TMP/out/coproc" "$TMP/out/data"
  TOOL_LOG=$TMP/tool.log "$ENGINE/stamp.sh" --computer "$name" --table "$TMP/team/coprocessors.yaml" \
    --recipe-dir "$RECIPE" --root "$TMP/out/root" --coproc "$TMP/out/coproc" --data "$TMP/out/data" \
    --release coprocessors-1 \
    --recipe-hash 2222222222222222222222222222222222222222222222222222222222222222 \
    --agent-config "$TMP/agent-configs/$name.json" --label photonvisionVersion=v2027.0.0-alpha-2 \
    --keys "$TMP/team/authorized_keys" --settings "$TMP/team/settings" --inputs "$TMP/inputs" "$@"
}

# A root shaped like PhotonVision's Armbian image, as far as provision.sh looks at it, in
# $TMP/root; and the agent's jar and unit, and a PhotonVision jar, in $TMP.
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

  make_agent_deb
  make_photonvision_pack
  mkdir -p "$TMP/inputs"
  echo 'photonvision jar' >"$TMP/inputs/photonvision.jar"
}

# The agent's package as built (agent/build.gradle's agentPackage), but for its jar and runtime:
# its real launcher, polkit rules, sysusers file, and maintainer scripts, and its unit from
# $TMP/agent-unit (the real one, copied there first), into $TMP/frc-spotter.deb. A test
# that changes $TMP/agent-unit packs it again by calling this again.
make_agent_deb() {
  local agent=$SPOTTER/agent/package pkg=$TMP/agent-package
  [[ -d $agent ]] || skip "needs Spotter's checkout at $SPOTTER (its agent's package files)"
  need dpkg-deb
  rm -rf "$pkg"
  mkdir -p "$pkg/DEBIAN" "$pkg/usr/lib/frc-spotter/bin" "$pkg/usr/lib/systemd/system" \
    "$pkg/usr/lib/sysusers.d" "$pkg/usr/share/polkit-1/rules.d" \
    "$pkg/usr/lib/frc-spotter/packs/builtin"
  [[ -f $TMP/agent-unit ]] || cp "$agent/frc-spotter.service" "$TMP/agent-unit"
  echo 'agent jar' >"$pkg/usr/lib/frc-spotter/frc-spotter.jar"
  install -m 0755 "$agent/launcher/frc-spotter" "$pkg/usr/lib/frc-spotter/bin/"
  cp "$TMP/agent-unit" "$pkg/usr/lib/systemd/system/frc-spotter.service"
  cp "$agent/frc-spotter.sysusers" "$pkg/usr/lib/sysusers.d/frc-spotter.conf"
  cp "$agent"/*.rules "$pkg/usr/share/polkit-1/rules.d/"
  echo '{"pack": "builtin"}' >"$pkg/usr/lib/frc-spotter/packs/builtin/pack.json"
  install -m 0755 "$agent/debian/postinst" "$agent/debian/prerm" "$agent/debian/postrm" "$pkg/DEBIAN/"
  sed 's/@VERSION@/0.1.0/; s/@ARCH@/arm64/; s/@SIZE@/1/' "$agent/debian/control.in" >"$pkg/DEBIAN/control"
  dpkg-deb --root-owner-group --build "$pkg" "$TMP/frc-spotter.deb" >/dev/null
}

# PhotonVision's pack as built (:photonvision-pack:packFolder), but for its helper's jar.
make_photonvision_pack() {
  local source=$PADDOCK/packs/photonvision/package pack=$TMP/photonvision-pack
  mkdir -p "$pack/bin" "$pack/lib"
  echo '{"pack": "photonvision"}' >"$pack/pack.json"
  echo 'helper jar' >"$pack/lib/photonvision-helper.jar"
  install -m 0755 "$source/launcher/photonvision-helper" "$pack/bin/"
  install -m 0755 "$source/install.sh" "$pack/"
  cp "$source"/*.rules "$pack/"
}

# Runs the recipe's provision.sh on make_image_root's tree, offline, with any extra options.
run_provision() {
  "$RECIPE/provision.sh" --board orangepi-5 --target "$TMP/root" --offline \
    --inputs "$TMP/inputs" --agent-deb "$TMP/frc-spotter.deb" \
    --pack "$TMP/photonvision-pack" "$@"
}
