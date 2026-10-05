#!/usr/bin/python3
"""Reports a USB camera's frame rate to the journal every few seconds.

A stand-in for your own program: anything you'd run on a coprocessor goes in the same way. Which
camera it opens, and that camera's calibration, come from /etc/camera-check/camera.json: the same
image on every computer, each stamped with its own camera.json.
"""

import json
import time

import cv2

SETTINGS = "/etc/camera-check/camera.json"
REPORT_EVERY = 5.0


def main():
    with open(SETTINGS) as f:
        settings = json.load(f)
    name, device = settings["name"], settings["device"]
    fx = settings["calibration"]["camera_matrix"][0][0]
    print(f"camera {name} at /dev/video{device}, calibrated fx={fx}", flush=True)
    while True:
        camera = cv2.VideoCapture(device)
        if not camera.isOpened():
            print(f"no camera at /dev/video{device}, trying again in 5 s", flush=True)
            time.sleep(5)
            continue
        frames, started = 0, time.monotonic()
        while camera.read()[0]:
            frames += 1
            elapsed = time.monotonic() - started
            if elapsed >= REPORT_EVERY:
                print(f"{name}: {frames / elapsed:.1f} frames/s", flush=True)
                frames, started = 0, time.monotonic()
        print("lost the camera, reopening it", flush=True)
        camera.release()


if __name__ == "__main__":
    main()
