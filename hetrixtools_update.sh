#!/bin/bash
#
#
#	HetrixTools Server Monitoring Agent - Update Script
#	version 1.5.8
#	Copyright 2015 - 2019 @  HetrixTools
#	For support, please open a ticket on our website https://hetrixtools.com
#
#
#		DISCLAIMER OF WARRANTY
#
#	The Software is provided "AS IS" and "WITH ALL FAULTS," without warranty of any kind, 
#	including without limitation the warranties of merchantability, fitness for a particular purpose and non-infringement. 
#	HetrixTools makes no warranty that the Software is free of defects or is suitable for any particular purpose. 
#	In no event shall HetrixTools be responsible for loss or damages arising from the installation or use of the Software, 
#	including but not limited to any indirect, punitive, special, incidental or consequential damages of any character including, 
#	without limitation, damages for loss of goodwill, work stoppage, computer failure or malfunction, or any and all other commercial damages or losses. 
#	The entire risk as to the quality and performance of the Software is borne by you, the user.
#
#

# Set PATH
# Install or update from a local checkout of the SmartOS fork.
set -e
PATH=/usr/bin:/usr/sbin:/opt/local/bin:/opt/local/sbin:/opt/tools/bin:/opt/tools/sbin
export LC_ALL=C
umask 077
if [[ "$EUID" != 0 || "$(uname -s)" != SunOS ]]; then
	printf '%s\n' 'Run this script as root on SmartOS.' >&2
	exit 1
fi
for tool in bash wget vmstat dladm dlstat ipadm zfs zpool; do
	command -v "$tool" >/dev/null || { printf 'Missing command: %s\n' "$tool" >&2; exit 1; }
done

source_dir=$(cd -P -- "$(dirname -- "$0")" && pwd)
agent_dir=/etc/hetrixtools
agent=$agent_dir/hetrixtools_agent.sh
config=$agent_dir/hetrixtools.cfg
state=$agent_dir/state
run_user=root
install=0
if [[ "$1" == --install ]]; then
	install=1
	shift
	if [[ ! "$1" =~ ^[[:xdigit:]]{32}$ || ! "$2" =~ ^[01]$ || ( -n "$3" && ! "$3" =~ ^[[:alnum:]_/.,:-]+$ ) ||
		! "${4:-0}${5:-0}${6:-0}" =~ ^[01]{3}$ ]]; then
		printf '%s\n' 'Usage: bash hetrixtools_install.sh SID 0|1 [services] [check_zfs] [drive_health] [processes]' >&2
		exit 1
	fi
	if [[ "$2" == 0 ]]; then
		run_user=hetrixtools
		id -u "$run_user" >/dev/null 2>&1 || useradd -d "$agent_dir" -s /bin/false "$run_user"
	fi
else
	[[ -f "$agent" ]] || { printf '%s\n' 'No existing SmartOS agent found.' >&2; exit 1; }
	if id -u hetrixtools >/dev/null 2>&1 &&
		crontab -u hetrixtools -l 2>/dev/null | grep -q '/etc/hetrixtools/hetrixtools_agent.sh'; then
		run_user=hetrixtools
	fi
fi

bash -n "$source_dir/hetrixtools_agent.sh"
# The agent code and configuration remain root-owned even for unprivileged cron.
# Give the selected account a private directory for transient payloads and snapshots.
mkdir -p "$agent_dir"
[[ ! -L "$agent_dir" && ! -L "$state" ]] || exit 1
chown root "$agent_dir"
chmod 755 "$agent_dir"
mkdir -p "$state"
chown "$run_user" "$state"
chmod 700 "$state"

stage=$(mktemp -d "$agent_dir/.update.XXXXXX")
trap 'rm -rf "$stage"' EXIT
if (( install )); then
	{
		printf 'SID=%s\n' "$1"
		if [[ "$3" != 0 ]]; then printf 'CheckServices=%s\n' "$3"; fi
		printf 'CheckSoftRAID=%s\nCheckDriveHealth=%s\nRunningProcesses=%s\n' "${4:-0}" "${5:-0}" "${6:-0}"
	} > "$stage/config"
elif [[ -f "$config" ]]; then
	cp "$config" "$stage/config"
else
	# Copy only literal, known assignments from the previous agent.
	awk '/^(SID|NetworkInterfaces|CheckServices|CheckSoftRAID|CheckDriveHealth|RunningProcesses|ConnectionPorts|CollectEveryXSeconds|CustomVars)=/{print}' "$agent" > "$stage/config"
fi
if ! awk -F= '$1 == "SID" {sid=$2; gsub(/^"|"$/, "", sid)} END {exit !(length(sid) == 32 && sid ~ /^[[:xdigit:]]+$/)}' "$stage/config"; then
	printf '%s\n' 'The existing configuration has no valid SID.' >&2
	exit 1
fi
chgrp "$(id -gn "$run_user")" "$stage/config"
chmod 640 "$stage/config"
cp "$source_dir/hetrixtools_agent.sh" "$stage/agent"
chmod 755 "$stage/agent"
mv -f "$stage/config" "$config"
mv -f "$stage/agent" "$agent"

if (( install )); then
	for account in root hetrixtools; do
		id -u "$account" >/dev/null 2>&1 || continue
		{ crontab -u "$account" -l 2>/dev/null || :; } |
			awk '!/\/etc\/hetrixtools\/hetrixtools_agent\.sh/' > "$stage/cron"
		if [[ "$account" == "$run_user" ]]; then
			printf '* * * * * %s %s\n' "$(command -v bash)" "$agent" >> "$stage/cron"
		fi
		crontab -u "$account" "$stage/cron"
	done
fi
printf '%s\n' "HetrixTools agent ready for $run_user's cron job."
