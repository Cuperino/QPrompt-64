#!/bin/bash
# Assemble a PRG plus VICE/ld65 label file into tests/vice/build/<name>/.
#   usage: build_debug.sh            -> build/current/ from the working tree
#          build_debug.sh <git-ref>  -> build/<ref>/ from that commit
set -e
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
ref=${1:-}
name=${ref:-current}
out="$here/build/$name"
mkdir -p "$out"
if [ -n "$ref" ]; then
    git -C "$root" show "$ref:scroll.s" > "$out/scroll.s"
    git -C "$root" show "$ref:c64scroll.cfg" > "$out/c64scroll.cfg"
    src="$out/scroll.s"; cfg="$out/c64scroll.cfg"
else
    src="$root/scroll.s"; cfg="$root/c64scroll.cfg"
fi
ca65 -g -t c64 -o "$out/scroll.o" "$src"
ld65 -C "$cfg" -o "$out/scroll.prg" -Ln "$out/labels.txt" "$out/scroll.o"
echo "$out"
