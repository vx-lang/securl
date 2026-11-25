#!/bin/sh
# Build the servers that curl's test suite needs but that pip cannot install, into the Python
# virtualenv build/h2-venv (nothing goes into the system):
#
#   nghttpx  from nghttp2, for curl's HTTP/2 tests (with libev and c-ares, which it needs)
#   stunnel  for curl's HTTPS tests
#
# They link the OpenSSL of the submodule, so run `make openssl-dev` first. Then:
#
#   tools/build-test-tools.sh
#
# tests/run-curl-tests.sh finds them in the virtualenv. Each download is checked against the
# SHA-256 below; stunnel's matches the one that stunnel.org publishes.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
venv=$root/build/h2-venv
src=$root/build/test-tools-src
ssl=$root/build/openssl-dev/usr/local
jobs=${JOBS:-4}

if [ ! -f "$ssl/lib64/libssl.a" ] && [ ! -f "$ssl/lib/libssl.a" ]; then
  echo "Run make openssl-dev first." >&2
  exit 1
fi
ssl_lib=$ssl/lib64
[ -d "$ssl_lib" ] || ssl_lib=$ssl/lib
[ -x "$venv/bin/python" ] || python3 -m venv "$venv"
mkdir -p "$src"

# fetch NAME URL SHA256: download into a directory of its own and unpack there.
fetch() {
  dir=$src/$1
  file=$dir/$(basename "$2")
  mkdir -p "$dir"
  [ -f "$file" ] || curl -sSfL -o "$file" "$2"
  echo "$3  $file" | sha256sum -c --quiet - || { echo "bad checksum: $file" >&2; exit 1; }
  tar -xf "$file" -C "$dir"
}

fetch libev http://dist.schmorp.de/libev/libev-4.33.tar.gz \
  507eb7b8d1015fbec5b935f34ebed15bf346bed04a11ab82b8eee848c4205aea
fetch c-ares https://github.com/c-ares/c-ares/releases/download/v1.34.9/c-ares-1.34.9.tar.gz \
  9364b70a12eb59a06830fb488d9357f90100dff0d98b23ea3593a183d43e6f2f
fetch nghttp2 https://github.com/nghttp2/nghttp2/releases/download/v1.71.0/nghttp2-1.71.0.tar.xz \
  c0f55121d88650e4b9227aec28cebaf664d2417ca60fe70be0f8d38829f52116
fetch stunnel https://www.stunnel.org/downloads/stunnel-5.82.tar.gz \
  8e7438ccd6b3a2ab05182d0846e112a56a7f557ecdee40de07bf67820008bef7

echo "building libev"
cd "$src/libev/libev-4.33"
./configure --prefix="$venv" --libdir="$venv/lib" --disable-shared --enable-static \
  CFLAGS="-O2 -fPIC" > configure.log
make -j"$jobs" > build.log && make install > install.log

echo "building c-ares"
cmake -S "$src/c-ares/c-ares-1.34.9" -B "$src/c-ares/build" -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$venv" -DCMAKE_INSTALL_LIBDIR=lib -DCARES_STATIC=ON -DCARES_SHARED=OFF \
  -DCARES_BUILD_TOOLS=OFF -DCMAKE_POSITION_INDEPENDENT_CODE=ON > "$src/c-ares/configure.log"
cmake --build "$src/c-ares/build" -j"$jobs" > "$src/c-ares/build.log"
cmake --install "$src/c-ares/build" > "$src/c-ares/install.log"

echo "building nghttpx"
cmake -S "$src/nghttp2/nghttp2-1.71.0" -B "$src/nghttp2/build" -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$venv" -DCMAKE_INSTALL_LIBDIR=lib -DENABLE_APP=ON \
  -DENABLE_HPACK_TOOLS=OFF -DENABLE_EXAMPLES=OFF -DENABLE_DOC=OFF -DBUILD_TESTING=OFF \
  -DBUILD_SHARED_LIBS=OFF -DBUILD_STATIC_LIBS=ON -DWITH_JEMALLOC=OFF -DWITH_LIBXML2=OFF \
  -DWITH_JANSSON=OFF -DWITH_LIBBPF=OFF -DWITH_MRUBY=OFF -DWITH_NEVERBLEED=OFF \
  -DOPENSSL_ROOT_DIR="$ssl" -DOPENSSL_USE_STATIC_LIBS=ON \
  -DLIBEV_INCLUDE_DIR="$venv/include" -DLIBEV_LIBRARY="$venv/lib/libev.a" \
  -DLIBCARES_INCLUDE_DIR="$venv/include" -DLIBCARES_LIBRARY="$venv/lib/libcares.a" \
  -DCMAKE_EXE_LINKER_FLAGS="-ldl -lpthread" > "$src/nghttp2/configure.log"
cmake --build "$src/nghttp2/build" -j"$jobs" --target nghttpx > "$src/nghttp2/build.log"
cp "$src/nghttp2/build/src/nghttpx" "$venv/bin/nghttpx"

echo "building stunnel"
cd "$src/stunnel/stunnel-5.82"
./configure --prefix="$venv" --with-ssl="$ssl" --disable-fips --disable-systemd \
  CPPFLAGS="-I$ssl/include" LDFLAGS="-L$ssl_lib" LIBS="-ldl -lpthread" > configure.log
make -j"$jobs" > build.log && make install > install.log

"$venv/bin/nghttpx" --version | head -1
"$venv/bin/stunnel" -version 2>&1 | head -1
