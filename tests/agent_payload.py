"""Run the agent against illumos command fixtures without contacting HetrixTools."""

import gzip
import json
import subprocess
import tempfile
from base64 import b64decode
from pathlib import Path
from urllib.parse import parse_qs


ROOT = Path(__file__).resolve().parents[1]

COMMANDS = {
    "date": 'case "$1" in +%s) n=$(cat samples 2>/dev/null || echo 0); echo $((1200 + n * 3));; *) echo "2026-11-22 11:11:11 UTC";; esac',
    "vmstat": """printf '%s\\n' '0 0 0 0 2048 1 1 10 10 80' '0 0 0 0 4096 1 1 15 20 65'
echo 1 > samples""",
    "prtconf": 'echo "Memory size: 8 Megabytes"',
    "swap": 'echo "total: 0k bytes allocated + 0k reserved = 0k used, 0k available"',
    "dladm": 'echo "net0:up"; echo "net1:down"',
    "dlstat": 'n=$(cat samples 2>/dev/null || echo 0); echo $(( 100 + n * 300 ))',
    "ipadm": "printf '%s\\n' '192.0.2.2/24' '2001\\:db8\\:\\:2/64' 'fe80\\:\\:1/64'",
    "netstat": """printf '%s\\n' '*.443 *.* 0 0 LISTEN' '127.0.0.1.25 *.* 0 0 LISTEN' \\
'192.0.2.2.443 192.0.2.3.12345 0 0 ESTABLISHED' '2001:db8::2.443 2001:db8::3.54321 0 0 ESTABLISHED' \\
'192.0.2.2.50000 192.0.2.3.443 0 0 ESTABLISHED'""",
    "svcs": 'case "$*" in *ssh*) echo online;; *) echo offline;; esac',
    "uptime": 'echo "11:11am up 1 day, load average: 0.11, 0.22, 0.33"',
    "kstat": 'printf "unix:0:system_misc:boot_time\\t1000\\n"',
    "psrinfo": '''case "$1" in
-pv) echo "Test CPU";;
-v) echo "The x86 processor operates at 2200 MHz";;
-p) echo 1;;
*) echo "0 on-line"; echo "1 on-line";;
esac''',
    "zpool": '''case "$1" in
list) printf "%s\\n" zones backup;;
iostat) printf "zones\\t10\\t90\\t1\\t2\\t123\\t456\\nbackup\\t20\\t80\\t1\\t2\\t321\\t654\\n";;
status) printf "  pool: %s\\n state: ONLINE\\n" "$2";;
esac''',
    "zfs": '''case "$*" in
*name,used,available,mountpoint*) printf "zones\\t10\\t90\\t/zones\\nbackup\\t20\\t80\\tnone\\n";;
*name,mountpoint*) printf "zones\\t/zones\\nbackup\\tnone\\n";;
esac''',
    "diskinfo": 'printf "%s\\n" "SAS c0t0d0" "SAS c0t1d0"',
    "smartctl": 'printf "%s\\n" "Product: Test Drive" "Serial Number: 123" "Transport protocol: SAS" "SMART Health Status: OK"; exit 8',
    "ps": 'echo "100 1 0 root 0 0 00:00 01:00 test test"',
    "wget": '''for flag in "$@"; do
	case "$flag" in
		--post-file=*) cat "${flag#*=}" > posted;;
		--no-check-certificate) exit 1;;
	esac
done
test "${!#}" = https://sm.hetrixtools.net/v2/''',
}


def check_payload():
    with tempfile.TemporaryDirectory() as temp:
        workdir = Path(temp)
        bin_dir = workdir / "bin"
        bin_dir.mkdir()
        (workdir / "state").mkdir()
        for name, implementation in COMMANDS.items():
            stub = bin_dir / name
            stub.write_text("#!/bin/bash\n" + implementation + "\n")
            stub.chmod(0o700)

        agent = workdir / "hetrixtools_agent.sh"
        lines = (ROOT / agent.name).read_text().splitlines()
        agent.write_text("\n".join(
            f'PATH="{bin_dir}:$PATH"' if line.startswith("PATH=") else line
            for line in lines
        ) + "\n")
        (workdir / "hetrixtools.cfg").write_text(
            'SID="0123456789abcdef0123456789abcdef"\n'
            'CheckServices="svc:/network/ssh:default,svc:/example:default"\n'
            'CheckSoftRAID=1\nCheckDriveHealth=1\nRunningProcesses=1\n'
            'Unknown=$(touch config-was-executed)\n'
        )
        (workdir / "custom_variables.json").write_text('{"example": 1}')

        def run_agent():
            (workdir / "samples").unlink(missing_ok=True)
            result = subprocess.run(
                ["bash", str(agent)], cwd=workdir, check=True, capture_output=True, text=True,
            )
            assert not result.stderr, result.stderr
            form = parse_qs((workdir / "posted").read_text().strip())
            return json.loads(gzip.decompress(b64decode(form["j"][0])))

        first = run_agent()
        assert first["version"] == "2.4.2"
        assert first["cpu"] == "35.00" and first["ram"] == "50.00"
        assert first["ramswap"] == "0.00" and first["uptime"] == "200"
        assert first["load1"] == "0.11" and first["cpuspeed"] == "2200"
        assert first["rps1"] == ""
        expected = {
            "nics": "net0,100,100;",
            "ipv4": "net0,192.0.2.2;",
            "ipv6": "net0,2001:db8::2;",
            "conn": "443,2;",
            "serv": "svc:/network/ssh:default,1;svc:/example:default,0;",
            "disks": "/zones,zfs,100,10,90;backup,zfs,100,20,80;",
            "iops": "/zones,123,456;backup,321,654;",
            "cust": '{"example": 1}',
        }
        for field, value in expected.items():
            assert b64decode(first[field]).decode() == value, (field, first[field])
        pools = b64decode(first["zp"]).decode().split(";")
        assert pools[0].startswith("/zones,zones,") and pools[1].startswith("backup,backup,")
        drives = b64decode(first["dh"]).decode().split(";")
        assert len(drives) == 2 and drives[0].startswith("3,c0t0d0,")
        assert run_agent()["rps1"] == first["rps2"]
        assert not (workdir / "config-was-executed").exists()


if __name__ == "__main__":
    check_payload()
    print("SmartOS agent payload matches the v2 fixture")
