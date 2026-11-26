#!/bin/sh
# Refuse code that makes a raw pointer in the code with no trusted code: the packages
# src/curlvx, src/cli and src/disk, and src/main.vx.
#
# `--no-trusted-code curlvx` refuses `unsafe`, but two kinds of safe function read through a
# raw pointer with no check: `sys::text::lit` and `push_lit`, and core's `Write::write_c_str`
# that they call. They are correct for a string literal. But `Vec::as_mut_ptr` and pointer casts
# are safe too, so `lit(v.as_mut_ptr() as *const i8)` would read past the end of `v` with no
# `unsafe` at all. Until Vx gives string literals their own type (Vx#532), this check keeps a
# string literal the only pointer that this code can have.
#
#   tools/check-no-pointers.sh
set -u
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root" || exit 1
# A method that gives the pointer of a buffer, a cast to a pointer type, and the pointer
# arithmetic of core::ptr.
pattern='as_mut_ptr|as_ptr|as \*(const|mut)|core::ptr'
if grep -rnE "$pattern" src/curlvx src/cli src/disk src/main.vx; then
  echo "error: the lines above make a raw pointer in code that must have no trusted code." >&2
  echo "Put the code in src/sys, which may hold trusted code, and give it a safe interface." >&2
  exit 1
fi
