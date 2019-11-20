#!/usr/bin/env perl

use strict;
use warnings;

use FindBin qw($Bin);
use MIME::Base64;
use Time::Piece;

# ----------------------------------------------------------------------------------------------------------------------

# Agent Version (do not change)
my $VERSION = "1.5.8";

# SID (Server ID - automatically assigned on installation, do not change this)
# DO NOT share this ID with anyone
# my $SID = "SIDPLACEHOLDER";
my $SID = "797f39da19f8dc3c7d43e20f17013aff";

# How frequently should the data be collected
my $CollectEveryXSeconds = 3;

# Runtime, in seconds
my $Runtime = 60;

# Calculate how many times per minute should the data be collected
my $RunTimes = $Runtime / $CollectEveryXSeconds;

# ----------------------------------------------------------------------------------------------------------------------

sub base64encodeForUrl {
    my ($string) = @_;

    my $encoded = encode_base64($string);
    # my $encoded = join('', encode_base64($string));
    # $encoded =~ s/\n//g;
    # $encoded =~ s/,$//;

    return $encoded;
}

# ----------------------------------------------------------------------------------------------------------------------

# Kill any lingering agent processes (there shouldn't be any, the agent should finish its job within ~50 seconds, 
# so when a new cycle starts there shouldn't be any lingering agents around, but just in case, so they won't stack)
chomp(my $HTProcesses = `ps -eo user=|sort|uniq -c | grep hetrixtools | awk -F " " '{print \$1}'`);
if (!$HTProcesses) {
    $HTProcesses = 0
}
if ($HTProcesses > 300) {
    system("ps aux | grep -ie hetrixtools_agent.pl | awk '{print \$2}' | xargs kill -9")
}

# ----------------------------------------------------------------------------------------------------------------------

my $M = localtime->strftime("%M");
$M =~ s/^0*//;
if (!$M) {
    $M = 0;
    system("rm -f $Bin/hetrixtools_cron.log");
}

# ----------------------------------------------------------------------------------------------------------------------

# Automatically detect the network interfaces
chomp(my @NetworkInterfacesArray = `ifconfig | grep BROADCAST | grep UP | awk '{print \$1}' | awk -F ":" '{print \$1}'`);

# ----------------------------------------------------------------------------------------------------------------------

# Get the initial network usage
my $START = localtime->strftime("%s");
my %aRX = ();
my %aTX = ();
my %tRX = ();
my %tTX = ();

# Loop through network interfaces
for my $NIC (@NetworkInterfacesArray) {
    chomp($aRX{$NIC} = `dlstat -rpo rbytes "$NIC"`);
    chomp($aTX{$NIC} = `dlstat -tpo obytes "$NIC"`);
    $tRX{$NIC} = 0;
    $tTX{$NIC} = 0;
}

# Collect data loop
my $tCPU = 0;
my $tRAM = 0;
my $tIOW = 0;
my $Loops = 0;
for my $X (1 .. $RunTimes) {
    $Loops = $X;
    # Get vmstat info
    chomp(my $VMSTAT = `vmstat $CollectEveryXSeconds 2 | tail -1`);
    # Get CPU Load
    chomp(my $CPU = 100 - `echo "$VMSTAT" | awk '{print \$22}'`);
    $tCPU += $CPU;
    # Get IO Wait
    chomp(my $IOW = `iostat -xn | grep zones | awk '{print \$9}'`);
    $tIOW += $IOW;
    # Get RAM Usage
    chomp(my $bRAM = `prtconf | grep Memory | awk '{print \$3 * 1024}'`);
    chomp(my $fRAM = `echo "$VMSTAT" | awk '{print \$5}'`);
    my $aRAM = $bRAM - $fRAM;
    chomp(my $RAM = `echo | awk "{ print $aRAM*100/$bRAM }" | sed 's/,/./g'`);
    chomp($RAM = `echo | awk "{ print 100 - $RAM }" | sed 's/,/./g'`);
    chomp($tRAM = `echo | awk "{ print $tRAM + $RAM }" | sed 's/,/./g'`);
    # Get Network Usage
    my $END = localtime->strftime("%s");
    my $TIMEDIFF = $END - $START;
    $START = localtime->strftime("%s");
    # Loop through network interfaces
    for my $NIC (@NetworkInterfacesArray) {
        # Received Traffic
        chomp(my $RX = `dlstat -rpo rbytes "$NIC"`);
        $RX = $RX - $aRX{$NIC};
        $RX = $RX / $TIMEDIFF;
        $RX = sprintf("%18.0f", $RX);
        chomp($aRX{$NIC} = `dlstat -rpo rbytes "$NIC"`);
        $tRX{$NIC} += $RX;
        $tRX{$NIC} = sprintf("%18.0f", $tRX{$NIC});
        # Transferred Traffic
        chomp(my $TX = `dlstat -tpo obytes "$NIC"`);
        $TX = $TX - $aTX{$NIC};
        $TX = $TX / $TIMEDIFF;
        $TX = sprintf("%18.0f", $TX);
        chomp($aTX{$NIC} = `dlstat -tpo obytes "$NIC"`);
        chomp($tTX{$NIC} = `echo | awk "{ print $tTX{$NIC} + $TX }"`);
        $tTX{$NIC} = sprintf("%18.0f", $tTX{$NIC});
    }
    # Check if minute changed, so we can end the loop
    my $MM = localtime->strftime("%M");
    $MM =~ s/^0*//;
    if (!$MM) {
        $MM = 0;
    }
    if ($MM > $M) {
        last;
    }
}

# ----------------------------------------------------------------------------------------------------------------------

# Get Operating System and Kernel
chomp(my $OSName = `uname -s`);
chomp(my $OSRelease = `uname -r`);
chomp(my $OSVersion = `uname -v`);
my $OS = "$OSName $OSRelease";
$OS = base64encodeForUrl("$OS|$OSVersion|0");
# Get the server uptime
my $Curtime = localtime->strftime("%s");
chomp(my $BootTime = `kstat -pn system_misc -s boot_time | cut -f 2`);
my $Uptime = $Curtime - $BootTime;
# Get CPU model
chomp(my $CPUModel = `psrinfo -pv | tail -n 1`);
$CPUModel =~ s/^\s+//;
$CPUModel = base64encodeForUrl($CPUModel);
# Get CPU speed (MHz)
chomp(my $CPUSpeed = `psrinfo -pv | grep clock | tail -n 1 | awk '{print \$(NF-1)}'`);
$CPUSpeed = base64encodeForUrl($CPUSpeed);
# Get number of cores
chomp(my $CPUCores = `psrinfo -t`);
# Calculate average CPU Usage
my $CPU = $tCPU / $Loops;
# Calculate IO Wait
my $IOW = $tIOW / $Loops;
# Get system memory (RAM)
chomp(my $RAMSize = `prtconf | grep Memory | awk '{print \$3 * 1024}'`);
# Calculate RAM Usage
my $RAM = $tRAM / $Loops;
# Get the Swap Size
chomp(my $SwapSize = `swap -s | awk '{print \$11}' | cut -d "k" -f 1`);
# Calculate Swap Usage
chomp(my $SwapUsed = `swap -s | awk '{print \$9}' | cut -d "k" -f 1`);
my $SwapFree = $SwapSize - $SwapUsed;
my $Swap = 100 - (($SwapFree / $SwapSize) * 100);

# Get all disks usage
my @DISKs = `df -k | awk '\$1 ~ /\\// {print}'`;
my $DISKstr = "";
for my $DISK (@DISKs) {
    my @cols = split(/\s+/, $DISK);
    my $total = $cols[1] * 1024;
    my $used = $cols[2] * 1024;
    my $available = $cols[3] * 1024;
    $DISKstr .= "$cols[5],$total,$used,$available;";
}

$DISKstr = `echo -ne "$DISKstr" | gzip -cf | base64`;
$DISKstr =~ s/\+/%2B/;
$DISKstr =~ s/\//%2F/;

# Calculate Total Network Usage (bytes)
my $RX = 0;
my $TX = 0;
my $NICS = "";
for my $NIC (@NetworkInterfacesArray) {
    # Calculate individual NIC usage
    my $RX = $tRX{$NIC} / $Loops;
    $RX = sprintf("%18.0f", $RX);
    $RX =~ s/^\s+//;
    my $TX = $tTX{$NIC} / $Loops;
    $TX = sprintf("%18.0f", $TX);
    $TX =~ s/^\s+//;
    $NICS .= "|$NIC;$RX;$TX;";
}
$NICS = base64encodeForUrl(`echo -ne "$NICS" | gzip -cf`);
$NICS =~ s/\+/%2B/;
$NICS =~ s/\//%2F/;

# ----------------------------------------------------------------------------------------------------------------------

my $ServiceStatusString = "";
my $RAID = "";
my $DH = "";
my $RPS1 = "";
my $RPS2 = "";

# Prepare data
my $DATA = "$OS|$Uptime|$CPUModel|$CPUSpeed|$CPUCores|$CPU|$IOW|$RAMSize|$RAM|$SwapSize|$Swap|$DISKstr|$NICS|$ServiceStatusString|$RAID|$DH|$RPS1|$RPS2";
my $POST = "v=$VERSION&s=$SID&d=$DATA";

# Save data to file
open (FILE, "> $Bin/hetrixtools_agent.log");
print FILE $POST;
close(FILE);

# Post data
system("wget -t 1 -T 30 -qO- --post-file=\"$Bin/hetrixtools_agent.log\" --no-check-certificate https://sm.hetrixtools.net/ &> /dev/null");
