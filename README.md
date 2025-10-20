# FOLKs Router Deployment Helpers

This repository provides helper scripts to make deploying and verifying custom
OpenWrt/LEDE packages on a router less error-prone. The utilities wrap common
steps such as copying `.ipk` files to the router, installing them via `opkg`,
restarting init scripts, and running post-install diagnostics so you can focus
on your actual firmware changes instead of repeated manual work.

## Prerequisites

- A reachable router running OpenWrt/LEDE with SSH access enabled.
- A local machine with `ssh` and `scp` installed.
- The package you want to deploy already built as an `.ipk` file.

If you are deploying to a non-default SSH port or using a non-root account,
pass the appropriate options when running the scripts.

## Deploying a package

Use `scripts/install_router_package.sh` to copy an `.ipk` to the router and
install it with `opkg`:

```bash
./scripts/install_router_package.sh \
  --host 192.168.1.1 \
  --package build/folks.ipk \
  --service folksd
```

Key behaviour:

- Verifies that `ssh` and `scp` are available locally before starting.
- Confirms the router is reachable, that `opkg` is installed, and that `/tmp`
  is writable before any files are copied.
- Uploads the package to `/tmp/<package>.<timestamp>` on the router and installs
  it using `opkg install --force-reinstall`.
- Optionally enables and restarts an init script (pass `--service <name>`),
  validating that the init script exists before touching it.
- Removes the uploaded package by default (use `--keep-remote` to skip).
- Cleans up the uploaded package automatically even if the installation fails
  (unless `--keep-remote` is provided).
- Pass `--dry-run` to preview the commands without executing them.
- Export `FOLKS_SSH_OPTS` to add extra SSH options (for example,
  `FOLKS_SSH_OPTS="-o StrictHostKeyChecking=no"`).

Run `./scripts/install_router_package.sh --help` for the full list of options.

## Post-installation checks

After installing, run `scripts/router_post_install_check.sh` to verify the
package and service state:

```bash
./scripts/router_post_install_check.sh \
  --host 192.168.1.1 \
  --package folksd \
  --service folksd \
  --log-path /var/log/messages
```

This script performs the following diagnostics:

- Confirms SSH connectivity and prints the router's overlay filesystem usage.
- Ensures the specified package appears in `opkg list-installed`.
- Optionally checks whether an init script is enabled and running, failing fast
  when it is missing, disabled, or stopped.
- Tails the last 50 lines of a log file to help spot runtime errors.
- Validates that the requested log file exists before attempting to tail it.
- Supports a `--dry-run` flag similar to the installer.
- Respects the same `FOLKS_SSH_OPTS` environment variable for additional SSH
  flags.

## Troubleshooting tips

- **Authentication failures:** verify you can `ssh` to the router manually and
  confirm the username/port arguments you pass to the scripts.
- **`opkg` errors:** make sure there is enough free space on the router and that
  the package architecture matches the device.
- **Service restart fails:** log into the router and inspect the init script at
  `/etc/init.d/<service>`; check `/var/log/messages` for detailed errors.
- **Need to keep the uploaded package:** rerun the installer with
  `--keep-remote` so you can inspect it on the router.

## License

MIT
