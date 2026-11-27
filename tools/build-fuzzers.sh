#!/bin/sh
# Build the libFuzzer targets of tests/fuzz into build/fuzz/fuzz-NAME.
#
# vxc has no fuzzer option, so each target goes through LLVM: vxc writes the LLVM dialect of
# MLIR (`--action emit-llvm`), mlir-translate turns it into LLVM IR, and clang adds the coverage
# of libFuzzer (`-fsanitize=fuzzer-no-link`) and links its main, which calls the exported
# `vx_fuzz_one` of the target with each input.
#
#   VXC=... VX_LIBDIR=... LLVM_BIN=... TLS_LIBS=... tools/build-fuzzers.sh [NAME ...]
#
# `make fuzz` passes the settings of config.mk.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
VXC=${VXC:-vxc}
VX_LIBDIR=${VX_LIBDIR:-$HOME/.vx/current/lib}
LLVM_BIN=${LLVM_BIN:-/usr/lib/llvm-22/bin}
TLS_LIBS=${TLS_LIBS:--lssl -lcrypto}
export PATH="$LLVM_BIN:$PATH"
CLANG=${CLANG:-clang}
if ! command -v "$CLANG" > /dev/null 2>&1; then
  CLANG=clang-22
fi
out=$root/build/fuzz
mkdir -p "$out"
cat > "$out/shim.c" <<'EOF'
#include <stddef.h>
#include <stdint.h>
int vx_fuzz_one(const uint8_t *data, long len);
int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
  vx_fuzz_one(data, (long)size);
  return 0;
}
EOF
if [ $# -eq 0 ]; then
  set -- $(cd "$root/tests/fuzz" && ls *.vx | sed 's/\.vx$//')
fi
for name in "$@"; do
  src=$root/tests/fuzz/$name.vx
  "$VXC" --package sys="$root/src/sys" --package securl="$root/src/securl" \
    --no-trusted-code securl --action emit-llvm "$src" > "$out/$name.mlir"
  mlir-translate --mlir-to-llvmir "$out/$name.mlir" -o "$out/$name.ll"
  "$CLANG" -O1 -g -Wno-override-module -fsanitize=fuzzer-no-link -c "$out/$name.ll" \
    -o "$out/$name.o"
  # shellcheck disable=SC2086
  "$CLANG" -g -fsanitize=fuzzer "$out/shim.c" "$out/$name.o" $TLS_LIBS -L "$VX_LIBDIR" \
    -lvx_std_core -Wl,-rpath,"$VX_LIBDIR" -lpthread -ldl -o "$out/fuzz-$name"
  echo "built build/fuzz/fuzz-$name"
done
