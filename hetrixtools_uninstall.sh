#!/bin/bash
#
#
#	HetrixTools Server Monitoring Agent - Uninstall Script
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

set -e
PATH=/usr/bin:/usr/sbin:/opt/local/bin:/opt/local/sbin
export LC_ALL=C
umask 077
if [[ "$EUID" != 0 || "$(uname -s)" != SunOS ]]; then
	printf '%s\n' 'Run this script as root on SmartOS.' >&2
	exit 1
fi

agent=/etc/hetrixtools/hetrixtools_agent.sh
[[ -f "$agent" ]] || exit 0
cron_file=$(mktemp /var/tmp/hetrixtools-cron.XXXXXX)
trap 'rm -f "$cron_file"' EXIT
for account in root hetrixtools; do
	id -u "$account" >/dev/null 2>&1 || continue
	if existing=$(crontab -u "$account" -l 2>/dev/null) &&
		grep -q '/etc/hetrixtools/hetrixtools_agent\.sh' <<< "$existing"; then
		awk '!/\/etc\/hetrixtools\/hetrixtools_agent\.sh/' <<< "$existing" > "$cron_file"
		crontab -u "$account" "$cron_file"
	fi
done
rm -f "$agent"
printf '%s\n' 'Removed the agent and its cron entry. Configuration and custom variables were retained.'
