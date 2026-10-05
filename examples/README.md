# Examples

Each folder is a complete setup: a `paddock.yaml` plus the files and scripts it uses, with every
path relative to that folder. Paddock's CI builds every one of them on each change to Paddock, so
they always build as they stand. They're there to read and borrow from: each README says what its
images give you and what you'd change.

| Example | What |
|---|---|
| [`raspberry-pi/`](raspberry-pi/) | Raspberry Pi OS Lite you can SSH into with your keys, plus a package and a file. The one [Getting started](../docs/getting-started.md) builds |
| [`raspberry-pi-service/`](raspberry-pi-service/) | Your own program as a service: a small Python/OpenCV script started at boot, on two computers sharing one image, each with its own camera calibration |
| [`raspberry-pi-read-only/`](raspberry-pi-read-only/) | A read-only root on a Raspberry Pi, with the journal, SSH keys, and a home folder kept on a small data partition |

Their addresses are placeholders (`10.0.0.x`); yours are `10.TE.AM.x`.

Got a setup that would make a good example? Pull requests are welcome.
