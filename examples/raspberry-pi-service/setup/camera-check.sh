#!/bin/sh
# Run by Paddock as root inside the image, after the program and its unit are in place: what the
# program needs from Raspberry Pi OS, then its service turned on for every boot.
set -eu

# OpenCV for Python, from Raspberry Pi OS's own archive. You get whatever version the archive has
# when the image builds; for an exact version, pin its .deb with a package step instead.
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends python3-opencv
apt-get clean

# The program at least loads here, so a missing module fails the build instead of the boot.
python3 -c 'import cv2'

systemctl enable camera-check.service
