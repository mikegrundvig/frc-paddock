# Third-party software and licenses

Paddock's own code is under the MIT license (`LICENSE`). One file in this repository is someone
else's: `gradle/wrapper/gradle-wrapper.jar`, with `gradlew` and `gradlew.bat`, are Gradle's
wrapper, under the Apache License 2.0.

**Building and testing Paddock** downloads, and doesn't redistribute: Gradle and its plugins, JUnit,
AssertJ, and Testcontainers (`gradle/libs.versions.toml`); and in CI, mikefarah's yq (MIT) and
ShellCheck (GPL-3.0), each pinned by SHA-256. The workflow teams call downloads the same yq.

**What Paddock builds isn't Paddock's.** An image is the team's base and the team's steps: a Linux
distribution, mostly under the GNU General Public License, and whatever the team adds, each under
its own license. Paddock downloads them, checks them against the SHA-256s in `paddock.yaml`, and
puts them together. A team that publishes its images, or passes them on, should say what's in them
and where its source is, as those licenses require: a `NOTICE.md` beside `paddock.yaml` goes into
every release, and each release's `manifest.json` names every base, package, and download by URL
and SHA-256.

`examples/` holds inputs for teams to start from; each names its bases and packages, with their
licenses, in its own `NOTICE.md`.
