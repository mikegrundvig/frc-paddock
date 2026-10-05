# Your own program on Raspberry Pis

Raspberry Pi OS Lite running a program of yours as a service: started at boot, restarted if it
stops, logging to the journal. Two computers share one image, and each is stamped with its own
camera's settings, the way you'd handle camera calibration. The program here is a small Python
script that reports a USB camera's frame rate, standing in for whatever you'd actually run, like
vision code, a logger, or a dashboard.

## What you get

- **`camera-check`**, started at boot on both computers. It runs as its own user (not root) with
  access to the cameras, and comes back 5 seconds after it stops. `journalctl -u camera-check -f`
  shows what it's saying.
- **Each computer's own `/etc/camera-check/camera.json`:** which camera it opens and that camera's
  calibration. Same image, different cameras.
- **OpenCV for Python**, installed from Raspberry Pi OS's own archive.
- **Log in as `pi` with your SSH keys**, the same as the [raspberry-pi example](../raspberry-pi/).

## How it fits together

1. Two `file` steps put the program at `/opt/camera-check/` and its systemd unit at
   `/etc/systemd/system/camera-check.service`.
2. `setup/camera-check.sh` installs what the program needs with `apt-get`, checks the program can
   at least load, and enables the service. Enabling is all a step can do: nothing actually starts
   until the computer boots.
3. Each computer's `files:` in `paddock.yaml` puts its own `camera.json` in place when that
   computer is stamped. When you recalibrate a camera, commit its new file and release: every
   computer is rebuilt from the same image, and each gets its own settings.

To run your own program instead, swap in its files, its unit, and the packages it needs. Something
that's a single file (a jar, a binary) and lives in its own release can come in through a
`download` step instead, pinned by SHA-256.

Packages installed with `apt-get` in a script are whatever version Raspberry Pi OS's archive has
when the image builds. That's usually fine; if you need an exact version, pin its `.deb` with a
`package` step.

## Make it yours

1. Your addresses in `paddock.yaml`: `10.TE.AM.x/24`, gateway `10.TE.AM.4`.
2. Your SSH public keys in `keys/authorized_keys`, one per line: each person's own, never a private
   key ([Control who can log in](../../docs/how-to.md#control-who-can-log-in)).
3. Your program, its unit, and its packages in place of `camera-check`.
4. Each computer's own files under `computers/`, like your cameras' real calibrations.

## What's here

| Path | What |
|---|---|
| `paddock.yaml` | The image and its two computers, each with its own files |
| `app/camera-check.py` | The program |
| `app/camera-check.service` | Its systemd unit |
| `computers/*/camera.json` | Each computer's camera and its calibration |
| `setup/camera-check.sh` | Installs OpenCV, checks the program loads, enables the service |
| `setup/login.sh`, `keys/authorized_keys` | Logging in as `pi` with your keys |
| `NOTICE.md` | What's in the image, and where its source is |

## On the board

On top of [the hardware checklist](../../docs/hardware-checklist.md):

1. `systemctl status camera-check` says it's running, as a user that isn't root.
2. `journalctl -u camera-check` starts with this computer's camera name and calibration.
3. With a USB camera plugged in, `journalctl -u camera-check -f` reports its frame rate; unplug it
   and it says so, plug it back in and it picks up again.
