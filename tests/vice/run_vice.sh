#!/bin/bash
# Start VICE (flatpak net.sf.VICE) with the text remote monitor on
# 127.0.0.1:6510, in warp mode, without autostart (the tests load the PRG
# through the monitor).  Kills any running x64sc first.
#   usage: run_vice.sh ntsc|pal
set -e
model=${1:?usage: run_vice.sh ntsc|pal}
here=$(cd "$(dirname "$0")" && pwd)
pkill x64sc 2>/dev/null || true
sleep 0.5
flatpak run --share=network --command=x64sc --filesystem="$here" net.sf.VICE \
    -default -model "$model" -remotemonitor -remotemonitoraddress ip4://127.0.0.1:6510 \
    +sound -warp > "$here/build/vice.log" 2>&1 &
