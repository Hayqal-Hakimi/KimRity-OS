#!/usr/bin/env bash
# Unit test for part() in install.sh — the one branch that decides whether the
# partition suffix is "1" (/dev/vda1) or "p1" (/dev/nvme0n1p1). Getting it wrong
# means step 1 partitions a disk and step 2 finds no partition to format.
# It extracts the real function from install.sh, so it cannot drift from it.
set -u
cd "$(dirname "$0")/.."
eval "$(sed -n '/^part() {/,/^}/p' install.sh)"

fail=0
check() {  # check <name> <got> <want>
  [ "$2" = "$3" ] || { printf 'FAIL %-6s got %s, want %s\n' "$1" "$2" "$3"; fail=1; }
}
DISK=/dev/vda;       check sata "$(part 1)" /dev/vda1
DISK=/dev/nvme0n1;   check nvme "$(part 2)" /dev/nvme0n1p2
DISK=/dev/mmcblk0;   check mmc  "$(part 1)" /dev/mmcblk0p1
[ "$fail" = 0 ] && echo "part(): 3/3 OK"
exit "$fail"
