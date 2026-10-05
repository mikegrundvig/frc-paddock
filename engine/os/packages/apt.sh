# shellcheck shell=bash
# The apt adapter (os: packages: apt): .deb packages, installed by apt with their dependencies from
# the image's own package sources.

packages_check_base() {
  local root=${1%/} tool
  for tool in /usr/bin/dpkg /usr/bin/apt-get /usr/bin/dpkg-deb /usr/bin/dpkg-query; do
    [[ -x $root$tool ]] || echo "no $tool (the apt adapter installs .deb packages with it)"
  done
  return 0
}

# While the steps run, no package may start a service: in a chroot, a package's init script would
# start a real daemon on the build machine, which then holds the image open. Debian's policy-rc.d
# (exit 101) is the standard way; pi-gen and debootstrap use it too.
packages_prepare() {
  local root=${1%/}
  if [[ -e $root/usr/sbin/policy-rc.d ]]; then
    mv -f "$root/usr/sbin/policy-rc.d" "$root/usr/sbin/policy-rc.d.paddock-saved"
  fi
  mkdir -p "$root/usr/sbin"
  printf '#!/bin/sh\n# Paddock: no service starts while an image is built.\nexit 101\n' >"$root/usr/sbin/policy-rc.d"
  chmod 0755 "$root/usr/sbin/policy-rc.d"
}

packages_finish() {
  local root=${1%/}
  # The package lists apt fetched during the steps: download state, not part of the image.
  rm -rf "$root"/var/lib/apt/lists/*
  rm -f "$root/usr/sbin/policy-rc.d"
  if [[ -e $root/usr/sbin/policy-rc.d.paddock-saved ]]; then
    mv -f "$root/usr/sbin/policy-rc.d.paddock-saved" "$root/usr/sbin/policy-rc.d"
  fi
}

# Installs .deb files in order. In the chroot (ROOT /), apt resolves their dependencies and runs
# their maintainer scripts; each must be for the image's architecture and end up at its version.
# OFFLINE=yes (tests, on a folder) unpacks them instead.
packages_install() {
  local root=${1%/} offline=$2 deb arch what name version
  shift 2
  (($#)) || return 0
  if [[ $offline == yes ]]; then
    for deb; do
      dpkg-deb -x "$deb" "${root:-/}"
    done
    return 0
  fi
  [[ -z $root ]] || die "the apt adapter installs inside the image's chroot, at /"
  arch=$(dpkg --print-architecture)
  for deb; do
    what=$(dpkg-deb -f "$deb" Architecture) || die "${deb##*/} isn't a package (.deb)"
    [[ $what == "$arch" || $what == all ]] || die "${deb##*/} is for $what, but this image is $arch"
  done
  apt-get -o Acquire::Retries=5 update -qq
  DEBIAN_FRONTEND=noninteractive apt-get -o Acquire::Retries=5 install -y -qq --no-install-recommends "$@"
  apt-get clean
  for deb; do
    name=$(dpkg-deb -f "$deb" Package)
    version=$(dpkg-deb -f "$deb" Version)
    [[ $(dpkg-query -W -f='${Status} ${Version}' "$name" 2>/dev/null) == "install ok installed $version" ]] ||
      die "${deb##*/} isn't installed at its version, $version"
  done
}
