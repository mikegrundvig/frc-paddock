# PhotonVision's pack, settings, and layout

What Paddock knows of PhotonVision: its pack, which Spotter's agent runs on each coprocessor; its
settings, in their canonical form for Git; and the AprilTag layout's fingerprint. `core/` (Gradle
`:core`, `com.michaelgrundvig.frc.paddock`) holds the shared code; `packs/photonvision/`
(`:photonvision-pack`) the pack.

## The pack

`packs/photonvision/pack.yaml` (Spotter's pack format, its `docs/agent.md`) checks PhotonVision's
unit, its page (`/api/status`), its version (read from the jar it runs, as the pinned build has no
version over HTTP), its settings' hash, its AprilTag layout's fingerprint, and each configured
camera at the USB port PhotonVision's settings match it by. Before a power-off, it stops
PhotonVision (`systemctl stop photonvision.service`, so it saves its settings), and it serves the
settings as `settings.json` and `settings.zip` downloads. Its polkit rule
(`61-frc-coprocessor-photonvision.rules`) lets the agent's account stop and restart
`photonvision.service`, and nothing more.

**Its helper**, `bin/photonvision-helper`, is its one program: `photonvision-helper.jar`, built
from `core`, run with a fixed command line per use. It reads PhotonVision's SQLite database
read-only, within bounds (a 32 MB file, 16 MB of text, 2 MB a value), with the same code a robot's
build hashes committed settings with. It needs `java.sql`, which Spotter's own runtime leaves out,
so it runs on the board's Java (PhotonVision's, always there on its images), else on the agent's
(`FRC_AGENT_JAVA`) if that has `java.sql`.

| Command | Prints |
|---|---|
| `version JAR` | PhotonVision's version, as its jar says it (`PhotonVersion.versionString`) |
| `hash DB` | The settings' hash (below) |
| `fingerprint DB` | The AprilTag layout's fingerprint; exit 1, saying so, when PhotonVision holds none of its own |
| `camera DB NAME` | Whether that camera is plugged in at the port its settings match it by, and at what speed |
| `settings-json DB` | The settings as canonical rows, with their hash |
| `settings-zip DB COMPUTER` | The settings as a zip laid out like the team's repository |
| `settings-db ROWS_DIR EMPTY_DB OUT_DB` | Builds a database from committed settings, for stamping an image, and prints their hash |

Exit 0 when it found what it was asked for, 1 when it found otherwise, 2 for a wrong command line,
3 when there's no database yet, 4 when it failed; why goes to standard error, which the agent puts
in the probe's detail.

**Measured** against the real PhotonVision v2027.0.0-alpha-2 in the container tests (no cameras):
the settings' hash held through two restarts, and equals the robot's own hash of `settings.json`
and of the files in `settings.zip`; a layout uploaded to PhotonVision (`/api/settings/aprilTagFieldLayout`,
which then restarts itself, answering again within 1.1 to 1.6 s) fingerprints as the robot's copy
does; and soft-off, with the pack's step stopping PhotonVision first, left both ports in about 1 s.

## The AprilTag layout's fingerprint

`LayoutFingerprint` is the SHA-256 of one line per tag, sorted by ID: the ID, the position in
tenths of a millimetre, and roll, pitch, and yaw (WPILib's `Rotation3d` angles) in hundredths of a
degree, each rounded to a whole number, with -180° written as 180°. The robot computes it from the
layout it uses; the pack, from the layout PhotonVision stored. So a layout pushed to a coprocessor
that didn't take shows as a mismatch, and a layout PhotonVision rewrote in its own JSON doesn't.

## Settings in Git

PhotonVision keeps all its settings, calibrations included, in one SQLite database,
`photon.sqlite`: a `global` table (network, hardware, field layout, ...) and a `cameras` table
(each camera's configuration, pipelines, and calibrations), with JSON text in their columns. In
Git, they're one file per row, under `settings/<computer>/` in the team's repository:

```
database.json                  {"userVersion": 2}: the database's schema version
global/networkConfig.json      {"contents": {...}}
cameras/<unique name>.json     {"config_json": {...}, "drivermode_json": null, ...}
```

Each file is the row's columns, each column's JSON as JSON (so a diff shows a calibration's
changed member, not a changed line of escaped text), sorted and indented by `Json.pretty`. A key
becomes a file name with everything but letters, digits, `.`, `_`, and `-` written as `%XX`, as
are a leading dot and the names Windows reserves, so every key makes a file on every system; two
keys that differ only in case would be one file on Windows, and are refused. A column whose text
isn't JSON is kept as text, under its name plus `.text`.

Sorted members are safe for PhotonVision to read back: its JSON library (avaje-jsonb) generates
readers that take members in any order, the type member of a polymorphic value included (checked
in avaje-jsonb's generator source). It matters, because PhotonVision's own order isn't stable: some
of its maps are keyed by enums, whose order changes from run to run.

In Java (`com.michaelgrundvig.frc.paddock.settings`): `Settings` and `SettingsRow` are the
rows; `SettingsFiles` reads and writes the folder (`read`, `write`, and `render`/`parse` for the
files as text); `SettingsDatabase` reads and writes the database through JDBC's own API, so the
shared code needs no driver (PhotonVision's pack helper brings xerial's sqlite-jdbc, and the tests
use it too). It reads
every table, with its primary key as the key and every other column as JSON, so a column a new
PhotonVision adds comes along unasked. Writing replaces every row in one transaction, and refuses a
database at another schema version, or without a table or column the settings name.
`SettingsText` is the rows as the database's text, parsed a row at a time: a calibration is about a
megabyte of JSON, many times that parsed, and the helper has 64 MB.

Two things don't round-trip, and PhotonVision's schema has neither: an SQL NULL reads as JSON
`null` and is written back as the text `null` (PhotonVision's columns are NOT NULL), and a column
named like kept text (`x.text`) would be ambiguous, so its table is left out.

**The backup** (the pack's `settings.zip` download, `/v1/downloads/settings.zip`) holds
`settings/<computer>/` and, written last beside it, `settings/<computer>.sha256`: each file's
SHA-256 as `sha256sum` writes them. A zip that was cut short is missing it, or fails `sha256sum -c
settings/<computer>.sha256` run from the repository's root.

**The tests' database** is made from PhotonVision's schema (its `DatabaseSchema` migrations,
transcribed in `core/src/testFixtures/resources/photonvision/`, the one file here adapted from
PhotonVision, under its license: `THIRD-PARTY.md`) with example rows written from its
configuration classes' fields. The container tests run the real PhotonVision (the pinned x86 jar,
`harness/src/test/resources/harness/photonvision-x86.json`) and hash the database it writes, both
on the coprocessor and, from its downloads, as the robot would.

### The settings hash

`SettingsHash.of(settings)` (or `settings.hash()`) is the SHA-256, in lowercase hex, of
`Json.hashable` of `{"tables": {<table>: {<key>: <columns>}}, "userVersion": <n>}`, after the rules
below. So rewriting doesn't change it (members reordered, `70.0` written `70`), files and the
database give the same hash, and a changed setting changes it. The robot's build hashes each
computer's committed settings into the program; PhotonVision's pack hashes the live database on each coprocessor; empty means
none are committed.

Some values PhotonVision changes by itself, as it runs. The hash leaves them out, or reads them in
a fixed order (`SettingsHash.RULES`, each with its reason; `SettingsHashTest` pins the list):

| Table, column | Value | Rule | Why |
|---|---|---|---|
| `cameras`, `config_json` | `currentPipelineIndex` | left out | The robot program switches pipelines and driver mode, and PhotonVision saves the choice |
| `cameras`, `config_json` | `streamIndex` | left out | PhotonVision assigns each camera's stream ports as it starts |
| `cameras`, `config_json` | `matchedCameraInfo.dev` | left out, for a USB camera matched by its port | The `/dev/videoN` number the kernel gave the camera this boot |
| `cameras`, `config_json` | `matchedCameraInfo.path` | left out, for a USB camera matched by its port | The `/dev/videoN` device; PhotonVision matches such a camera by the by-path entry in `otherPaths` |
| `cameras`, `config_json` | `matchedCameraInfo.otherPaths` | any order | The camera's other paths, in an order PhotonVision notes can change; which ones (the USB port) still counts |

"A USB camera matched by its port" is one whose `type` is `PVUsbCameraInfo` with a by-path entry
in its `otherPaths`. For any other (a CSI camera, a file, a USB camera without one), the path is
what identifies the camera, so it counts.

**Identical cameras swapped between ports are invisible**, to PhotonVision and to the hash alike:
two cameras of the same model without serial numbers look the same, and PhotonVision follows the
port, so each port's calibration now applies to the other camera. Label cameras and their ports.

**Partly verified:** the list comes from reading PhotonVision's source. The container tests show
the hash steady across PhotonVision's restarts, with no cameras; a bench test on a real board
confirms the rest: steady across reboots, replugs, and pipeline switches. Changing the
list changes every hash, so every image needs stamping again.


## Paddock's build tool

`com.michaelgrundvig.frc.paddock.tools.PaddockBuild`, for a robot's build: `check-lock` (the lock,
and its version against PhotonLib's vendordep), `table` (Spotter's compiled table, checked by
Paddock's rules for PhotonVision's images: a known board, camera names PhotonVision can publish, no
port PhotonVision uses; and the label every image must carry, its PhotonVision version), and
`settings-hashes` (each computer's committed settings hash, for the robot's requirements).
