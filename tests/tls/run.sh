#!/bin/sh
# The TLS and time-limit tests of securl: each case runs build/securl against the servers of
# servers.py and checks the exit code and the output. They need python3, and no network but
# 127.0.0.1.
#
#   tests/tls/run.sh
#   CURL=/usr/bin/curl tests/tls/run.sh     # the same checks against another curl
set -u
# The proxy checks set these themselves.
unset http_proxy HTTP_PROXY https_proxy HTTPS_PROXY all_proxy ALL_PROXY no_proxy NO_PROXY
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
curl=${CURL:-$root/build/securl}
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
# It runs curl with the variables of `curl_env`, such as `https_proxy=...`, in its environment.
curl_env=
check() {
  name=$1
  want_exit=$2
  want_out=$3
  shift 3
  # shellcheck disable=SC2086
  out=$(env $curl_env timeout 20 "$curl" "$@" 2> "$work/stderr")
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

# sockopts NAME EXPECTED CURL_ARGUMENTS...: the TCP options that securl sets on its connection,
# as strace shows them, such as `TCP_NODELAY=1 SO_KEEPALIVE=1`. IP_RECVERR comes from the
# connect of the Vx runtime. Skipped when strace is not installed.
sockopts() {
  name=$1
  want=$2
  shift 2
  if ! command -v strace > /dev/null 2>&1; then
    echo "skip $name: no strace"
    return
  fi
  timeout 20 strace -f -qq -e trace=setsockopt -o "$work/strace" "$curl" "$@" \
    > /dev/null 2> "$work/stderr"
  got=$(sed -n 's/.*setsockopt([0-9]*, SOL_[A-Z]*, \([A-Z_]*\), \[\([0-9]*\)\].*/\1=\2/p' \
    "$work/strace" | grep -v IP_RECVERR | tr '\n' ' ' | sed 's/ $//')
  if [ "$got" != "$want" ]; then
    echo "FAIL $name: '$got' (want '$want')"
    fail=1
  else
    echo "ok   $name"
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
# -g, or curl reads the brackets as a glob.
check "a bad IPv6 address" 3 "" \
  -sS -g --cacert "$certs/ca.pem" "https://[1:2:3]:$https/"
stderr_has "  with curl's message" "URL rejected: Bad IPv6 address"
check "an IPv6 zone is not part of the name" 3 "" \
  -sS -g --cacert "$certs/ca.pem" "https://[::1%25lo%zz]:$https/"
# curl checks that the file exists while it reads the command line.
check "missing --cacert file" 2 "" \
  -sS --cacert "$work/no-such-file.pem" "https://localhost:$https/"
stderr_has "  with curl's message" "provided to --cacert does not exist"
check "a --cacert file that holds no certificate" 77 "" \
  -sS --cacert "$here/run.sh" "https://localhost:$https/"
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
# A peer that never ends a line must not make securl read on: each line has a limit, 100 KiB
# for a status or header line and 4 KiB for a trailer, as in libcurl.
check "a status line with no end" 100 "" -sS "http://127.0.0.1:$http/endless-status"
stderr_has "  with curl's message" "A value or data field grew larger than allowed"
check "a header line with no end" 100 "" -sS "http://127.0.0.1:$http/endless-header"
stderr_has "  with curl's message" "A value or data field grew larger than allowed"
# curl reads the extension of a chunk-size line with no limit, so it waits until -m. securl
# stops at 100 KiB.
if [ -z "${CURL:-}" ]; then
  check "a chunk-size line with no end" 56 "" -sS "http://127.0.0.1:$http/endless-chunk-line"
else
  echo "skip a chunk-size line with no end: curl waits for -m there, and securl does not"
fi
check "a trailer with no end" 100 "" -sS "http://127.0.0.1:$http/endless-trailer"
stderr_has "  with curl's message" "Out of memory in chunked-encoding"
check "chunk data with no CRLF after it" 56 "hello" -sS "http://127.0.0.1:$http/chunk-junk"
stderr_has "  with curl's message" "Malformed encoding found in chunked-encoding"
# A body that ends when the connection closes is whole only when TLS ends it with its close
# message. A plain TCP close or a reset could cut it, so they fail, as in curl.
check "a body that TLS ends with close_notify" 0 "body until close" \
  -sS --cacert "$certs/ca.pem" "https://localhost:$https/close-notify"
check "a TLS body cut by a TCP close" 56 "body until close" \
  -sS --cacert "$certs/ca.pem" "https://localhost:$https/close-cut"
stderr_has "  with curl's message" "SSL routines::unexpected eof while reading"
check "a TLS body cut by a reset" 56 "" \
  -sS --cacert "$certs/ca.pem" "https://localhost:$https/close-reset"
stderr_has "  with curl's message" "Recv failure: Connection reset by peer"
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
# Proxies from the environment, as libcurl reads them. The proxy of servers.py does only
# CONNECT and answers 405 to anything else, so a request that went to it directly gives 405.
p=http://127.0.0.1:$proxy
: > "$work/proxy.log"
curl_env="https_proxy=$p"
check "https_proxy" 0 "hello over tls" -sS --cacert "$certs/ca.pem" "https://localhost:$https/"
if grep -q "^CONNECT localhost:$https " "$work/proxy.log"; then
  echo "ok     through a CONNECT of the proxy"
else
  echo "FAIL   no CONNECT in the log of the proxy"
  fail=1
fi
curl_env="HTTPS_PROXY=$p"
check "HTTPS_PROXY" 0 "hello over tls" -sS --cacert "$certs/ca.pem" "https://localhost:$https/"
curl_env="all_proxy=$p"
check "all_proxy" 0 "hello over tls" -sS --cacert "$certs/ca.pem" "https://localhost:$https/"
curl_env="http_proxy=$p"
check "http_proxy" 0 "405" -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$http/"
check "http_proxy with -p goes through a tunnel" 0 "hello over tls" \
  -sS -p "http://127.0.0.1:$http/"
check "  and --proxytunnel too" 0 "hello over tls" -sS --proxytunnel "http://127.0.0.1:$http/"
curl_env="HTTP_PROXY=$p"
check "no HTTP_PROXY in upper case" 0 "hello over tls" -sS "http://127.0.0.1:$http/"
curl_env="http_proxy=$p no_proxy=localhost,127.0.0.1"
check "no_proxy" 0 "hello over tls" -sS "http://127.0.0.1:$http/"
curl_env="http_proxy=$p NO_PROXY=*"
check "NO_PROXY=*" 0 "hello over tls" -sS "http://127.0.0.1:$http/"
curl_env="http_proxy=$p no_proxy=127.0.0.1"
check "--noproxy '' wins over no_proxy" 0 "405" -s --noproxy '' -o /dev/null \
  -w '%{http_code}' "http://127.0.0.1:$http/"
curl_env="http_proxy=$p"
check "-x '' turns the variables off" 0 "hello over tls" -sS -x '' "http://127.0.0.1:$http/"
curl_env="http_proxy=http://127.0.0.1:$mute"
check "-x wins over http_proxy" 0 "405" -s -x "$p" -o /dev/null -w '%{http_code}' \
  "http://127.0.0.1:$http/"
curl_env="https_proxy=$p"
check "-v names the variable" 0 "hello over tls" -sS -v --cacert "$certs/ca.pem" \
  "https://localhost:$https/"
stderr_has "  with curl's message" "Uses proxy env variable https_proxy == '$p'"
curl_env=

# The TCP options of libcurl, in its order: TCP_NODELAY, then keepalive after 60 seconds, every
# 60 seconds, 9 times.
sockopts "TCP_NODELAY and keepalive by default" \
  "TCP_NODELAY=1 SO_KEEPALIVE=1 TCP_KEEPIDLE=60 TCP_KEEPINTVL=60 TCP_KEEPCNT=9" \
  -s "http://127.0.0.1:$http/"
sockopts "--keepalive-time, --keepalive-cnt and --no-tcp-nodelay" \
  "SO_KEEPALIVE=1 TCP_KEEPIDLE=17 TCP_KEEPINTVL=17 TCP_KEEPCNT=3" \
  -s --keepalive-time 17 --keepalive-cnt 3 --no-tcp-nodelay "http://127.0.0.1:$http/"
sockopts "--no-keepalive" "TCP_NODELAY=1" -s --no-keepalive "http://127.0.0.1:$http/"
# --resolve, because curl also tries ::1 for localhost, which sets the options on a second
# socket.
sockopts "the same options over TLS" \
  "TCP_NODELAY=1 SO_KEEPALIVE=1 TCP_KEEPIDLE=60 TCP_KEEPINTVL=60 TCP_KEEPCNT=9" \
  -s --cacert "$certs/ca.pem" --resolve "localhost:$https:127.0.0.1" "https://localhost:$https/"
exit $fail
