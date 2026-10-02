# Fixtures

`team/` is a team's repository as Paddock's image workflow reads it, for Paddock's own CI
(`.github/workflows/ci.yml`): one computer on an Orange Pi 5, with PhotonVision's recipe, no
committed settings, and an SSH key nobody holds. CI builds its image end to end and keeps it as a
workflow artifact; it publishes nothing.
