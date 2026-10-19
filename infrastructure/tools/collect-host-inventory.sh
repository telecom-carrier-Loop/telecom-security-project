#!/usr/bin/env bash
# Read-only inventory. Run on each Ubuntu host; review output before sharing.
set -Eeuo pipefail
printf '\n[OS]\n'
if [[ -r /etc/os-release ]]; then sed -n '/^PRETTY_NAME=/p' /etc/os-release; fi
printf '\n[CPU]\n'
LC_ALL=C lscpu | sed -n '/^Architecture:/p; /^CPU(s):/p; /^Model name:/p; /^Virtualization:/p'
printf '\n[Memory]\n'
free -h
printf '\n[Disks: no serial numbers]\n'
lsblk -d -o NAME,SIZE,TYPE,ROTA,TRAN
printf '\n[Interfaces: no addresses]\n'
for interface in /sys/class/net/*; do
    name="${interface##*/}"
    [[ "$name" == lo ]] && continue
    kind=virtual
    [[ ! -e "$interface/device" ]] || kind=device
    printf '%s type=%s state=%s\n' "$name" "$kind" "$(cat "$interface/operstate")"
done
printf '\nMatch device interfaces to actual Ethernet ports; do not count virtual interfaces as physical NICs.\n'
