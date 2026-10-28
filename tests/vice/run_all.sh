#!/bin/bash
# Run every check against the working tree:
#   1. scan_keyboard unit test (py65, no emulator)
#   2. beam-race check on NTSC, then PAL (VICE)
#   3. screen-content comparison against a baseline commit (VICE, NTSC)
# VICE is closed after each run.
#   usage: run_all.sh [baseline-ref]     (default: 7cbf4f5, last v1.1 commit
#                                          before the beam-chasing scroll)
here=$(cd "$(dirname "$0")" && pwd)
cd "$here"
base=${1:-7cbf4f5}
fail=0
trap 'pkill x64sc 2>/dev/null' EXIT

cur=$(./build_debug.sh) || exit 1
old=$(./build_debug.sh "$base") || exit 1

echo "== keyboard scan"
out=$(python3 kbtest.py "$cur/labels.txt" "$cur/scroll.prg") || { echo "$out"; fail=1; }
echo "$out" | tail -1

for model in ntsc pal; do
    echo "== beam race ($model)"
    ./run_vice.sh $model
    timeout 120 python3 race.py "$cur/labels.txt" "$cur/scroll.prg" $model || fail=1
    pkill x64sc
done

echo "== screen content vs $base (ntsc)"
for b in "$old" "$cur"; do
    ./run_vice.sh ntsc
    timeout 120 python3 content.py dump "$b/labels.txt" "$b/scroll.prg" "$b/content.json" || fail=1
    pkill x64sc
done
python3 content.py compare "$old/content.json" "$cur/content.json" || fail=1

[ $fail = 0 ] && echo "ALL PASSED" || echo "SOME CHECKS FAILED"
exit $fail
