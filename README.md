# HetrixTools monitoring agent for SmartOS

The `smartos` branch uses the HetrixTools v2 metrics endpoint and payload
format from [upstream 2.4.2](https://github.com/hetrixtools/agent/tree/2.4.2).

The agent uses illumos commands for CPU, memory, swap, networking, TCP
connections and SMF service status. It reports ZFS usage and pool throughput,
with optional ZFS pool health and SMART data from `diskinfo` and `smartctl`.
It can read custom variables from `custom_variables.json` alongside the
configuration. The upload verifies the HTTPS certificate.

## Install or update

Run the scripts as root on a SmartOS host, from a checkout of the `smartos`
branch. Use Bash 4 or newer and install `wget` with a working CA bundle.

- Install with `bash hetrixtools_install.sh SID 1` for root cron or
  `bash hetrixtools_install.sh SID 0` for the dedicated `hetrixtools` account.
  Replace `SID` with the Server ID from HetrixTools.
- Update with `bash hetrixtools_update.sh`. The updater preserves an existing
  `hetrixtools.cfg` or migrates assignments from the old agent, and keeps
  the existing cron schedule.
- Customise `/etc/hetrixtools/hetrixtools.cfg` using one `key=value` per line.
  Supported settings include `NetworkInterfaces`, `CheckServices` (SMF
  FMRIs or process names), `ConnectionPorts` (blank for auto-discovery),
  `CollectEveryXSeconds`, `CheckSoftRAID` (ZFS health), `CheckDriveHealth`,
  `RunningProcesses`, and `CustomVars` (a local JSON file name).

Linux package-manager reboot checks, mdadm/LVM, and systemd support do not
apply to SmartOS. Outgoing ping probes, temperature, and controller-specific
MegaRAID or HP Smart Array discovery have not been ported. Pool throughput
and SMART availability depend on the host's tools and device permissions.

To remove the collector and its cron entry, use the uninstall script from
the same checkout. It keeps local configuration and custom variables.

## Test without a SmartOS host

Run `python3 tests/agent_payload.py` to check the serialized packet and
collector behavior with illumos command fixtures and a stub HTTP client.
