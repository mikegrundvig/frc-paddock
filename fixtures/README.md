# Fixtures

`team/` is a team's repository as Paddock's image workflow reads it, for Paddock's own CI
(`.github/workflows/ci.yml`): its input, `paddock.yaml`, with one computer on an Orange Pi 5 and
PhotonVision's recipe; no committed settings; and an SSH key nobody holds. CI builds its image end
to end and keeps it as a workflow artifact; it publishes nothing.

Its image gets another project's software, as a team's would: Spotter's agent (a `.deb` from
Spotter's v0.3.0 release, by URL and SHA-256) and Spotter's PhotonVision pack (a file, copied from
Spotter's catalog at v0.3.0 into `team/packs/`). Paddock doesn't depend on Spotter: they're just
a package and a file, and the fixture proves a package from someone else's release installs.
Because CI runs the workflow from Paddock's own repository, the file's `path` is from Paddock's
root.
