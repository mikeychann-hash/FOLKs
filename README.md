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
- Can measure latency and packet loss to a target host to validate gaming paths
  using `--ping-target`, optionally warning when `--latency-warn-ms` or
  `--loss-warn-percent` thresholds are exceeded.
- Supports a `--dry-run` flag similar to the installer.
- Respects the same `FOLKS_SSH_OPTS` environment variable for additional SSH
  flags.

### Latency and stability checks for gamers

If you rely on the router for latency-sensitive gaming, run additional checks
after deployment:

```bash
./scripts/router_post_install_check.sh \
  --host 192.168.1.1 \
  --package folksd \
  --service folksd \
  --log-path /var/log/messages \
  --ping-target xbox.com \
  --ping-count 20 \
  --latency-warn-ms 60 \
  --loss-warn-percent 1
```

This will collect packet loss and latency numbers directly from the router.
Pick a target that mirrors where you play most (for example, `xbox.com`, a
regional game server hostname, or your VPN/SmartDNS endpoint) and adjust the
thresholds to match your expectations. A few additional tips:

- For Xbox consoles and high-end gaming PCs, keeping the average latency under
  60 ms and packet loss below 1% generally maintains an "Open" NAT and smooth
  online play.
- For mobile gaming, consider a lower warning threshold (30–40 ms) to catch
  local Wi-Fi congestion early.
- Combine these checks with the existing `--service sqm` verification if you
  use Smart Queue Management to avoid bufferbloat under load.
- Re-run the command during peak hours after firmware or configuration changes
  to ensure latency remains stable for every device in your gaming setup.

## Gaming-friendly port forwarding presets

OpenWrt's firewall can expose console or server ports to the internet so your
friends can join without NAT issues. Automate those redirects with
`scripts/router_configure_port_forwarding.sh`:

```bash
./scripts/router_configure_port_forwarding.sh \
  --host 192.168.1.1 \
  --lan-ip 192.168.1.50 \
  --profile xbox \
  --profile minecraft-java \
  --profile minecraft-bedrock
```

The script checks that `uci` and the firewall service are available on the
router, then adds (or updates) `firewall` redirects targeting the provided LAN
IP before reloading the firewall. Pass `--dry-run` to preview the commands, or
`--lan-interface br-lan` if your LAN zone uses a custom name.

Available profiles and their forwarded ports:

| Profile            | Protocol | Ports                  | Description |
|--------------------|----------|------------------------|-------------|
| `xbox`             | TCP/UDP  | 53, 80, 88, 500, 3074, 3544, 4500 | Ensures an Open NAT for Xbox consoles. |
| `minecraft-java`   | TCP      | 25565                  | Default Java Edition server port. |
| `minecraft-bedrock`| UDP      | 19132, 19133           | Default Bedrock Edition server ports. |

Run the command again anytime you need to retarget the forwards to a different
IP—existing rules with the same profile names will be updated instead of
duplicated.

## Gaming-optimized Wi-Fi and DNS

If your router also hosts your wireless networks, keep the SSIDs and channels
tidy for latency-sensitive play. `scripts/router_configure_wifi_dns.sh` applies
gaming-friendly defaults over SSH:

```bash
./scripts/router_configure_wifi_dns.sh \
  --host 192.168.1.1
```

What the helper does:

- Renames the 2.4 GHz SSID to **FolksG** and pins it to channel **1**, the
  cleanest non-DFS option for most North American deployments. Channel 1 keeps
  your network away from overlapping channel 6/11 chatter common in apartment
  buildings.
- Renames the 5 GHz SSID to **FolksG-5G** and locks it to channel **36**, the
  lowest-latency UNII-1 channel that avoids DFS radar checks so your Xbox,
  gaming PC, and mobile devices stay connected without mid-match waits.
- Leaves radio detection automatic but lets you override device/iface sections
  if your `wireless` UCI layout is customized (use `--two-g-radio`,
  `--five-g-radio`, `--two-g-iface`, or `--five-g-iface`).
- Pushes Cloudflare's 1.1.1.1/1.0.0.1 "gamer" DNS resolvers into AdGuard Home
  so its filtering engine has a fast, privacy-friendly upstream. Pass
  `--dns-server <ip>` repeatedly to supply your own upstream list.
- Reloads Wi-Fi and restarts AdGuard Home (when installed) after committing the
  changes to keep downtime to a few seconds.

Add `--dry-run` to preview the SSH commands, or adjust the SSIDs/channels with
`--two-g-ssid`, `--five-g-ssid`, `--two-g-channel`, and `--five-g-channel` if you
want to diverge from the defaults described above.

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
