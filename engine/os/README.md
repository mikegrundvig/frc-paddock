# OS adapters

Everything Paddock knows about the OS it builds on is here, one file per value of each axis. An
image's `os:` picks one adapter per axis; the defaults are the only ones so far.

| Axis | Adapter | Defines |
|---|---|---|
| `packages` | `packages/apt.sh` | `packages_check_base ROOT`, `packages_prepare ROOT`, `packages_install ROOT OFFLINE FILE...`, `packages_finish ROOT` |
| `init` | `init/systemd.sh` | `init_check_base ROOT`, `init_stamped_paths`, `init_ram_paths`, `init_clear_machine_id ROOT`, `init_write_machine_id ROOT ID` |
| `network` | `network/networkmanager.sh` | `network_check_base ROOT`, `network_check_result ROOT`, `network_stamped_paths`, `network_ram_paths`, `network_write ROOT HOSTNAME ADDRESS PREFIX GATEWAY DNS SEED` |
| `filesystem` | `filesystem/ext4.sh` | `fs_check_base DEVICE`, `fs_grow DEVICE`, `fs_trim MOUNT`, `fs_check DEVICE`, `fs_type`, `fs_data_options`, `fs_make IMAGE OFFSET SIZE_KIB LABEL [DIR]` |

- **ROOT** is the image's root: `/` in its chroot (the steps, finishing), the mounted root from
  outside (stamping), or a folder in the tests.
- **Checks** (`*_check_*`) print each problem on a line of its own, print nothing when all's well,
  and always return 0: the caller collects every adapter's problems and names them all at once.
- **`packages_prepare` and `packages_finish`** bracket the steps: whatever the build must hold off
  while they run (services starting), and whatever it leaves behind that isn't the image's
  (download state). `packages_finish` runs even when a step fails.
- **`*_stamped_paths`** are the files stamping writes per computer; **`*_ram_paths`**, what the
  adapter's program writes while the computer runs, in RAM on a read-only root. The input check
  keeps steps and kept paths off both.
- **Filesystem functions** run on the build machine, never in the chroot. **`network_write`** and
  **`init_write_machine_id`** write from outside the image, so they write through `put_in`, which
  follows no links.

A new adapter is one file defining its axis's functions, and its tests in
`engine/test/adapters_test.sh`. The input check accepts any value with a file here.
