#!/bin/bash
#
#
#	HetrixTools Server Monitoring Agent
#	SmartOS port, wire protocol 2.4.2
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

# HetrixTools Server Monitoring Agent for SmartOS, protocol version 2.4.2.
PATH=/usr/bin:/usr/sbin:/smartdc/bin:/opt/smartdc/bin:/opt/local/bin:/opt/local/sbin:/opt/tools/bin:/opt/tools/sbin:/opt/smartdc/agents/bin
export LC_ALL=C
umask 077
ScriptPath=$(cd -P -- "$(dirname -- "$0")" && pwd) || exit 1
StatePath="$ScriptPath/state"
VERSION=2.4.2
SID=""
NetworkInterfaces=""
CheckServices=""
CheckSoftRAID=0
CheckDriveHealth=0
RunningProcesses=0
ConnectionPorts=""
CollectEveryXSeconds=3
CustomVars=custom_variables.json

# Accept data assignments only, including quoted values migrated from 1.5.8.
while IFS='=' read -r key value || [[ -n "$key" ]]; do
	case "$value" in \"*\") value=${value#\"}; value=${value%\"} ;; esac
	case "$key" in
		SID) SID=$value ;;
		NetworkInterfaces) NetworkInterfaces=$value ;;
		CheckServices) CheckServices=$value ;;
		CheckSoftRAID) CheckSoftRAID=$value ;;
		CheckDriveHealth) CheckDriveHealth=$value ;;
		RunningProcesses) RunningProcesses=$value ;;
		ConnectionPorts) ConnectionPorts=$value ;;
		CollectEveryXSeconds) CollectEveryXSeconds=$value ;;
		CustomVars) CustomVars=$value ;;
	esac
done < "$ScriptPath/hetrixtools.cfg"

if [[ ! "$SID" =~ ^[[:xdigit:]]{32}$ ]]; then
	printf '%s\n' 'Configure a valid HetrixTools SID in hetrixtools.cfg.' >&2
	exit 1
fi
[[ "$CollectEveryXSeconds" =~ ^([2-9]|10)$ ]] || CollectEveryXSeconds=3

encode() {
	base64 | tr -d '[:space:]'
}

port_snapshot() {
	# illumos uses a dot before the local port in both address families.
	netstat -an -P tcp 2>/dev/null | awk '
		$NF == "LISTEN" || $NF == "ESTABLISHED" {
			host = port = $1
			sub(/\.[^.]*$/, "", host)
			sub(/^.*\./, "", port)
			if (port !~ /^[0-9]+$/) next
			if ($NF == "ESTABLISHED") connections[port]++
			else if (host !~ /^(127\.|::1$|::ffff:127\.)/) listeners[port] = 1
		}
		END {
			for (port in listeners) print "listen", port, 0
			for (port in connections) print "established", port, connections[port]
		}'
}

service_online() {
	local state
	if state=$(svcs -H -o state "$1" 2>/dev/null) && [[ -n "$state" ]]; then
		grep -qx online <<< "$state"
	elif [[ "$1" != svc:* ]]; then
		pgrep -x "$1" >/dev/null 2>&1
	else
		return 1
	fi
}

wire_name() {
	printf '%s' "$1" | tr -d ',;'
}

drive_health() {
	local disk report model serial type
	local -A seen_serials=()
	command -v smartctl >/dev/null 2>&1 || return 0
	while read -r disk; do
		[[ "$disk" =~ ^[[:alnum:]_.-]+$ ]] || continue
		# A failing disk can produce a nonzero exit status with useful output.
		report=$(smartctl -i -H -A "/dev/rdsk/$disk" 2>/dev/null)
		case "$report" in
			*"SMART/Health Information (NVMe Log"*) type=2 ;;
			*"Transport protocol:"*"SAS"*) type=3 ;;
			*"SMART Attributes Data Structure"*) type=1 ;;
			*) continue ;;
		esac
		model=$(awk -F ': *' '/^(Device Model|Model Number|Product):/ {print $2; exit}' <<< "$report")
		serial=$(awk -F ': *' '/^[Ss]erial [Nn]umber:/ {print $2; exit}' <<< "$report")
		if [[ -n "$serial" ]]; then
			[[ -z "${seen_serials[$serial]}" ]] || continue
			seen_serials[$serial]=1
		fi
		printf '%s,%s,%s,%s,%s;' "$type" "$disk" "$(printf '%s' "$report" | encode)" "$(wire_name "$model")" "$(wire_name "$serial")"
	done < <(diskinfo -cH 2>/dev/null | awk '$1 !~ /\?\?R/ {print $2}')
}

if [[ -n "$NetworkInterfaces" ]]; then
	IFS=, read -r -a interfaces <<< "$NetworkInterfaces"
else
	readarray -t interfaces < <(dladm show-link -p -o LINK,STATE 2>/dev/null | awk -F: '$2 == "up" {print $1}')
fi
declare -A rx_start tx_start
for nic in "${interfaces[@]}"; do
	[[ "$nic" =~ ^[[:alnum:]_.-]+$ ]] || continue
	rx_start[$nic]=$(dlstat -rpo rbytes "$nic" 2>/dev/null)
	tx_start[$nic]=$(dlstat -tpo obytes "$nic" 2>/dev/null)
done

if [[ -n "$ConnectionPorts" ]]; then
	IFS=, read -r -a ports <<< "$ConnectionPorts"
else
	readarray -t ports < <(port_snapshot | awk '$1 == "listen" {print $2}' | sort -n | head -30)
fi
declare -A port_totals port_seen
valid_ports=()
for port in "${ports[@]}"; do
	[[ "$port" =~ ^[0-9]{1,5}$ ]] || continue
	port=$((10#$port))
	[[ "$port" -ge 1 && "$port" -le 65535 && -z "${port_seen[$port]}" ]] || continue
	port_seen[$port]=1
	valid_ports+=("$port")
	(( ${#valid_ports[@]} < 30 )) || break
done
readarray -t services < <(printf '%s\n' "$CheckServices" | tr ',' '\n' | awk '/^[[:alnum:]][[:alnum:]_.\/:-]*$/ && !seen[$0]++ && ++n <= 10')
declare -A services_up
ram_size=$(prtconf 2>/dev/null | awk '/Memory size:/ {printf "%.0f", $3 * 1024; exit}')
start=$(date +%s)
samples=$(( (48 - start % 60) / CollectEveryXSeconds ))
(( samples > 0 )) || samples=1

# The first zpool iostat report is since boot, so use the interval report.
pool_names=$(zpool list -H -o name 2>/dev/null)
if [[ -n "$pool_names" ]]; then
	pool_interval=$((samples * CollectEveryXSeconds))
	exec 3< <(zpool iostat -Hpy "$pool_interval" 1 2>/dev/null |
		awk 'NF == 7 && $6 ~ /^[0-9]+$/ && $7 ~ /^[0-9]+$/ {print $1, $6, $7}')
fi

sample_count=0
cpu_user=0 cpu_system=0 free_ram=0
while read -r cpu_u cpu_s free; do
	(( sample_count += 1, cpu_user += cpu_u, cpu_system += cpu_s, free_ram += free ))
	if (( ${#valid_ports[@]} )); then
		while read -r kind port count; do
			if [[ "$kind" == established && -n "${port_seen[$port]}" ]]; then
				(( port_totals[$port] += count ))
			fi
		done < <(port_snapshot)
	fi
	for service in "${services[@]}"; do
		if service_online "$service"; then services_up[$service]=1; fi
	done
# vmstat prints the since-boot report first, then us, sy and id at each interval.
done < <(vmstat "$CollectEveryXSeconds" "$((samples + 1))" | awk '
	NF >= 8 && $1 ~ /^[0-9]+$/ && $(NF-2) ~ /^[0-9]+$/ && $5 ~ /^[0-9]+$/ {
		if (seen++) {print $(NF-2), $(NF-1), $5; fflush()}
	}')
elapsed=$(( $(date +%s) - start ))

average() {
	awk -v n="$sample_count" -v value="$1" 'BEGIN {if (n > 0) printf "%.2f", value/n}'
}
cpu=$(average "$((cpu_user + cpu_system))")
cpu_us=$(average "$cpu_user")
cpu_sy=$(average "$cpu_system")
ram=$(awk -v n="$sample_count" -v size="$ram_size" -v free="$free_ram" '
	BEGIN {if (n > 0 && size > 0) {used = 100 * (1 - free/n/size); printf "%.2f", (used > 0 ? used : 0)}}')
read -r swap_size swap_used < <(swap -s 2>/dev/null | awk '
	/used,.*available/ {
		used = $9 + 0; available = $11 + 0; total = used + available
		printf "%.0f %.2f\n", total, (total > 0 ? 100 * used / total : 0)
	}')

nics="" ipv4="" ipv6=""
for nic in "${interfaces[@]}"; do
	[[ "$nic" =~ ^[[:alnum:]_.-]+$ ]] || continue
	rx=$(dlstat -rpo rbytes "$nic" 2>/dev/null)
	tx=$(dlstat -tpo obytes "$nic" 2>/dev/null)
	if (( elapsed > 0 )) && [[ "$rx" =~ ^[0-9]+$ && "$tx" =~ ^[0-9]+$ &&
		"${rx_start[$nic]}" =~ ^[0-9]+$ && "${tx_start[$nic]}" =~ ^[0-9]+$ ]]; then
		nics+=$(awk -v nic="$nic" -v rx="$rx" -v tx="$tx" -v rx0="${rx_start[$nic]}" -v tx0="${tx_start[$nic]}" -v t="$elapsed" '
			BEGIN {rx_rate = rx >= rx0 ? (rx-rx0)/t : 0; tx_rate = tx >= tx0 ? (tx-tx0)/t : 0; printf "%s,%.0f,%.0f;", nic, rx_rate, tx_rate}')
	fi
	addresses=$(ipadm show-addr -p -o ADDR "$nic/" 2>/dev/null)
	ips=$(awk -F/ '$1 ~ /^[0-9]+\./ {printf ",%s", $1}' <<< "$addresses")
	[[ -z "$ips" ]] || ipv4+="$nic$ips;"
	ips=$(awk -F/ '{gsub(/\\:/, ":", $1)} $1 ~ /:/ && tolower($1) !~ /^fe[89ab]/ {printf ",%s", $1}' <<< "$addresses")
	[[ -z "$ips" ]] || ipv6+="$nic$ips;"
done

conn="" serv=""
if (( sample_count > 0 )); then
	for port in "${valid_ports[@]}"; do
		conn+=$(awk -v port="$port" -v value="${port_totals[$port]:-0}" -v n="$sample_count" 'BEGIN {printf "%s,%.0f;", port, value/n}')
	done
fi
for service in "${services[@]}"; do
	serv+="$service,${services_up[$service]:-0};"
done

disks=$(zfs list -Hp -t filesystem -o name,used,available,mountpoint 2>/dev/null | awk -F '\t' '
	{mount = $4 ~ /^\// ? $4 : $1; gsub(/[,;]/, "", mount); printf "%s,zfs,%.0f,%s,%s;", mount, $2+$3, $2, $3}')
declare -A mounts
while IFS=$'\t' read -r name mount; do
	[[ -n "$name" ]] || continue
	[[ "$mount" == /* ]] || mount=$name
	mounts[$name]=$(wire_name "$mount")
done < <(zfs list -Hp -t filesystem -o name,mountpoint 2>/dev/null)
iops="" zp=""
if [[ -n "$pool_names" ]]; then
	while read -r -t 3 pool read_rate write_rate <&3; do
		iops+="${mounts[$pool]:-$pool},$read_rate,$write_rate;"
	done
	exec 3<&-
fi
if [[ "$CheckSoftRAID" == 1 && -n "$pool_names" ]]; then
	while read -r pool; do
		status=$(zpool status "$pool" 2>/dev/null) || continue
		zp+="${mounts[$pool]:-$pool},$pool,$(printf '%s' "$status" | encode);"
	done <<< "$pool_names"
fi
dh=""
[[ "$CheckDriveHealth" != 1 ]] || dh=$(drive_health)

custom=""
if [[ "$CustomVars" =~ ^[[:alnum:]_][[:alnum:]_.-]*\.json$ &&
	-f "$ScriptPath/$CustomVars" && ! -L "$ScriptPath/$CustomVars" ]]; then
	custom=$(encode < "$ScriptPath/$CustomVars")
fi
rps1="" rps2=""
if [[ "$RunningProcesses" == 1 ]]; then
	if [[ -f "$StatePath/running_proc.txt" && ! -L "$StatePath/running_proc.txt" ]]; then
		read -r rps1 < "$StatePath/running_proc.txt"
		[[ "$rps1" =~ ^[A-Za-z0-9+/=]*$ && "$rps1" != H4sI* ]] || rps1=""
	fi
	rps2=$(ps -e -o pid=,ppid=,uid=,user=,pcpu=,pmem=,time=,etime=,comm=,args= | encode)
	snapshot=$(mktemp "$StatePath/running_proc.XXXXXX") || exit 1
	printf '%s\n' "$rps2" > "$snapshot" && mv -f "$snapshot" "$StatePath/running_proc.txt"
fi

boot=$(kstat -pn system_misc -s boot_time 2>/dev/null | awk 'NR == 1 {print $2}')
uptime_seconds=""
[[ ! "$boot" =~ ^[0-9]+$ ]] || uptime_seconds=$((start - boot))
cpu_model=$(psrinfo -pv 2>/dev/null | awk 'NF {line=$0} END {sub(/^[[:space:]]+/, "", line); print line}')
cpu_speed=$(psrinfo -v 2>/dev/null | awk '/operates at .* MHz/ && !seen++ {for (i=2; i<=NF; i++) if ($i == "MHz") {printf "%.0f", $(i-1); break}}')
cpu_cores=$(psrinfo 2>/dev/null | awk 'END {print NR}')
cpu_sockets=$(psrinfo -p 2>/dev/null | awk '$1 ~ /^[0-9]+$/ {print $1; exit}')
read -r load1 load5 load15 < <(uptime | awk -F 'load averages?: ' '{gsub(/,/, "", $2); split($2, values, " "); for (i=1; i<=3; i++) if (values[i] !~ /^[0-9]+([.][0-9]+)?$/) exit; print $2}')

# Match the upstream v2 field names and encodings. A command that yields no
# supported measurement leaves its field empty.
wire=()
metric() {
	wire+=("\"$1\":\"$2\"")
}
text_metric() {
	metric "$1" "$(printf '%s' "$2" | encode)"
}
metric version "$VERSION"
metric SID "$SID"
metric agent 0
metric user "$(id -un | tr -cd '[:alnum:]_.-')"
text_metric os "SmartOS $(uname -v)"
text_metric kernel "$(uname -r)"
text_metric hostname "$(uname -n)"
text_metric time "$(date '+%Y-%m-%d %T %Z')"
metric uptime "$uptime_seconds"
text_metric cpumodel "$cpu_model"
metric cpusockets "$cpu_sockets"
metric cpucores "$cpu_cores"
metric cpuspeed "$cpu_speed"
metric cpu "$cpu"
metric us "$cpu_us"
metric sy "$cpu_sy"
metric load1 "$load1"
metric load5 "$load5"
metric load15 "$load15"
metric ramsize "$ram_size"
metric ram "$ram"
metric ramswapsize "$swap_size"
metric ramswap "$swap_used"
text_metric disks "$disks"
text_metric iops "$iops"
text_metric zp "$zp"
text_metric dh "$dh"
text_metric nics "$nics"
text_metric ipv4 "$ipv4"
text_metric ipv6 "$ipv6"
text_metric conn "$conn"
text_metric serv "$serv"
metric cust "$custom"
metric rps1 "$rps1"
metric rps2 "$rps2"
for field in reqreboot cputhreads wa st rambuff ramcache inodes raid temp oping; do
	metric "$field" ""
done

set -o pipefail
payload=$(IFS=,; printf '{%s}' "${wire[*]}" | gzip -c | encode) || exit 1
payload=${payload//+/%2B}
payload=${payload//\//%2F}
body=$(mktemp "$StatePath/payload.XXXXXX") || exit 1
trap 'rm -f "$body"' EXIT
printf 'j=%s\n' "$payload" > "$body" || exit 1
wget -t 1 -T 8 -qO- --post-file="$body" https://sm.hetrixtools.net/v2/ >/dev/null
