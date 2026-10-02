# Third-party software and licenses

Paddock's own code is under the MIT license (`LICENSE`). What else is here, or goes into what
Paddock builds:

## In this repository

- **`core/src/testFixtures/resources/photonvision/schema.sql`** is adapted from
  [PhotonVision](https://github.com/PhotonVision/photonvision) (its `DatabaseSchema` migrations, as
  SQL), Copyright (C) Photon Vision, and keeps PhotonVision's license, the GNU General Public
  License, version 3 or later. It's a fixture for the unit tests, and goes into no image or jar.
- Nothing else here is copied or adapted from PhotonVision's repositories
  ([photonvision](https://github.com/PhotonVision/photonvision) and
  [photon-image-modifier](https://github.com/PhotonVision/photon-image-modifier), both GPL-3.0).
  Paddock uses their released jar and images as inputs, downloaded and checked against its locks,
  and reads facts about them (a board's image name, where its root is, the database's tables) as
  any program using them must.

## In what Paddock builds

- **PhotonVision's pack's helper** (`photonvision-helper.jar`) bundles
  [xerial's sqlite-jdbc](https://github.com/xerial/sqlite-jdbc) (Apache-2.0, with SQLite, which is
  in the public domain) and [Spotter](https://github.com/mikegrundvig/frc-spotter)'s API (MIT).
- **The images** hold software under the GNU General Public License, version 3, and under other
  licenses: PhotonVision; each board's base image, PhotonVision's own (built by
  photon-image-modifier on Armbian, Debian, and the Linux kernel, mostly GPL); Spotter's agent (MIT)
  with its Java runtime (OpenJDK, GPL-2.0 with the Classpath Exception); and the Debian packages a
  recipe adds. So every release of images Paddock publishes carries a `NOTICE.md`, written by the
  recipe (`recipes/<name>/notice.sh`), naming the exact PhotonVision version and each base image,
  with links to their source at those versions. A team that passes its images on, as anyone who
  flashes them for another team does, offers that source by passing on the notice with them.
- **The image workflow** runs PhotonVision's
  [photon-image-runner](https://github.com/PhotonVision/photon-image-runner) action (MIT) to
  provision each common image in a chroot of its base image.
