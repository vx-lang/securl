#!/bin/sh
# Compile and run each unit test program in tests/unit. A test passes when it exits with 0.
# Each test checks its own results with `assert`.
set -u
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
VXDIST=${VXDIST:-/mnt/scratch/curl-vx-toolchain/dist}
VXC=${VXC:-$VXDIST/vxc}
out=$root/build/unit
mkdir -p "$out"
export PATH="/usr/lib/llvm-22/bin:$PATH"
fail=0
for t in "$here"/*.vx; do
  name=$(basename "$t" .vx)
  if ! "$VXC" --package sys="$root/src/sys" --package curlvx="$root/src/curlvx" \
      --no-trusted-code curlvx -c "$t" -o "$out/$name.o" > "$out/$name.log" 2>&1; then
    echo "FAIL (compile) $name"; grep -v '^\[JIT\]' "$out/$name.log" | head -20; fail=1; continue
  fi
  cc "$out/$name.o" -L "$VXDIST" -lvx_std_core -Wl,-rpath,"$VXDIST" -o "$out/$name" || { fail=1; continue; }
  if "$out/$name" > "$out/$name.stdout" 2>&1; then
    echo "ok   $name"
  else
    echo "FAIL $name"; tail -20 "$out/$name.stdout"; fail=1
  fi
done
exit $fail
