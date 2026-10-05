# shellcheck shell=bash disable=SC1090,SC1091 # tests source the engine by computed paths
# check_config (lib/common.sh): paddock.yaml checked whole, every problem named at once.

setup_config() {
  need_yq
  make_team
}

check() {
  bash -c '. "$1/lib/common.sh"; check_config "$2"' _ "$ENGINE" "$TMP/team/paddock.yaml"
}

test_config_accepts_the_teams_input() {
  setup_config
  check
}

test_config_accepts_an_image_with_nothing_but_its_base() {
  setup_config
  edit_team 'del(.images.vision.steps) | del(.images.vision["read-only"]) | del(.images.vision.grow)'
  check
}

test_config_names_every_problem_at_once() {
  setup_config
  edit_team '.images.vision.from.url = "http://x" | .computers[0].address = "10.12.34.11" | .extra = 1'
  local output
  output=$(check 2>&1 || true)
  [[ $output == *"has 3 problems"* ]] || fail "not 3 problems: $output"
  [[ $output == *"unknown key 'extra'"* ]] || fail "the unknown key isn't named: $output"
  [[ $output == *"isn't the https:// address of a disk image"* ]] || fail "the URL isn't named: $output"
  [[ $output == *"isn't an IPv4 address and prefix"* ]] || fail "the address isn't named: $output"
}

test_config_refuses_a_key_given_twice() {
  setup_config
  printf 'computers: []\n' >>"$TMP/team/paddock.yaml"
  assert_fails "'computers' is given twice" check
  setup_config
  sed -i 's/^    grow: 2G$/    grow: 2G\n    grow: 1G/' "$TMP/team/paddock.yaml"
  assert_fails "images.vision: 'grow' is given twice" check
}

test_config_refuses_a_bad_base() {
  setup_config
  edit_team '.images.vision.from.url = "https://example.org/base.zip"'
  assert_fails "isn't the https:// address of a disk image" check
  setup_config
  edit_team '.images.vision.from.sha256 = "nope"'
  assert_fails "images.vision.from: sha256 'nope' isn't a SHA-256" check
  setup_config
  edit_team 'del(.images.vision.from.sha256)'
  assert_fails "images.vision.from has no sha256" check
  setup_config
  edit_team '.images.vision.from.arch = "riscv64"'
  assert_fails "isn't arm64 or amd64" check
  setup_config
  edit_team 'del(.images.vision.from)'
  assert_fails "from must be its base" check
  # The base's root is found, not given.
  setup_config
  edit_team '.images.vision.from["root-partition"] = 2'
  assert_fails "unknown key 'root-partition'" check
}

test_config_takes_a_sha256_as_github_and_powershell_show_it() {
  setup_config
  edit_team ".images.vision.from.sha256 = \"sha256:$SHA_A\" | .images.vision.steps[1].sha256 = \"${SHA_1^^}\""
  check
}

test_config_refuses_an_image_name_that_cant_be_an_image_id() {
  setup_config
  edit_team '.images.Vision = .images.vision | del(.images.vision) | .computers[0].image = "Vision" | .computers[1].image = "Vision"'
  assert_fails "can't be an image's name" check
}

test_config_refuses_an_os_value_without_an_adapter() {
  setup_config
  edit_team '.images.vision.os.network = "networkd"'
  assert_fails "os.network 'networkd' isn't supported yet (supported: networkmanager)" check
  setup_config
  edit_team '.images.vision.os.packages = "dnf"'
  assert_fails "isn't supported yet" check
  setup_config
  edit_team '.images.vision.os.kernel = "linux"'
  assert_fails "unknown key 'kernel'" check
}

test_config_accepts_the_default_os_values_spelled_out() {
  setup_config
  edit_team '.images.vision.os = {"packages": "apt", "init": "systemd", "network": "networkmanager", "filesystem": "ext4"}'
  check
}

test_config_refuses_a_bad_size() {
  setup_config
  edit_team '.images.vision.grow = "2TB"'
  assert_fails "grow '2TB' isn't a size" check
  setup_config
  edit_team '.images.vision["read-only"].data = 8'
  assert_fails "read-only.data '8' isn't a size" check
}

test_config_names_steps_from_one_with_what_they_are() {
  setup_config
  edit_team '.images.vision.steps[0].mode = "rw"'
  assert_fails "images.vision step 1 (file: config/tool.yaml): mode 'rw'" check
}

test_config_refuses_a_step_that_isnt_exactly_one_kind() {
  setup_config
  edit_team '.images.vision.steps[0].run = "setup/vision.sh"'
  assert_fails "step 1 must be exactly one of file:, download:, package:, or run:" check
  setup_config
  edit_team '.images.vision.steps += [{"copy": "x"}]'
  assert_fails "step 6 must be exactly one of" check
}

test_config_refuses_a_file_outside_the_folder() {
  setup_config
  edit_team '.images.vision.steps[0].file = "../secret"'
  assert_fails "isn't a path from paddock.yaml's folder" check
  setup_config
  edit_team '.images.vision.steps[0].file = "config/missing.yaml"'
  assert_fails "config/missing.yaml isn't a file in paddock.yaml's folder (names are case-sensitive)" check
  setup_config
  ln -s /etc/passwd "$TMP/team/config/link.yaml"
  edit_team '.images.vision.steps[0].file = "config/link.yaml"'
  assert_fails "isn't a file in paddock.yaml's folder" check
}

test_config_takes_a_files_mode_or_its_default() {
  setup_config
  edit_team 'del(.images.vision.steps[0].mode)'
  check
  setup_config
  edit_team '.images.vision.steps[0].mode = "rw-r--r--"'
  assert_fails "isn't a file's mode in octal" check
}

test_config_refuses_a_step_onto_what_stamping_writes() {
  local path
  for path in /etc/hostname /etc/hosts /etc/os-release /etc/machine-id \
    /etc/NetworkManager/system-connections/paddock.nmconnection; do
    setup_config
    P=$path edit_team '.images.vision.steps[0].to = strenv(P)'
    assert_fails "$path is written at stamping" check
  done
}

test_config_refuses_a_step_onto_what_the_build_mounts() {
  local path
  for path in /dev/sda /proc/x /sys/x /run/x /run/paddock/config/x; do
    setup_config
    P=$path edit_team '.images.vision.steps[0].to = strenv(P)'
    assert_fails "which the build mounts itself" check
  done
}

test_config_refuses_a_step_onto_the_data_partition_or_into_ram() {
  setup_config
  edit_team '.images.vision.steps[0].to = "/data/x"'
  assert_fails "is under /data, where the data partition is mounted" check
  setup_config
  edit_team '.images.vision.steps[0].to = "/var/log/team/tool.yaml"'
  assert_fails "is under /var/log, which is in RAM and empty at every boot" check
  setup_config
  edit_team '.images.vision["read-only"].ram = ["/srv/cache"] | .images.vision.steps[0].to = "/srv/cache/x"'
  assert_fails "is under /srv/cache, which is in RAM" check
  # Without a read-only root, /data and /var/log are just folders.
  setup_config
  edit_team '.images.plain.steps = [{"file": "config/tool.yaml", "to": "/data/x"}, {"file": "config/tool.yaml", "to": "/var/log/x"}]'
  check
}

test_config_refuses_a_bad_package_or_download() {
  setup_config
  edit_team '.images.vision.steps[1].package = "https://example.org/tool.rpm"'
  assert_fails "isn't the https:// address of a .deb" check
  setup_config
  edit_team '.images.vision.steps[1].sha256 = "x"'
  assert_fails "sha256 'x' isn't a SHA-256" check
  setup_config
  edit_team '.images.vision.steps[4].download = "http://example.org/model.bin"'
  assert_fails "isn't the https:// address of a file" check
  setup_config
  edit_team 'del(.images.vision.steps[4].to)'
  assert_fails "has no to:" check
}

test_config_refuses_a_bad_script() {
  setup_config
  edit_team '.images.vision.steps[2].run = "/usr/bin/true"'
  assert_fails "isn't a path from paddock.yaml's folder" check
  setup_config
  edit_team '.images.vision.steps[2].run = "setup/missing.sh"'
  assert_fails "setup/missing.sh isn't a file" check
  setup_config
  printf '#!/bin/sh\r\necho set up\r\n' >"$TMP/team/setup/vision.sh"
  assert_fails "setup/vision.sh has Windows line endings (CRLF)" check
}

test_config_refuses_bad_read_only_paths() {
  setup_config
  edit_team '.images.vision["read-only"].keep = ["/data/x"]'
  assert_fails "is under /data, the data partition itself" check
  setup_config
  edit_team '.images.vision["read-only"].keep = ["relative"]'
  assert_fails "'relative' isn't a path in the image" check
  setup_config
  edit_team '.images.vision["read-only"].keep = ["/run/x"]'
  assert_fails "which the build mounts itself" check
  setup_config
  edit_team '.images.vision["read-only"].ram = ["/srv", "/srv"]'
  assert_fails "/srv is listed twice" check
  setup_config
  edit_team '.images.vision["read-only"] = true'
  assert_fails "read-only must give the data partition's size" check
}

test_config_refuses_kept_or_ram_paths_that_hide_stamped_files() {
  local path
  for path in /etc /etc/NetworkManager /etc/machine-id /usr/lib; do
    setup_config
    P=$path edit_team '.images.vision["read-only"].keep = [strenv(P)]'
    assert_fails "would hide" check
  done
  setup_config
  edit_team '.images.vision["read-only"].ram = ["/etc/NetworkManager/system-connections"]'
  assert_fails "would hide /etc/NetworkManager/system-connections/paddock.nmconnection" check
}

test_config_refuses_a_path_both_kept_and_in_ram() {
  setup_config
  edit_team '.images.vision["read-only"].keep = ["/tmp"]'
  assert_fails "/tmp is in RAM on a read-only root, so it can't also be kept" check
  setup_config
  edit_team '.images.vision["read-only"].keep = ["/srv/team"] | .images.vision["read-only"].ram = ["/srv/team"]'
  assert_fails "/srv/team is both kept and in RAM" check
  # A kept path inside a RAM one is fine: the journal's, under /var/log.
  setup_config
  check
}

test_config_takes_extra_ram_paths_beside_the_defaults() {
  setup_config
  edit_team '.images.vision["read-only"].ram = ["/srv/cache", "/tmp"]'
  check
}

test_config_refuses_bad_computers() {
  setup_config
  edit_team '.computers[1].hostname = "vision-front"'
  assert_fails "two computers have the hostname vision-front" check
  setup_config
  edit_team '.computers[0].hostname = "Vision_Front"'
  assert_fails "can't be a hostname: lowercase letters, digits, and hyphens (such as vision-front)" check
  setup_config
  edit_team '.computers[0].hostname = "localhost"'
  assert_fails "can't be a hostname" check
  setup_config
  edit_team '.computers[0].image = "nope"'
  assert_fails "image 'nope' isn't one of images:" check
  setup_config
  edit_team 'del(.computers[0].image)'
  assert_fails "has no image" check
  setup_config
  edit_team '.computers = []'
  assert_fails "computers lists none" check
}

test_config_takes_plain_ip_addresses() {
  local address
  for address in 10.12.34.11 10.12.34.256/24 10.012.34.11/24 10.12.34.11/33 10.12.34.11/0 10.12.34/24; do
    setup_config
    A=$address edit_team '.computers[0].address = strenv(A)'
    assert_fails "isn't an IPv4 address and prefix" check
  done
  setup_config
  edit_team '.computers[1].address = "10.12.34.11/24"'
  assert_fails "two computers have the address 10.12.34.11" check
}

test_config_refuses_addresses_a_computer_cant_have() {
  local address why
  while read -r address why; do
    setup_config
    A=$address edit_team '.computers[0].address = strenv(A) | del(.computers[0].gateway)'
    assert_fails "$why" check
  done <<'EOF'
10.12.34.0/24 is its subnet's network address
10.12.34.255/24 is its subnet's broadcast address
127.0.0.1/8 isn't an address a computer can have
0.1.2.3/8 isn't an address a computer can have
224.0.0.5/24 isn't an address a computer can have
255.255.255.255/32 isn't an address a computer can have
EOF
  # /31 and /32 have no network or broadcast address.
  setup_config
  edit_team '.computers[0].address = "10.12.34.10/31" | del(.computers[0].gateway)'
  check
}

test_config_checks_the_gateway_and_dns() {
  setup_config
  edit_team '.computers[0].gateway = "10.12.35.4"'
  assert_fails "gateway 10.12.35.4 isn't in its subnet, 10.12.34.11/24" check
  setup_config
  edit_team '.computers[0].gateway = "10.12.34.11"'
  assert_fails "gateway is its own address" check
  setup_config
  edit_team '.computers[0].gateway = "10.12.34.255"'
  assert_fails "gateway 10.12.34.255 is its subnet's broadcast address" check
  setup_config
  edit_team '.computers[0].gateway = "router"'
  assert_fails "gateway 'router' isn't an IPv4 address" check
  setup_config
  edit_team '.computers[2].dns = ["one.one.one.one"]'
  assert_fails "dns 'one.one.one.one' isn't an IPv4 address" check
  # A wider prefix takes a gateway further away.
  setup_config
  edit_team '.computers[0].address = "10.12.34.11/16" | .computers[0].gateway = "10.12.99.1"'
  check
}

test_ipv4_and_sha256_helpers() {
  . "$ENGINE/lib/common.sh"
  is_ipv4 0.0.0.0 || fail "0.0.0.0 is an address"
  is_ipv4 255.255.255.255 || fail "255.255.255.255 is an address"
  ! is_ipv4 1.2.3.04 || fail "a leading zero isn't plain"
  same_subnet 10.12.34.11 10.12.34.4 24 || fail "same /24"
  ! same_subnet 10.12.34.11 10.12.35.4 24 || fail "different /24"
  same_subnet 10.12.34.11 10.12.35.4 16 || fail "same /16"
  ! same_subnet 1.2.3.4 200.0.0.1 1 || fail "different /1"
  assert_eq "$(size_mib 512M)" 512
  assert_eq "$(size_mib 2G)" 2048
  assert_eq "$(normal_sha256 "sha256:${SHA_A^^}")" "$SHA_A"
}

# A computer's own files: like file steps, checked against its image's paths, kept ones included.
test_config_checks_each_computers_own_files() {
  setup_config
  mkdir -p "$TMP/team/computers"
  echo 'fx: 600.0' >"$TMP/team/computers/front.yaml"
  edit_team '.computers[0].files = [{"file": "computers/front.yaml", "to": "/etc/team/camera.yaml"}]'
  check
  edit_team '.computers[0].files = [
    {"file": "computers/missing.yaml", "to": "/etc/team/a.yaml"},
    {"file": "computers/front.yaml", "to": "/etc/hostname"},
    {"file": "computers/front.yaml", "to": "/var/log/camera.yaml"},
    {"file": "computers/front.yaml", "to": "/var/lib/team/camera.yaml"},
    {"file": "computers/front.yaml", "to": "/data/camera.yaml"},
    {"file": "computers/front.yaml", "to": "/etc/team/b.yaml", "mode": "999"},
    {"file": "computers/front.yaml", "to": "/etc/team/b.yaml", "owner": "pi"}]'
  local output
  output=$(check 2>&1 || true)
  [[ $output == *"has 8 problems"* ]] || fail "not 8 problems: $output"
  local want
  for want in "file 1 (computers/missing.yaml): computers/missing.yaml isn't a file" \
    "/etc/hostname is written at stamping" \
    "/var/log/camera.yaml is under /var/log, which is in RAM" \
    "/var/lib/team/camera.yaml is under /var/lib/team, which is kept on the data partition" \
    "/data/camera.yaml is under /data" \
    "mode '999' isn't a file's mode" \
    "/etc/team/b.yaml is listed twice" \
    "unknown key 'owner'"; do
    [[ $output == *"vision-front's $want"* || $output == *"$want"* ]] || fail "'$want' isn't named: $output"
  done
}

test_config_lets_a_writable_images_computer_put_files_anywhere_but_stamped_paths() {
  setup_config
  mkdir -p "$TMP/team/computers"
  echo 'bench' >"$TMP/team/computers/bench.conf"
  edit_team '.computers[2].files = [{"file": "computers/bench.conf", "to": "/var/log/bench.conf"}]'
  check
  edit_team '.computers[2].files = "computers/bench.conf"'
  assert_fails "bench's files must be a list" check
}
