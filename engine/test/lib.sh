# shellcheck shell=bash disable=SC1090,SC1091 # tests source the engine by computed paths
# Helpers and fixtures for the engine's tests; run.sh sources this into each test. $PADDOCK is
# Paddock's root, $ENGINE the engine's folder, and $TMP the test's own temporary directory.

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

SHA_A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
SHA_B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
SHA_1=1111111111111111111111111111111111111111111111111111111111111111
SHA_2=2222222222222222222222222222222222222222222222222222222222222222

# A team's repository in $TMP/team: Paddock's input with two images
# (one with a read-only root and a step of each kind, one plain, amd64) and three computers, and the
# files and scripts its steps name.
make_team() {
  local team=$TMP/team
  mkdir -p "$team/config" "$team/setup"
  cat >"$team/paddock.yaml" <<EOF
images:
  vision:
    from:
      url: https://example.org/images/base-arm64.img.xz
      sha256: $SHA_A
    grow: 2G
    steps:
      - file: config/tool.yaml
        to: /etc/tool/tool.yaml
        mode: "0600"
      - package: https://example.org/releases/example-tool_1.0.0_arm64.deb
        sha256: $SHA_1
      - run: setup/vision.sh
      - file: setup/check.sh
        to: /opt/team/check.sh
        mode: "0755"
      - download: https://example.org/releases/model.bin
        sha256: $SHA_2
        to: /opt/team/model.bin
        mode: "0640"
    read-only:
      data: 64M
      keep: [/var/lib/team, /var/log/journal]
  plain:
    from:
      url: https://example.org/images/plain-amd64.img
      sha256: $SHA_B
      arch: amd64
computers:
  - hostname: vision-front
    image: vision
    address: 10.12.34.11/24
    gateway: 10.12.34.4
  - hostname: vision-back
    image: vision
    address: 10.12.34.12/24
  - hostname: bench
    image: plain
    address: 192.168.1.50/24
    dns: [192.168.1.1, 1.1.1.1]
EOF
  echo 'checks: [example]' >"$team/config/tool.yaml"
  printf '#!/bin/sh\necho checked\n' >"$team/setup/check.sh"
  printf '#!/bin/sh\necho set up\n' >"$team/setup/vision.sh"
  chmod +x "$team/setup/vision.sh"
}

# Rewrites the team's input with a yq expression.
edit_team() {
  yq -i "$1" "$TMP/team/paddock.yaml"
}

# The team's plan, in $TMP/plan, with a fixed commit, time, and repository name.
make_plan() {
  GITHUB_OUTPUT=$TMP/plan.out "$ENGINE/plan.sh" --config "$TMP/team/paddock.yaml" --repo "$TMP/team" \
    --out "$TMP/plan" --commit 0123456789abcdef0123456789abcdef01234567 \
    --built-at 2027-01-10T18:30:00Z --repository team/robot-images "$@"
}

# A root shaped like a Debian image's, as far as the default adapters look at it, in $TMP/root:
# apt and dpkg, systemd, NetworkManager, an fstab with the root on a PARTUUID, and the base's own
# state in the kept paths.
make_root() {
  local root=$TMP/root tool
  mkdir -p "$root"/{etc,usr/bin,usr/sbin,usr/lib/systemd,var/lib/dbus,var/lib/team,var/log/journal}
  for tool in usr/bin/dpkg usr/bin/apt-get usr/bin/dpkg-deb usr/bin/dpkg-query usr/lib/systemd/systemd \
    usr/sbin/NetworkManager; do
    printf '#!/bin/sh\n' >"$root/$tool"
    chmod +x "$root/$tool"
  done
  printf 'PRETTY_NAME="Debian (fixture)"\nID=debian\n' >"$root/usr/lib/os-release"
  ln -s ../usr/lib/os-release "$root/etc/os-release"
  cat >"$root/etc/fstab" <<'EOF'
# <file system> <mount point> <type> <options> <dump> <pass>
PARTUUID=0b1c2d3e-01 /boot/firmware vfat defaults 0 2
PARTUUID=0b1c2d3e-02 / ext4 defaults,noatime 0 1
tmpfs /tmp tmpfs defaults,nosuid 0 0
EOF
  echo 0123456789abcdef0123456789abcdef >"$root/etc/machine-id"
  echo 'what the base had' >"$root/var/lib/team/state"
  chmod 0750 "$root/var/lib/team"
}

# What fetch.sh downloads for the vision image, in $TMP/inputs: its package (make_package) and
# its download step's file.
make_inputs() {
  make_package
  mkdir -p "$TMP/inputs/downloads"
  echo 'a model' >"$TMP/inputs/downloads/00-model.bin"
}

# A team's package, as a .deb: example-tool, a program and its unit, with a maintainer script
# (which offline steps don't run), in $TMP/inputs/packages/00-example-tool_1.0.0_arm64.deb.
make_package() {
  need dpkg-deb
  local pkg=$TMP/example-package
  rm -rf "$pkg"
  mkdir -p "$pkg/DEBIAN" "$pkg/usr/bin" "$pkg/usr/lib/systemd/system" "$TMP/inputs/packages"
  printf '#!/bin/sh\necho example\n' >"$pkg/usr/bin/example-tool"
  chmod 0755 "$pkg/usr/bin/example-tool"
  printf '[Service]\nExecStart=/usr/bin/example-tool\n[Install]\nWantedBy=multi-user.target\n' \
    >"$pkg/usr/lib/systemd/system/example-tool.service"
  printf '#!/bin/sh\nset -e\ndeb-systemd-helper enable example-tool.service\n' >"$pkg/DEBIAN/postinst"
  chmod 0755 "$pkg/DEBIAN/postinst"
  printf 'Package: example-tool\nVersion: 1.0.0\nArchitecture: arm64\nMaintainer: nobody <nobody@localhost>\nDescription: a team'"'"'s package, for the tests\n' \
    >"$pkg/DEBIAN/control"
  dpkg-deb --root-owner-group --build "$pkg" "$TMP/inputs/packages/00-example-tool_1.0.0_arm64.deb" >/dev/null
}
