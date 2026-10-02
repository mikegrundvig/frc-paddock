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

- **PhotonVision's settings tool** (`photonvision-helper.jar`), which runs at stamping and goes
  into no image, bundles [xerial's sqlite-jdbc](https://github.com/xerial/sqlite-jdbc)
  (Apache-2.0, with SQLite, which is in the public domain).
- **`core/src/main/java/com/michaelgrundvig/frc/paddock/json/`** comes from
  [Spotter](https://github.com/mikegrundvig/frc-spotter) (MIT, the same author's), copied so
  Paddock depends on nothing of Spotter's.
- **The images** hold software under the GNU General Public License, version 3, and under other
  licenses: PhotonVision; each board's base image, PhotonVision's own (built by
  photon-image-modifier on Armbian, Debian, and the Linux kernel, mostly GPL); the Debian packages
  a recipe adds; and the packages a team's input lists, each under its own license, with what they
  depend on. So every release of images Paddock publishes carries a `NOTICE.md`, written by the
  recipe (`recipes/<name>/notice.sh`), naming the exact PhotonVision version and each base image,
  with links to their source at those versions, and each of the team's packages by its URL. A
  team that passes its images on, as anyone who flashes them for another team does, offers that
  source by passing on the notice with them.
