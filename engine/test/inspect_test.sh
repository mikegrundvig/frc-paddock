# shellcheck shell=bash disable=SC1090,SC1091 # tests source the engine by computed paths
# inspect-root.sh: a built root checked against its steps and its init's rules, every problem named
# at once. inspect-image.sh's mounting needs root and loop devices: the harness's
# BuiltImageContainerTest runs it.

# A built root that passes, in $TMP/root: the files the vision image's steps put in place (a file:
# 0600, a file: 0755, a download: 0640), a package's unit with the team's drop-in, a unit of the
# team's, and masks of a unit and of an alias the base has.
make_inspected_root() {
  need systemd-analyze systemctl
  [[ -x /usr/lib/systemd/system-generators/systemd-fstab-generator ]] || skip "needs systemd's fstab generator"
  make_root
  local root=$TMP/root units=$TMP/root/usr/lib/systemd/system
  mkdir -p "$units" "$root/etc/systemd/system/example-tool.service.d" "$root/etc/tool" "$root/opt/team"
  # The targets and slices every unit is ordered against, as any systemd image has them.
  cp /usr/lib/systemd/system/*.target /usr/lib/systemd/system/*.slice "$units/"
  printf '#!/bin/sh\necho example\n' >"$root/usr/bin/example-tool"
  chmod 0755 "$root/usr/bin/example-tool"
  printf '[Unit]\nDescription=a package'"'"'s\n[Service]\nExecStart=/usr/bin/example-tool\n[Install]\nWantedBy=multi-user.target\n' \
    >"$units/example-tool.service"
  printf '[Service]\nNice=5\n' >"$root/etc/systemd/system/example-tool.service.d/10-team.conf"
  printf '[Unit]\nDescription=the team'"'"'s\n[Service]\nType=oneshot\nExecStart=/usr/bin/example-tool\n[Install]\nWantedBy=multi-user.target\n' \
    >"$root/etc/systemd/system/team.service"
  printf '[Service]\nExecStart=/usr/bin/example-tool\n' >"$units/rsyslog.service"
  printf '[Service]\nExecStart=/usr/bin/example-tool\n' >"$units/getty@.service"
  ln -s getty@.service "$units/autovt@.service"
  systemctl --root="$root" --quiet enable example-tool.service team.service
  systemctl --root="$root" --quiet mask rsyslog.service autovt@.service
  echo 'checks: [example]' >"$root/etc/tool/tool.yaml"
  chmod 0600 "$root/etc/tool/tool.yaml"
  printf '#!/bin/sh\necho checked\n' >"$root/opt/team/check.sh"
  chmod 0755 "$root/opt/team/check.sh"
  echo 'a model' >"$root/opt/team/model.bin"
  chmod 0640 "$root/opt/team/model.bin"
}

setup_inspect() {
  need_yq
  make_team
  make_plan
  make_inspected_root
}

inspect() {
  "$ENGINE/inspect-root.sh" --plan "$TMP/plan" --image vision --root "$TMP/root"
}

# Each row: what's wrong, what breaks it, and what the inspection must say ("passes" for a root
# that must pass). Each starts from a root that passes.
test_inspect_names_what_is_wrong_with_a_root() {
  local base=$TMP rows what change text output n=0
  rows=$(
    cat <<'ROWS'
a good root	true	passes
a file a step put in place is missing	rm "$TMP/root/opt/team/check.sh"	/opt/team/check.sh isn't in the image, though step 4 (file: setup/check.sh) put it there
a downloaded file has the wrong mode	chmod 0644 "$TMP/root/opt/team/model.bin"	/opt/team/model.bin has mode 0644, but step 5 (download: model.bin) gave it 0640
a build script masks a misspelt unit	systemctl --root="$TMP/root" --quiet mask rsyslg.service	rsyslg.service is masked, but the image has no unit of that name
a drop-in misspells a key	printf '[Service]\nReadWritePath=/opt/team\n' >"$TMP/root/etc/systemd/system/example-tool.service.d/20-team.conf"	Unknown key name 'ReadWritePath'
a drop-in is for a unit the image doesn't have	mkdir -p "$TMP/root/etc/systemd/system/exampel-tool.service.d"	has drop-ins for exampel-tool.service, but the image has no exampel-tool.service
the fstab has a line systemd can't read	echo garbage >>"$TMP/root/etc/fstab"	systemd's fstab generator complains on /etc/fstab
a unit runs a program that isn't there	sed -i 's|^ExecStart=.*|ExecStart=/usr/bin/missing-tool|' "$TMP/root/etc/systemd/system/team.service"	team.service doesn't pass systemd-analyze verify
a later step puts a file where an earlier one did	edit_team '.images.vision.steps += [{"file": "config/tool.yaml", "to": "/opt/team/check.sh", "mode": "0644"}]'; make_plan	/opt/team/check.sh has mode 0755, but step 6 (file: config/tool.yaml) gave it 0644
ROWS
  )
  while IFS=$'\t' read -r what change text; do
    TMP=$base/$((++n))
    mkdir -p "$TMP"
    setup_inspect
    eval "$change"
    if [[ $text == passes ]]; then
      output=$(inspect 2>&1) || fail "$what: the inspection failed: $output"
      [[ $output == *"inspected vision: the 3 file(s) its steps put in place are there"* ]] ||
        fail "$what: it didn't say so: $output"
      continue
    fi
    if output=$(inspect 2>&1); then
      fail "$what: the inspection passed"
    fi
    [[ $output == *"$text"* ]] || fail "$what: the inspection didn't say '$text': $output"
    [[ $output == *"has 1 problem:"* ]] || fail "$what: not exactly one problem: $output"
  done <<<"$rows"
}

test_inspect_names_every_problem_at_once() {
  setup_inspect
  chmod 0644 "$TMP/root/etc/tool/tool.yaml"
  rm "$TMP/root/opt/team/check.sh"
  systemctl --root="$TMP/root" --quiet mask rsyslg.service
  local output
  output=$(inspect 2>&1 || true)
  [[ $output == *"has 3 problems:"* ]] || fail "not 3 problems: $output"
}

test_inspect_wont_follow_an_absolute_link_out_of_the_image() {
  setup_inspect
  mkdir -p "$TMP/elsewhere/tool"
  mv "$TMP/root/etc/tool/tool.yaml" "$TMP/elsewhere/tool/"
  rmdir "$TMP/root/etc/tool"
  ln -s "$TMP/elsewhere/tool" "$TMP/root/etc/tool"
  assert_fails "/etc/tool/tool.yaml (step 1 (file: config/tool.yaml)) can't be checked: it goes through /etc/tool" inspect
}

test_inspect_image_refuses_what_it_cant_inspect() {
  need_yq
  make_team
  make_plan
  assert_fails "--plan and --image are required" "$ENGINE/inspect-image.sh" "$TMP/vision.img"
  assert_fails "no image file" "$ENGINE/inspect-image.sh" --plan "$TMP/plan" --image vision "$TMP/none.img"
  : >"$TMP/vision.img"
  if ((EUID != 0)); then
    assert_fails "needs root" "$ENGINE/inspect-image.sh" --plan "$TMP/plan" --image vision "$TMP/vision.img"
  fi
}
