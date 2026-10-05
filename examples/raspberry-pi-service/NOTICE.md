# Notice

These images hold software under the GNU General Public License and other licenses. Each release's
`manifest.json` names the base image by URL and SHA-256.

- **Raspberry Pi OS Lite** (Debian, mostly GPL): the release `paddock.yaml`'s `from.url` names, with
  its source through https://www.raspberrypi.com/software/ and Debian's archive.
- **OpenCV for Python** (Apache-2.0) and the libraries it needs, from Raspberry Pi OS's archive,
  each under its own license: each package's is in `/usr/share/doc/<package>/copyright` in the
  image.
- **`app/camera-check.py`**: this example's own, under Paddock's MIT license.

Keep this current when you change the base or add software. Pass it on with the images when you
give them to anyone.
