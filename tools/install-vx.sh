#!/bin/sh
# Install the Vx toolchain VERSION for Linux on x86-64 from its GitHub release into DIR, after a
# check of the SHA-256 that the release gives. DIR then has bin/vxc, lib/libvx_std_core.so, the
# stdlib, and the LLVM that the toolchain carries. CI uses it; on your own machine, Vx's installer
# does the same into ~/.vx (README.md).
#
#   tools/install-vx.sh v0.0.6 /opt/vx
set -eu
version=$1
dir=$2
name=vx-$version-x86_64-unknown-linux-gnu
url=https://github.com/vx-lang/Vx/releases/download/$version/$name.tar.gz
work=$(mktemp -d)
curl -fsSL -o "$work/$name.tar.gz" "$url"
curl -fsSL -o "$work/$name.tar.gz.sha256" "$url.sha256"
(cd "$work" && sha256sum -c "$name.tar.gz.sha256")
mkdir -p "$dir"
tar -xzf "$work/$name.tar.gz" -C "$dir" --strip-components=1
"$dir/bin/vxc" --version
