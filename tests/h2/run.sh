#!/bin/sh
# The HTTP/2 tests of curl-vx: each case runs build/curl-vx against tests/h2/server.py, an
# HTTP/2 server built on the h2 package, and checks the exit code and the output. The first run
# makes a Python virtualenv with h2 in build/h2-venv (it needs pip and PyPI).
#
#   tests/h2/run.sh
set -u
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
curl=$root/build/curl-vx
certs=$root/tests/tls/certs
work=$root/build/h2-tests
venv=$root/build/h2-venv
mkdir -p "$work"
if [ ! -x "$venv/bin/python" ] || ! "$venv/bin/python" -c "import h2" 2>/dev/null; then
  python3 -m venv "$venv" && "$venv/bin/pip" install -q h2 || { echo "cannot install h2"; exit 1; }
fi
: > "$work/ports"
"$venv/bin/python" "$here/server.py" "$certs" "$work/ports" &
server=$!
trap 'kill $server 2>/dev/null' EXIT
tries=0
while [ ! -s "$work/ports" ] && [ $tries -lt 50 ]; do
  sleep 0.1
  tries=$((tries + 1))
done
read -r tls plain < "$work/ports"
base="https://localhost:$tls"
ca="--cacert $certs/ca.pem"

fail=0
# check NAME EXPECTED_EXIT EXPECTED_STDOUT CURL_ARGUMENTS...
check() {
  name=$1
  want_exit=$2
  want_out=$3
  shift 3
  out=$(timeout 30 "$curl" "$@" 2> "$work/stderr")
  got=$?
  if [ "$got" -ne "$want_exit" ] || [ "$out" != "$want_out" ]; then
    echo "FAIL $name: exit $got (want $want_exit), output '$out' (want '$want_out')"
    sed 's/^/     stderr: /' "$work/stderr"
    fail=1
  else
    echo "ok   $name"
  fi
}
# has NAME TEXT FILE: FILE holds TEXT.
has() {
  if grep -qF -- "$2" "$3"; then
    echo "ok   $1"
  else
    echo "FAIL $1: no '$2' in:"
    sed 's/^/     /' "$3" | head -20
    fail=1
  fi
}

check "GET over TLS with ALPN h2" 0 "hello over h2
2 200" -sS $ca -w '%{http_version} %{http_code}' "$base/"
check "GET with prior knowledge" 0 "hello over h2
2" -sS --http2-prior-knowledge -w '%{http_version}' "http://127.0.0.1:$plain/"
check "1 MiB with WINDOW_UPDATE" 0 "1048576" -sS $ca -o "$work/big" -w '%{size_download}' "$base/big"
head -c 3000000 /dev/urandom > "$work/upload"
sum=$(sha256sum "$work/upload" | cut -c1-16)
check "3 MB upload with flow control" 0 "3000000 $sum" -sS $ca -T "$work/upload" "$base/echo"
check "POST body" 0 "7 $(printf 'a=1&b=2' | sha256sum | cut -c1-16)" -sS $ca -d 'a=1&b=2' "$base/echo"
check "an answer before the upload ends" 0 "too much
413" -sS $ca -T "$work/upload" -w '%{http_code}' "$base/early"
check "padding" 0 "padded data" -sS $ca "$base/padded"
check "100-byte DATA frames" 0 "5000" -sS $ca -o /dev/null -w '%{size_download}' "$base/small-frames"
check "PING before the response" 0 "after a ping" -sS $ca "$base/ping"
check "GOAWAY after the response" 0 "then goaway" -sS $ca "$base/goaway"
check "RST_STREAM" 92 "" -sS $ca "$base/reset"
has "  with curl's message" "HTTP/2 stream 1 was not closed cleanly: INTERNAL_ERROR (err 2)" "$work/stderr"
check "redirect with -L" 0 "hello over h2
1" -sSL $ca -w '%{num_redirects}' "$base/redirect"
"$curl" -sS $ca -i "$base/trailers" > "$work/trailers" 2>&1
has "trailers with -i" "x-checksum: abc123" "$work/trailers"
has "  after the body" "body before trailers" "$work/trailers"
"$curl" -sS $ca -I "$base/long-headers" > "$work/long" 2>&1
has "a head in CONTINUATION frames" "x-long-119: $(printf 'v%.0s' $(seq 200))" "$work/long"
has "  and the status line of curl" "HTTP/2 200 " "$work/long"
"$curl" -sS $ca -H "X-Foo: bar" -A "tester/1" "$base/headers" > "$work/headers" 2>&1
has "request fields: :authority" ":authority: localhost:$tls" "$work/headers"
has "  :path" ":path: /headers" "$work/headers"
has "  lower-case custom header" "x-foo: bar" "$work/headers"
has "  user-agent" "user-agent: tester/1" "$work/headers"
if grep -qi "^host:" "$work/headers"; then
  echo "FAIL   no Host header in HTTP/2"; fail=1
else
  echo "ok     no Host header in HTTP/2"
fi
: > "$work/jar"
check "cookies over HTTP/2" 0 "cookie: none
cookie: h2=yes" -sS $ca -b "$work/jar" -c "$work/jar" "$base/cookie" "$base/cookie"
exit $fail
