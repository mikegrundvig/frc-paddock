# Notice

These images hold software under the GNU General Public License and other licenses. Each release's
`manifest.json` names every base image and package in them by URL and SHA-256.

- **PhotonVision** (GPL-3.0): the release `paddock.yaml`'s `download` step names, with its source at
  https://github.com/PhotonVision/photonvision at that release.
- **PhotonVision's base image for the Orange Pi,** built on Armbian, Debian, and the Linux kernel
  (mostly GPL): the release `vision`'s `from.url` names, with its source at
  https://github.com/PhotonVision/photon-image-modifier at that release.
- **PhotonVision's own release image,** built on Joshua Riek's Ubuntu 24.04 for Rockchip (mostly
  GPL): the release `vision-release`'s `from.url` names, with its source at
  https://github.com/PhotonVision/photonvision and https://github.com/Joshua-Riek/ubuntu-rockchip.

Keep this current when you change a base or add a package. Pass it on with the images when you give
them to anyone.
