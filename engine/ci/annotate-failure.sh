#!/usr/bin/env bash
# annotate-failure.sh: for a failed workflow job, the end of its log as a GitHub annotation, with
# the disk, the mounts and the loop devices (what out-of-space and busy-unmount failures need).
#
#   annotate-failure.sh JOB
set -uo pipefail

log=${WORK:-build/paddock}/job.log
text=$(
  if [[ -f $log ]]; then
    tail -n 60 "$log"
  fi
  echo "--- disk"
  df -h / "${RUNNER_TEMP:-/tmp}" 2>/dev/null
  echo "--- mounts under /tmp"
  findmnt -rn -o TARGET 2>/dev/null | grep '^/tmp/' | head -20
  echo "--- loop devices"
  losetup -l 2>/dev/null | head -10
)
text=${text//'%'/'%25'}
text=${text//$'\r'/'%0D'}
text=${text//$'\n'/'%0A'}
echo "::error title=${1:-job}::$text"
