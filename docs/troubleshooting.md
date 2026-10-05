# Troubleshooting

When a job fails, the reason is at the top of the run's summary, along with the last lines of its
log. The messages below are quoted the way they start.

## Check the input

**"paddock.yaml has N problems"** lists each one: a key Paddock doesn't know, a value in the wrong
shape, a file that isn't there. Fix them all and run it again. Names are case-sensitive, and paths
are relative to `paddock.yaml`'s folder.

**"... has Windows line endings (CRLF)"**: the script was saved on Windows. Save it with LF line
endings (most editors show which in the status bar), or add a `.gitattributes` with
`*.sh text eol=lf`.

## Image NAME

**"... isn't the one paddock.yaml gives: its SHA-256 is X, not Y"**: the file at that URL isn't the
one you pinned. Either the `sha256` is mistyped or out of date (the URL changed but the digest
didn't), or the file behind the URL changed. Check the SHA-256 on the file's release page and update
it.

**"... couldn't be downloaded"**: the URL is wrong, or the file isn't public. Paddock downloads
without logging in, so everything has to be public.

**"NAME's base isn't one its adapters (os:) can build on"**: the base is missing something Paddock
relies on (apt, dpkg, systemd), listed under the message. Paddock doesn't support that base yet:
[open an issue](https://github.com/mikegrundvig/frc-paddock/issues) if you need it.

**"NAME's base is amd64, but from.arch says arm64"** (or the other way round): set `from.arch` to
match the base.

**"NAME's base: its last partition is its root, but ..."**: Paddock grows the last partition as the
root, and this base's last partition isn't an ext4 root, so it isn't a base Paddock supports yet.

**"step N: ... failed"**: one of your scripts failed, and its own output is just above. A script
that works on a running computer can still fail here, because nothing is running during the build:
no services, and `/proc` and `/sys` belong to the build machine. Use `systemctl enable`, not
`start`.

**"step N: TO is a folder in the image"**: `to:` needs the file's full path, like
`/etc/tool/tool.yaml`, not `/etc/tool`.

**"... isn't installed at its version"** or **"... is for amd64, but this image is arm64"**: a
problem with the package itself: the wrong architecture, or dependencies the base's sources can't
satisfy (apt's output above says which).

**"NAME's steps leave the network to more than its network adapter"**: something besides
NetworkManager configures Ethernet and would fight the stamped address. The message names each one
(systemd-networkd, a netplan file, ifupdown) and how to turn it off in a step.

**"NAME keeps PATH, but the base mounts POINT there"**: a kept path is on another of the base's
partitions, like the boot partition. Only keep paths on the root.

**"... the root is its fourth partition: an MBR table has no room for a data partition"**: the
base already has four partitions, so a read-only root can't add one. Drop `read-only:` for this
base.

**No space left on device**: your steps need more room than `grow:` gives them. Make it bigger.

**A warning, "fstab mounts ... which is none of its partitions"**: the base's `/etc/fstab` names a
partition the image doesn't have, so steps that write under that path write into the root instead.

## Release

**"release NAME already exists, and a release is never replaced"**: use a new name. If you really
want to replace it, delete the release and its tag on GitHub first.

**"a draft release NAME is left from a run that stopped"**: an earlier run stopped partway through
uploading. Delete the draft on the Releases page and run it again.

**"tag NAME points at ..., but these images were built from ..."**: a tag with that name already
marks a different commit. Use a new name.

**"tag X started this run, but the release is named Y"**: your workflow's `release:` input doesn't
match the tag. Use `${{ github.ref_type == 'tag' && github.ref_name || inputs.release }}`, as in
[Getting started](getting-started.md).

**"Resource not accessible by integration"**: the job calling Paddock needs
`permissions: contents: write`.

**A job waits for a runner forever**: arm64 images need GitHub's ARM runners
(`ubuntu-24.04-arm`). Public repositories get them free and private ones pay for them, but an
organization can turn Actions or larger runners off in its settings.

## On the computer

**It isn't at its address.** Make sure your laptop is on the same network with an address in the
same subnet. Two drives flashed from the same image share an address: the second one notices and
stays off it. The base's own network setup can still win if a step didn't turn it off; Paddock's
build catches the common ones, but not, say, a vendor's own network service.

**SSH refuses the connection.** Check SSH is turned on in the image, and that it has host keys:
many bases make them on systemd's "first boot", which a Paddock image never has
([the reference](reference.md#stamping) explains). The
[raspberry-pi example's](../examples/raspberry-pi/setup/login.sh) login step handles both.

**SSH refuses your key.** The key has to be in the image, for the user you log in as, so a new key
means a new release and a reflash ([Control who can log in](how-to.md#control-who-can-log-in)). If
SSH warns that the host key changed after a reflash, that's the new drive's own key: remove the old
one with `ssh-keygen -R ADDRESS`.

**The root didn't grow to fill the drive.** Bases that grow their root on systemd's first boot don't
on a Paddock image ([the reference](reference.md#stamping) explains). The root is the base's size
plus `grow:`, so make `grow:` as big as you need.

**Something fails on a read-only root.** Find what's trying to write with
`journalctl -b -p warning`, then keep its path, put it in RAM (`ram:`), or turn it off in a step,
and release again.
