# A Raspberry Pi

Raspberry Pi OS Lite that you can SSH into with your own keys, plus a package and a file to show
how those steps look. It's the smallest useful setup, and the one
[Getting started](../../docs/getting-started.md) builds.

## What you get

- Raspberry Pi OS Lite at its stamped address.
- **Log in as `pi` with your SSH keys** (`keys/authorized_keys`). Passwords don't work, and `pi`
  can `sudo` without one, so anyone with one of your keys has root.
- Each computer makes its own SSH host keys the first time it starts.
- [fd](https://github.com/sharkdp/fd), installed from its GitHub release, and a login message
  (`files/motd`).

Two things that are different from a Raspberry Pi OS card you'd set up by hand:

- There's no setup wizard on first boot: `setup/login.sh` turns it off, since the user and keys come
  from your repository.
- The root doesn't grow to fill the card. It's the base's size plus `grow:` (512M here), so raise
  `grow:` if you need more room ([why](../../docs/reference.md#stamping)).

## Make it yours

1. Your addresses in `paddock.yaml`: `10.TE.AM.x/24`, gateway `10.TE.AM.4`.
2. Your SSH public keys in `keys/authorized_keys`, one per line: each person's own, never a private
   key ([Control who can log in](../../docs/how-to.md#control-who-can-log-in)).
3. Your own steps in place of fd and the motd.

## What's here

| Path | What |
|---|---|
| `paddock.yaml` | The image and its computer |
| `setup/login.sh` | Keeps `pi`, gives it your keys, turns on SSH (key only), and turns off the setup wizard. Each part says why |
| `keys/authorized_keys` | Your SSH public keys |
| `files/motd` | Shown when you log in |
| `NOTICE.md` | What's in the image, and where its source is |

## On the board

On top of [the hardware checklist](../../docs/hardware-checklist.md):

1. `ssh pi@ADDRESS` gets you in with your key, and `sudo true` works.
2. The board's screen shows a login prompt, not the setup wizard.
