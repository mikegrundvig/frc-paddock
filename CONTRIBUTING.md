# Contributing

Paddock does what teams have needed so far, and it's meant to grow. If your images need something
it doesn't do yet (another OS, another kind of step, Wi-Fi), the best start is an
[issue](https://github.com/mikegrundvig/frc-paddock/issues) describing your setup. We're happy to
work it out with you, and pull requests are welcome.

Under the hood, Paddock is bash (`engine/`), a reusable GitHub workflow
(`.github/workflows/build-images.yml`), and tests. Gradle runs the tests; nothing a team uses needs
Gradle or Java.

| Path | What |
|---|---|
| `engine/plan.sh` | Checks `paddock.yaml` (`lib/common.sh`'s `check_config`) and writes the plan the later jobs follow |
| `engine/fetch.sh` | Downloads an image's base, packages, and downloads, each checked |
| `engine/build-image.sh` | Builds an image: unpacks and grows the base, runs `run-steps.sh` and `finish-root.sh` in a chroot, then `layout.sh` |
| `engine/stamp-image.sh`, `stamp.sh` | Stamps a computer's copy |
| `engine/manifest.sh`, `release.sh` | Writes `SHA256SUMS` and `manifest.json`, and publishes the release |
| `engine/local-build.sh` | All of it on one Linux machine |
| `engine/os/` | The OS adapters ([its README](engine/os/README.md)) |
| `engine/test/` | The unit tests |
| `harness/` | The integration tests (Testcontainers) |
| `examples/` | Complete inputs, built end to end by CI |

## Tests

| Layer | What | Where it runs |
|---|---|---|
| Unit | Each engine script on folders and image files, with stand-ins for the network and GitHub | `engine/test/run.sh`, anywhere with bash |
| Integration | A read-only image built by the engine in a real Debian, booted under systemd; a drive's image built by `local-build.sh` with loop devices | `harness/`, with Docker or Podman. The drive needs a rootful runtime, so it runs in CI only |
| Examples | Each example built end to end by the workflow, one released and checked | CI, on `main` and version tags |
| Hardware | What only a board shows | [The hardware checklist](docs/hardware-checklist.md), by hand |

```
./gradlew ci                         # shellcheck, the unit tests, the integration tests
bash engine/test/run.sh              # the unit tests alone
bash engine/test/run.sh layout       # the tests whose names contain "layout"
```

The unit tests need bash, mikefarah's yq version 4, sha256sum, and dpkg-deb, and the layout tests
also need sfdisk and e2fsprogs. A test that's missing a tool skips and says which; in CI on Linux, a
skip counts as a failure. The integration tests need Docker or Podman and skip without one, except
in CI. Gradle downloads the JDK it needs.

A flaky test is a bug: fix the cause before anything else.

## Conventions

- Every script starts with `set -euo pipefail`, sources `lib/common.sh`, and says what it does and
  how to call it in its header comment (`--help` prints it). Errors read
  `die "what's wrong: what to do"`.
- Checks report every problem at once instead of stopping at the first.
- `engine/` doesn't know about any particular distribution, application, or team. That belongs in
  an adapter, or in a team's steps.
- Anything downloaded is pinned and checked: tools by version and SHA-256, actions by commit.
- shellcheck passes with no exceptions beyond `.shellcheckrc`; Java is google-java-format
  (`./gradlew spotlessApply`).

## An OS adapter

A new value for an axis (`os.network: networkd`, say) is one file, `engine/os/network/networkd.sh`,
that defines the axis's functions ([engine/os/README.md](engine/os/README.md)), plus its tests in
`engine/test/adapters_test.sh`. The input check accepts any value that has a file, so nothing else
needs to change.

## Releasing Paddock

1. `./gradlew ci` passes, and CI on `main` (the examples, and the release rehearsal) is green.
2. The hardware checklist passes on the examples' boards.
3. Tag `vMAJOR.MINOR.PATCH` on `main` (with `-beta.N` while in beta) and push it. Teams pin it in
   their workflow's `@`.
