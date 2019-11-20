#!/bin/bash
#
#
#	HetrixTools Server Monitoring Agent
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

##############
## Settings ##
##############

# Set PATH
PATH=/usr/bin:/usr/sbin:/smartdc/bin:/opt/smartdc/bin:/opt/local/bin:/opt/local/sbin:/opt/tools/bin:/opt/tools/sbin:/opt/smartdc/agents/bin
ScriptPath=$(dirname "${BASH_SOURCE[0]}")

# Agent Version (do not change)
VERSION="1.5.8"

# SID (Server ID - automatically assigned on installation, do not change this)
# DO NOT share this ID with anyone
SID="SIDPLACEHOLDER"

# How frequently should the data be collected (do not modify this, unless instructed to do so)
CollectEveryXSeconds=3

# Runtime, in seconds (do not modify this, unless instructed to do so)
Runtime=60

# Network Interfaces
# * if you leave this setting empty our agent will detect and monitor all of your active network interfaces
# * if you wish to monitor just one interface, fill its name down below (ie: "eth1")
# * if you wish to monitor just some specific interfaces, fill their names below separated by comma (ie: "eth0,eth1,eth2")
NetworkInterfaces=""

# Check Services
# * separate service names by comma (,) with a maximum of 10 services to be monitored (ie: "ssh,mysql,apache2,nginx")
# * NOTE: this will only check if the service is running, not its functionality
CheckServices=""

# Check Software RAID Health
# * checks the status/health of any software RAID (mdadm) setup on the server
# * agent must be run as 'root' or privileged user to fetch the RAID status
# * 0 - OFF (default) | 1 - ON
CheckSoftRAID=0

# Check Drive Health
# * checks the health of any found drives on the system
# * requirements: 'S.M.A.R.T.' for HDD/SSD or 'nvme-cli' for NVMe
# * (these do not get installed by our agent, you must install them separately)
# * agent must be run as 'root' or privileged user to use this function
# * 0 - OFF (default) | 1 - ON
CheckDriveHealth=0

# View Running Processes
# * whether or not to record the server's running processes and display them in your HetrixTools dashboard
# * 0 - OFF (default) | 1 - ON
RunningProcesses=0

################################################
## CAUTION: Do not edit any of the code below ##
################################################

function servicestatus() {
	# Check first via ps
	if (( $(ps -ef | grep -v grep | grep $1 | wc -l) > 0 ))
	then
		# Up
		echo "$(echo -ne "$1" | base64),1"
	else
		# No systemctl, declare it down
		echo "$(echo -ne "$1" | base64),0"
	fi
}

# Function used to prepare base64 str for url encoding
function base64prep() {
	str=$1
	str="${str//+/%2B}"
	str="${str//\//%2F}"
	echo $str
}

# Kill any lingering agent processes (there shouldn't be any, the agent should finish its job within ~50 seconds, 
# so when a new cycle starts there shouldn't be any lingering agents around, but just in case, so they won't stack)
HTProcesses=$(ps -eo user=|sort|uniq -c | grep hetrixtools | awk -F " " '{print $1}')
if [ -z "$HTProcesses" ]
then
	HTProcesses=0
fi
if [ "$HTProcesses" -gt 300 ]
then
	ps aux | grep -ie hetrixtools_agent.sh | awk '{print $2}' | xargs kill -9
fi

# Calculate how many times per minute should the data be collected (based on the `CollectEveryXSeconds` setting)
RunTimes=$(($Runtime/$CollectEveryXSeconds))

# Get starting minute
M=$(echo `date +%M` | sed 's/^0*//')
if [ -z "$M" ]
then
	M=0
	# Clear the hetrixtools_cron.log every hour
	rm -f $ScriptPath/hetrixtools_cron.log
fi

# Network interfaces
if [ ! -z "$NetworkInterfaces" ]
then
	# Use the network interfaces specified in Settings
	IFS=',' read -r -a NetworkInterfacesArray <<< "$NetworkInterfaces"
else
	# Automatically detect the network interfaces
	NetworkInterfacesArray=($(ifconfig | grep BROADCAST | grep UP | awk '{print $1}' | awk -F ":" '{print $1}'))
fi
# Get the initial network usage
START=$(date +%s)
declare -A aRX
declare -A aTX
declare -A tRX
declare -A tTX
# Loop through network interfaces
for NIC in "${NetworkInterfacesArray[@]}"
do
	aRX[$NIC]=$(dlstat -rpo rbytes "$NIC")
	aTX[$NIC]=$(dlstat -tpo obytes "$NIC")
done

# Collect data loop
for X in $(seq $RunTimes)
do
	# Get vmstat info
	VMSTAT=$(vmstat $CollectEveryXSeconds 2 | tail -1)
	# Get CPU Load
	CPU=$(echo $[100-$( echo "$VMSTAT" | awk '{print $22}')])
	tCPU=$(echo | awk "{ print $tCPU + $CPU }")
	# Get IO Wait
	IOW=$(iostat -xn | grep zones | awk '{print $9}')
	tIOW=$(echo | awk "{ print $tIOW + $IOW }")
	# Get RAM Usage
	bRAM=$(prtconf | grep Memory | awk '{print $3 * 1024}')
	aRAM=$(($bRAM - $(echo "$VMSTAT" | awk '{print $5}')))
	RAM=$(echo | awk "{ print $aRAM*100/$bRAM }" | sed 's/,/./g')
	RAM=$(echo | awk "{ print 100 - $RAM }" | sed 's/,/./g')
	tRAM=$(echo | awk "{ print $tRAM + $RAM }" | sed 's/,/./g')
	# Get Network Usage
	END=$(date +%s)
	TIMEDIFF=$(echo | awk "{ print $END - $START }")
	START=$(date +%s)
		# Loop through network interfaces
	for NIC in "${NetworkInterfacesArray[@]}"
	do
		# Received Traffic
		RX=$(echo | awk "{ print $(dlstat -rpo rbytes "$NIC") - ${aRX[$NIC]} }")
		RX=$(echo | awk "{ print $RX / $TIMEDIFF }")
		RX=$(echo "$RX" | awk {'printf "%18.0f",$1'} | xargs)
		aRX[$NIC]=$(dlstat -rpo rbytes "$NIC")
		tRX[$NIC]=$(echo | awk "{ print ${tRX[$NIC]} + $RX }")
		tRX[$NIC]=$(echo "${tRX[$NIC]}" | awk {'printf "%18.0f",$1'} | xargs)
		# Transferred Traffic
		TX=$(echo | awk "{ print $(dlstat -tpo obytes "$NIC") - ${aTX[$NIC]} }")
		TX=$(echo | awk "{ print $TX / $TIMEDIFF }")
		TX=$(echo "$TX" | awk {'printf "%18.0f",$1'} | xargs)
		aTX[$NIC]=$(dlstat -tpo obytes "$NIC")
		tTX[$NIC]=$(echo | awk "{ print ${tTX[$NIC]} + $TX }")
		tTX[$NIC]=$(echo "${tTX[$NIC]}" | awk {'printf "%18.0f",$1'} | xargs)
	done
	# Check if minute changed, so we can end the loop
	MM=$(echo `date +%M` | sed 's/^0*//')
	if [ -z "$MM" ]
	then
		MM=0
	fi
	if [ "$MM" -gt "$M" ]
	then
		break
	fi
done

# Get Operating System and Kernel
OS="$(uname -s) $(uname -r) $(uname -v)"
OS=`echo -ne "$OS|$(uname -v)|0" | base64`
# Get the server uptime
Uptime=$(($(date +%s) - $(kstat -pn system_misc -s boot_time|cut -f 2)))
# Get CPU model
CPUModel=$(psrinfo -pv | tail -n 1)
CPUModel=$(echo -ne "$CPUModel" | base64)
# Get CPU speed (MHz)
CPUSpeed=$(psrinfo -pv | grep clock | tail -n 1 | awk '{print $(NF-1)}')
CPUSpeed=$(echo -ne "$CPUSpeed" | base64)
# Get number of cores
CPUCores=$(psrinfo -t)
# Calculate average CPU Usage
CPU=$(echo | awk "{ print $tCPU / $X }")
# Calculate IO Wait
IOW=$(echo | awk "{ print $tIOW / $X }")
# Get system memory (RAM)
RAMSize=$(prtconf | grep Memory | awk '{print $3 * 1024}')
# Calculate RAM Usage
RAM=$(echo | awk "{ print $tRAM / $X }")
# Get the Swap Size
SwapSize=$(swap -s | awk '{print $11}' | cut -d "k" -f 1)
# Calculate Swap Usage
SwapFree=$(($(echo $SwapSize) - $(swap -s | awk '{print $9}' | cut -d "k" -f 1)))
Swap=$(echo | awk "{ print 100 - (($SwapFree / $SwapSize) * 100) }")
# Get all disks usage
DISKs=$(echo -ne $(df -k | awk '$1 ~ /\// {print}' | awk '{ print $(NF)","$2*1024","$3*1024","$4*1024";" }') | gzip -cf | base64)
DISKs=$(base64prep "$DISKs")
# Calculate Total Network Usage (bytes)
RX=0
TX=0
NICS=""
for NIC in "${NetworkInterfacesArray[@]}"
do
	# Calculate individual NIC usage
	RX=$(echo | awk "{ print ${tRX[$NIC]} / $X }")
	RX=$(echo "$RX" | awk {'printf "%18.0f",$1'} | xargs)
	TX=$(echo | awk "{ print ${tTX[$NIC]} / $X }")
	TX=$(echo "$TX" | awk {'printf "%18.0f",$1'} | xargs)
	NICS=$NICS"|"$NIC";"$RX";"$TX";"
done
NICS=$(echo -ne "$NICS" | gzip -cf | base64)
NICS=$(base64prep "$NICS")
# Check Services (if any are set to be checked)
ServiceStatusString=""
if [ ! -z "$CheckServices" ]
then
	IFS=',' read -r -a CheckServicesArray <<< "$CheckServices"
	for i in "${CheckServicesArray[@]}"
	do
		ServiceStatusString="$ServiceStatusString"$(servicestatus "$i")";"
	done
fi
# Check Software RAID
RAID=""
if [ "$CheckSoftRAID" -gt 0 ]
then
	for i in $(df -PB1 | awk '$1 ~ /\// {print}' | awk '{ print $1 }')
	do
		mdadm=$(mdadm -D $i)
		if [ ! -z "$mdadm" ]
		then
			mnt=$(df -PB1 | grep $i | awk '{ print $(NF) }')
			RAID="$RAID|$mnt;$i;$mdadm;"
		fi
	done
fi
RAID=$(echo -ne "$RAID" | gzip -cf | base64)
RAID=$(base64prep "$RAID")
# Check Drive Health
DH=""
if [ "$CheckDriveHealth" -gt 0 ]
then
	if [ -x "$(command -v smartctl)" ] #Using S.M.A.R.T. (for regular HDD/SSD)
	then
		for i in $(lsblk -l | grep 'disk' | awk '{ print $1 }')
		do
			DHealth=$(smartctl -A /dev/$i)
			if grep -q 'Attribute' <<< $DHealth
			then
				DHealth=$(smartctl -H /dev/$i)"\n$DHealth"
				DH="$DH|1\n$i\n$DHealth\n"
			else # If initial read has failed, see if drives are behind hardware raid
				MegaRaid=($(smartctl --scan | grep megaraid | awk '{ print $(3) }'))
				if [ ${#MegaRaid[@]} -gt 0 ]
				then
					MegaRaidN=0
					for MegaRaidID in "${MegaRaid[@]}"
					do
						DHealth=$(smartctl -A -d $MegaRaidID /dev/$i)
						if grep -q 'Attribute' <<< $DHealth
						then
							MegaRaidN=$((MegaRaidN + 1))
							DHealth=$(smartctl -H -d $MegaRaidID /dev/$i)"\n$DHealth"
							DH="$DH|1\n$i[$MegaRaidN]\n$DHealth\n"
						fi
					done
				fi
			fi
		done
	fi
	if [ -x "$(command -v nvme)" ] #Using nvme-cli (for NVMe)
	then
		for i in $(lsblk -l | grep 'disk' | awk '{ print $1 }')
		do
			DHealth=$(nvme smart-log /dev/$i)
			if grep -q 'NVME' <<< $DHealth
			then
				if [ -x "$(command -v smartctl)" ]
				then
					DHealth=$(smartctl -H /dev/${i%??})"\n$DHealth"
				fi
				DH="$DH|2\n$i\n$DHealth\n"
			fi
		done
	fi
fi
DH=$(echo -ne "$DH" | gzip -cf | base64)
DH=$(base64prep "$DH")
# Running Processes
RPS1=""
RPS2=""
if [ "$RunningProcesses" -gt 0 ]
then
	# Get initial 'running processes' snapshot, saved from last run
	RPS1=$(cat $ScriptPath/running_proc.txt)
	# Get the current 'running processes' snapshot
	RPS2=$(ps -Ao pid,ppid,uid,user:20,pcpu,pmem,cputime,etime,comm,cmd --no-headers)
	RPS2=$(echo -ne "$RPS2" | gzip -cf | base64)
	RPS2=$(base64prep "$RPS2")
	# Save the current snapshot for next run
	echo $RPS2 > $ScriptPath/running_proc.txt
fi

# Prepare data
DATA="$OS|$Uptime|$CPUModel|$CPUSpeed|$CPUCores|$CPU|$IOW|$RAMSize|$RAM|$SwapSize|$Swap|$DISKs|$NICS|$ServiceStatusString|$RAID|$DH|$RPS1|$RPS2"
POST="v=$VERSION&s=$SID&d=$DATA"
# Save data to file
echo $POST > $ScriptPath/hetrixtools_agent.log

# Post data
wget -t 1 -T 30 -qO- --post-file="$ScriptPath/hetrixtools_agent.log" --no-check-certificate https://sm.hetrixtools.net/ &> /dev/null
