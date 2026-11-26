#!/bin/sh
# The TLS and time-limit tests of curl-vx: each case runs build/curl-vx against the servers of
# servers.py and checks the exit code and the output. They need python3, and no network but
# 127.0.0.1.
#
#   tests/tls/run.sh
set -u
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
curl=$root/build/curl-vx
certs=$here/certs
work=$root/build/tls-tests
mkdir -p "$work"
: > "$work/proxy.log"
: > "$work/ports"

python3 -I "$here/servers.py" "$certs" "$work/ports" "$work/proxy.log" &
server=$!
trap 'kill $server 2>/dev/null' EXIT
tries=0
while [ ! -s "$work/ports" ] && [ $tries -lt 50 ]; do
  sleep 0.1
  tries=$((tries + 1))
done
read -r https http proxy mute < "$work/ports"

fail=0
# check NAME EXPECTED_EXIT EXPECTED_STDOUT CURL_ARGUMENTS...
check() {
  name=$1
  want_exit=$2
  want_out=$3
  shift 3
  out=$(timeout 20 "$curl" "$@" 2> "$work/stderr")
  got=$?
  if [ "$got" -ne "$want_exit" ] || [ "$out" != "$want_out" ]; then
    echo "FAIL $name: exit $got (want $want_exit), output '$out' (want '$want_out')"
    sed 's/^/     stderr: /' "$work/stderr"
    fail=1
  else
    echo "ok   $name"
  fi
}

# stderr_has NAME TEXT: the standard error of the last check holds TEXT.
stderr_has() {
  if grep -qF "$2" "$work/stderr"; then
    echo "ok   $1"
  else
    echo "FAIL $1: no '$2' in the standard error:"
    sed 's/^/     /' "$work/stderr"
    fail=1
  fi
}

check "trusted CA" 0 "hello over tls" \
  -sS --cacert "$certs/ca.pem" "https://localhost:$https/"
check "unknown CA" 60 "" \
  -sS "https://localhost:$https/"
check "-k skips the check" 0 "hello over tls" \
  -sSk "https://localhost:$https/"
check "IP address in the certificate" 0 "hello over tls" \
  -sS --cacert "$certs/ca.pem" "https://127.0.0.1:$https/"
check "host name not in the certificate" 60 "" \
  -sS --cacert "$certs/ca.pem" --resolve "other.example:$https:127.0.0.1" \
  "https://other.example:$https/"
# 999.1.1.1 is no IPv4 address, so it is a host name, and the certificate does not name it.
# OpenSSL refuses it as an address, so a check of it as an address would check nothing.
check "a name that looks like an address" 60 "" \
  -sS --cacert "$certs/ca.pem" --resolve "999.1.1.1:$https:127.0.0.1" \
  "https://999.1.1.1:$https/"
check "a bad IPv6 address" 3 "" \
  -sS --cacert "$certs/ca.pem" "https://[1:2:3]:$https/"
stderr_has "  with curl's message" "URL rejected: Bad IPv6 address"
check "an IPv6 zone is not part of the name" 3 "" \
  -sS --cacert "$certs/ca.pem" "https://[::1%25lo%zz]:$https/"
check "missing --cacert file" 77 "" \
  -sS --cacert "$work/no-such-file.pem" "https://localhost:$https/"
check "1 MiB in chunks" 0 "200 1048576" \
  -sS --cacert "$certs/ca.pem" -o "$work/big" -w '%{http_code} %{size_download}' \
  "https://localhost:$https/big"
check "redirect from http to https" 0 "hello over tls" \
  -sSL --cacert "$certs/ca.pem" "http://localhost:$http/to-https"
check "https through a CONNECT proxy" 0 "hello over tls" \
  -sS --cacert "$certs/ca.pem" -x "127.0.0.1:$proxy" "https://localhost:$https/"
if grep -q "^CONNECT localhost:$https HTTP/1.1\$" "$work/proxy.log"; then
  echo "ok   the proxy got CONNECT localhost:$https"
else
  echo "FAIL the proxy log has no CONNECT line:"
  sed 's/^/     /' "$work/proxy.log"
  fail=1
fi

check "a chunk size of 2^63" 56 "" \
  -sS "http://127.0.0.1:$http/huge-chunk"
stderr_has "  with curl's message" "invalid chunk size: '8000000000000000'"
check "-m stops a stalled body" 28 "" \
  -sS -m 1 -o "$work/stalled" "http://127.0.0.1:$http/stall"
stderr_has "  with curl's message" "with 10 out of 100 bytes received"
check "-m stops a stalled body over TLS" 28 "" \
  -sS -m 1 --cacert "$certs/ca.pem" -o "$work/stalled" "https://localhost:$https/stall"
stderr_has "  with curl's message" "with 10 out of 100 bytes received"
check "--connect-timeout stops a TLS handshake" 28 "" \
  -sS --connect-timeout 1 "https://127.0.0.1:$mute/"
stderr_has "  with curl's message" "Connection timed out after"
check "--connect-timeout leaves a slow body alone" 28 "" \
  -sS --connect-timeout 1 -m 2 -o "$work/stalled" "http://127.0.0.1:$http/stall"
stderr_has "  and -m ends it" "Operation timed out after"
exit $fail
