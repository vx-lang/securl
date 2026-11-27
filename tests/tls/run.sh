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
read -r https http proxy mute socks mtls tlsproxy usock usocks usocks5 < "$work/ports"

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
# The head of the reply of a CONNECT proxy goes out with -i, as in curl.
# first_line NAME EXPECTED CURL_ARGUMENTS...: the first line of the output, without its CR.
first_line() {
  name=$1
  want=$2
  shift 2
  got=$(timeout 20 "$curl" "$@" 2> "$work/stderr" | head -n 1 | tr -d '\r')
  if [ "$got" = "$want" ]; then
    echo "ok   $name"
  else
    echo "FAIL $name: '$got' (want '$want')"
    fail=1
  fi
}
first_line "-i shows the reply of the proxy" "HTTP/1.1 200 Connection established" \
  -si --cacert "$certs/ca.pem" -x "127.0.0.1:$proxy" "https://localhost:$https/"
first_line "  unless --suppress-connect-headers" "HTTP/1.1 200 OK" -si \
  --suppress-connect-headers --cacert "$certs/ca.pem" -x "127.0.0.1:$proxy" \
  "https://localhost:$https/"
check "a tunnel that the proxy refuses" 7 "" -sS -x "127.0.0.1:$proxy" "https://localhost:1/"
stderr_has "  with curl's message" "CONNECT tunnel failed, response 403"
first_line "  and -i shows the refusal" "HTTP/1.1 403 Forbidden" -si -x "127.0.0.1:$proxy" \
  "https://localhost:1/"

# An HTTPS proxy: TLS to the proxy, and for an https:// URL, TLS to the server inside it.
# --cacert is for the server only. The proxy has --proxy-cacert, or the CAs of the system.
pcert="--proxy-cacert $certs/ca.pem"
# shellcheck disable=SC2086
check "https through an HTTPS proxy" 0 "hello over tls" -sS $pcert \
  -x "https://localhost:$tlsproxy" --cacert "$certs/ca.pem" "https://localhost:$https/"
check "  which must have a certificate that securl trusts" 60 "" -sS \
  -x "https://localhost:$tlsproxy" --cacert "$certs/ca.pem" "https://localhost:$https/"
stderr_has "  with curl's message" "SSL certificate problem: unable to get local issuer certificate"
check "  unless --proxy-insecure" 0 "hello over tls" -sS --proxy-insecure \
  -x "https://127.0.0.1:$tlsproxy" --cacert "$certs/ca.pem" "https://localhost:$https/"
# shellcheck disable=SC2086
check "  1 MiB in chunks, TLS inside TLS" 0 "200 1048576" -s $pcert \
  -x "https://localhost:$tlsproxy" --cacert "$certs/ca.pem" -o /dev/null \
  -w '%{http_code} %{size_download}' "https://localhost:$https/big"
# The server sends its alert and closes. When the reset of that close reaches the proxy first,
# the alert is lost on the way, and the error is "unexpected eof while reading". So only the
# exit code is checked here.
# shellcheck disable=SC2086
check "  a server that refuses inside the tunnel" 56 "" -sS $pcert \
  -x "https://localhost:$tlsproxy" -k "https://localhost:$mtls/whoami"
# shellcheck disable=SC2086
check "  a tunnel that it refuses" 7 "" -sS $pcert -x "https://localhost:$tlsproxy" \
  "https://localhost:1/"
# shellcheck disable=SC2086
check "http through an HTTPS proxy" 0 "405" -s $pcert -x "https://localhost:$tlsproxy" \
  -o /dev/null -w '%{http_code}' "http://127.0.0.1:$http/"
# shellcheck disable=SC2086
check "  and with -p, through a tunnel" 0 "hello over tls" -sS $pcert -p \
  -x "https://localhost:$tlsproxy" "http://127.0.0.1:$http/"
curl_env="https_proxy=https://localhost:$tlsproxy"
# shellcheck disable=SC2086
check "an https:// proxy in https_proxy" 0 "hello over tls" -sS $pcert \
  --cacert "$certs/ca.pem" "https://localhost:$https/"
curl_env=
check "a --proxy-cacert file that does not exist" 2 "" -sS --proxy-cacert "$work/no-such-file" \
  -x "https://localhost:$tlsproxy" "https://localhost:$https/"

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

# A proxy that is not a URL is exit 5, and the message names the proxy as it was given.
check "a proxy with no host" 5 "" -sS -x "/server" "http://127.0.0.1:$http/"
stderr_has "  with curl's message" "curl: (5) Unsupported proxy syntax in '/server': No host present"
check "a proxy with a bad port" 5 "" -sS -x "localhost:99999" "http://127.0.0.1:$http/"
stderr_has "  with curl's message" "curl: (5) Unsupported proxy syntax in 'localhost:99999': Port number was not a decimal number between 0 and 65535"
curl_env="http_proxy=/server"
check "  and one from the environment" 5 "" -sS "http://127.0.0.1:$http/"
curl_env=
check "a URL with no host" 3 "" -sS "http://:$http/"
stderr_has "  with curl's message" "curl: (3) URL rejected: No host present"

# logged NAME TEXT: the log of the proxies has TEXT.
logged() {
  if grep -qF -- "$2" "$work/proxy.log"; then
    echo "ok   $1"
  else
    echo "FAIL $1: no '$2' in the log of the proxies:"
    sed 's/^/     /' "$work/proxy.log" | tail -5
    fail=1
  fi
}

# SOCKS proxies. SOCKS4 and SOCKS5 get the address of the server, which curl looks up; SOCKS4a
# and SOCKS5h get its name. The proxy of servers.py logs what it got.
s=127.0.0.1:$socks
check "SOCKS4 looks up the name" 0 "hello over tls" -sS -x "socks4://$s" "http://localhost:$http/"
logged "  and sends the address" "SOCKS4 127.0.0.1:$http user="
check "SOCKS4a sends the name" 0 "hello over tls" -sS --socks4a "$s" "http://localhost:$http/"
logged "  to the proxy" "SOCKS4a localhost:$http user="
check "SOCKS5 with --resolve" 0 "hello over tls" -sS --socks5 "$s" \
  --resolve "name.test:$http:127.0.0.1" "http://name.test:$http/"
logged "  sends that address" "SOCKS5 atyp=1 127.0.0.1:$http user="
# The proxy cannot reach ::1, where nothing listens, and says so with code 5.
check "SOCKS5 takes the IPv6 address of a name first" 97 "" -sS -x "socks5://$s" \
  "http://localhost:$http/"
logged "  and sends it" "SOCKS5 atyp=4 ::1:$http user="
stderr_has "  with curl's message" "cannot complete SOCKS5 connection to localhost. (5)"
# Any other name goes to the resolver of the system. ip6-localhost is ::1 in the /etc/hosts of
# Debian and Ubuntu, and the proxy cannot reach it either.
if getent hosts ip6-localhost > /dev/null 2>&1; then
  check "SOCKS5 looks up a name with the resolver" 97 "" -sS -x "socks5://$s" \
    "http://ip6-localhost:$http/"
  stderr_has "  and sends its address" "cannot complete SOCKS5 connection to ip6-localhost. (5)"
fi
# curl 8.23 gives the error of its resolver, not the "error 6 resolving SOCKS destination" of its
# SOCKS code.
check "SOCKS5 with a name that has no address" 6 "" -sS -x "socks5://$s" \
  "http://no-such-host.invalid:$http/"
stderr_has "  with curl's message" "curl: (6) Could not resolve host: no-such-host.invalid"
check "SOCKS4 with a name that has no address" 6 "" -sS -x "socks4://$s" \
  "http://no-such-host.invalid:$http/"
check "SOCKS5h sends the name" 0 "hello over tls" -sS -x "socks5h://$s" "http://localhost:$http/"
logged "  to the proxy" "SOCKS5 atyp=3 localhost:$http user="
check "  and so does --socks5-hostname" 0 "hello over tls" -sS --socks5-hostname "$s" \
  "http://localhost:$http/"
check "HTTPS through SOCKS5h" 0 "hello over tls" -sS --cacert "$certs/ca.pem" \
  -x "socks5h://$s" "https://localhost:$https/"
check "a SOCKS5 user and password" 0 "hello over tls" -sS -x "socks5h://user:secret@$s" \
  "http://localhost:$http/"
logged "  reach the proxy" "SOCKS5 atyp=3 localhost:$http user=user"
check "  and -U too" 0 "hello over tls" -sS -x "socks5h://$s" -U user:secret \
  "http://localhost:$http/"
check "a SOCKS5 password that the proxy refuses" 97 "" -sS -x "socks5h://user:wrong@$s" \
  "http://localhost:$http/"
stderr_has "  with curl's message" "User was rejected by the SOCKS5 server (1 1)."
check "a SOCKS4 proxy that refuses" 97 "" -sS --socks4 "$s" "http://127.0.0.1:1/"
stderr_has "  with curl's message" \
  "[SOCKS] cannot complete SOCKS4 connection to 127.0.0.1:1. (91), request rejected or failed."
check "a SOCKS5 proxy that refuses" 97 "" -sS --socks5 "$s" "http://127.0.0.1:1/"
stderr_has "  with curl's message" "cannot complete SOCKS5 connection to 127.0.0.1. (2)"
check "a SOCKS proxy that does not listen" 7 "" -sS --socks5 127.0.0.1:1 "http://127.0.0.1:$http/"
check "a blank --socks5" 2 "" -sS --socks5 '' "http://127.0.0.1:$http/"
curl_env="all_proxy=socks5h://$s"
check "all_proxy with a SOCKS URL" 0 "hello over tls" -sS "http://localhost:$http/"
curl_env=

# Client certificates. The server on $mtls asks for one signed by client-ca.pem and answers
# with its common name.
who="https://localhost:$mtls/whoami"
check "a client certificate and key in PEM" 0 "hello securl test client" -sS \
  --cacert "$certs/ca.pem" --cert "$certs/client.pem" --key "$certs/client.key" "$who"
check "  both in one file" 0 "hello securl test client" -sS --cacert "$certs/ca.pem" \
  -E "$certs/client-both.pem" "$who"
check "  with -k too" 0 "hello securl test client" -sSk -E "$certs/client-both.pem" "$who"
check "an encrypted key with --pass" 0 "hello securl test client" -sS --cacert "$certs/ca.pem" \
  --cert "$certs/client.pem" --key "$certs/client-enc.key" --pass secret "$who"
check "  and with the password after the file name" 0 "hello securl test client" -sS \
  --cacert "$certs/ca.pem" --cert "$certs/client.pem:secret" --key "$certs/client-enc.key" "$who"
check "  and a wrong password" 43 "" -sS --cacert "$certs/ca.pem" --cert "$certs/client.pem" \
  --key "$certs/client-enc.key" --pass wrong "$who"
stderr_has "  with curl's message" "unable to set private key file: '$certs/client-enc.key' type PEM"
check "a certificate and key in DER" 0 "hello securl test client" -sS --cacert "$certs/ca.pem" \
  --cert "$certs/client.der" --cert-type DER --key "$certs/client-key.der" --key-type der "$who"
# OpenSSL 3 refuses a key that does not match while it loads it.
check "a key that does not match the certificate" 43 "" -sS --cacert "$certs/ca.pem" \
  --cert "$certs/client.pem" --key "$certs/server.key" "$who"
stderr_has "  with curl's message" "unable to set private key file: '$certs/server.key' type PEM"
check "a file that holds no certificate" 58 "" -sS --cacert "$certs/ca.pem" \
  --cert "$certs/client.key" --key "$certs/client.key" "$who"
stderr_has "  with curl's message" "could not load PEM client certificate from $certs/client.key"
check "a certificate type that curl does not know" 43 "" -sS --cacert "$certs/ca.pem" \
  --cert "$certs/client.pem" --cert-type XYZ "$who"
stderr_has "  with curl's message" "not supported file type 'XYZ' for certificate"
# A TLS 1.3 server refuses with an alert after the handshake, which comes with the response.
check "no client certificate" 56 "" -sS --cacert "$certs/ca.pem" "$who"
stderr_has "  with curl's message" "SSL routines::tlsv13 alert certificate required, errno 0"
check "--cert does nothing for http://" 0 "hello over tls" -sS --cert "$work/no-such.pem" \
  "http://127.0.0.1:$http/"

# --compressed: gzip in chunks, and deflate (zlib), decoded as they arrive. The body has 5000
# lines, 203890 bytes.
check "--compressed decodes gzip" 0 "203890" -s --compressed -w '%{size_delivered}' \
  -o "$work/gz" "http://127.0.0.1:$http/gzip"
if [ "$(tail -n 1 "$work/gz")" = "line 4999 of a body that compresses well" ]; then
  echo "ok     to the last line"
else
  echo "FAIL   the last line is '$(tail -n 1 "$work/gz")'"
  fail=1
fi
check "  and deflate" 0 "203890" -s --compressed -w '%{size_delivered}' -o "$work/df" \
  "http://127.0.0.1:$http/deflate"
check "  over TLS" 0 "203890" -s --compressed -w '%{size_delivered}' -o "$work/df" \
  --cacert "$certs/ca.pem" "https://localhost:$https/gzip"
check "no --compressed, no decoding" 0 "200" -s -o "$work/raw" -w '%{http_code}' \
  "http://127.0.0.1:$http/gzip"
check "a gzip body cut short" 61 "" -sS --compressed -o /dev/null "http://127.0.0.1:$http/gzip-cut"
stderr_has "  with curl's message" "Gzip stream ended before completion"
check "a gzip body with a bad CRC" 61 "" -sS --compressed -o /dev/null \
  "http://127.0.0.1:$http/gzip-bad-crc"
stderr_has "  with curl's message" \
  "Error while processing content unencoding: incorrect data check"
check "an encoding curl does not know" 61 "" -sS --compressed -o /dev/null \
  "http://127.0.0.1:$http/compress"
stderr_has "  with curl's message" "Unrecognized content encoding type"
check "six encodings" 61 "" -sS --compressed -o /dev/null "http://127.0.0.1:$http/six"
stderr_has "  with curl's message" "Reject response exceeding limit of 5 content encodings"

# zstd, when the servers can make it and the curl under test has it. The body is the same.
if python3 -I -c 'import compression.zstd' 2> /dev/null && "$curl" -V | grep -q '^Features:.* zstd'; then
  check "--compressed decodes zstd" 0 "203890" -s --compressed -w '%{size_delivered}' \
    -o "$work/zst" "http://127.0.0.1:$http/zstd"
  if cmp -s "$work/zst" "$work/gz"; then
    echo "ok     to the last byte"
  else
    echo "FAIL   the zstd body differs"
    fail=1
  fi
  check "  in two frames with a skippable frame between" 0 "203890" -s --compressed \
    -w '%{size_delivered}' -o "$work/zst" "http://127.0.0.1:$http/zstd-frames"
  check "  and zstd, gzip" 0 "203890" -s --compressed -w '%{size_delivered}' -o "$work/zst" \
    "http://127.0.0.1:$http/zstd-gzip"
  check "a zstd body cut short" 61 "" -sS --compressed -o /dev/null \
    "http://127.0.0.1:$http/zstd-cut"
  stderr_has "  with curl's message" "Zstd stream ended before completion"
  check "a zstd body with a bad checksum" 61 "" -sS --compressed -o /dev/null \
    "http://127.0.0.1:$http/zstd-bad-sum"
  stderr_has "  with curl's message" "Unrecognized or bad HTTP Content or Transfer-Encoding"
else
  echo "skip zstd: python3 has no compression.zstd, or $curl has no zstd"
fi

# brotli, when the servers can make it and the curl under test has it.
if python3 -I -c 'import ctypes; ctypes.CDLL("libbrotlienc.so.1")' 2> /dev/null \
   && "$curl" -V | grep -q '^Features:.* brotli'; then
  check "--compressed decodes br" 0 "203890" -s --compressed -w '%{size_delivered}' \
    -o "$work/br" "http://127.0.0.1:$http/br"
  if cmp -s "$work/br" "$work/gz"; then
    echo "ok     to the last byte"
  else
    echo "FAIL   the brotli body differs"
    fail=1
  fi
  check "  and br, gzip" 0 "203890" -s --compressed -w '%{size_delivered}' -o "$work/br" \
    "http://127.0.0.1:$http/br-gzip"
  check "a brotli body cut short" 61 "" -sS --compressed -o /dev/null \
    "http://127.0.0.1:$http/br-cut"
  stderr_has "  with curl's message" "Brotli stream ended before completion"
  check "bytes after the brotli stream" 23 "" -sS --compressed -o /dev/null \
    "http://127.0.0.1:$http/br-junk"
  stderr_has "  with curl's message" "Failed writing received data to disk/application"
else
  echo "skip brotli: no libbrotlienc for python3, or $curl has no brotli"
fi

# --max-filesize: a body that decodes to more than the limit fails before the piece that would
# go past it, and a body longer than the limit gives the bytes up to it.
check "--max-filesize stops a decoded body" 63 "" -sS --compressed --max-filesize 100000 \
  -o "$work/limited" "http://127.0.0.1:$http/gzip"
stderr_has "  with curl's message" "Would have exceeded max file size"
check "--max-filesize=1000 cuts a chunked body" 63 "1000" -sS --max-filesize=1000 \
  -o "$work/limited" -w '%{size_download}' --cacert "$certs/ca.pem" "https://localhost:$https/big"
stderr_has "  with curl's message" "Exceeded the maximum allowed file size (1000) with 1000 bytes"
if [ "$(wc -c < "$work/limited")" -eq 1000 ]; then
  echo "ok     and keeps 1000 bytes"
else
  echo "FAIL   the file has $(wc -c < "$work/limited") bytes"
  fail=1
fi

# --retry: a 503 is tried again after the wait, with curl's warning, and the exit code is the
# one of the last try.
check "--retry tries a 503 again" 0 "busy
fine" --retry 2 --retry-delay 0.25 "http://127.0.0.1:$http/flaky/a"
stderr_has "  with curl's warning" "Warning: Problem : HTTP error. Retrying in 0.250 seconds. 2 retries left."
check "  and with -f" 0 "fine" -sS -f --retry 1 --retry-delay 0.1 "http://127.0.0.1:$http/flaky/b"
check "no --retry, no second try" 22 "" -sS -f "http://127.0.0.1:$http/flaky/c"

# -C: go on with a file. The full text is in $work/gz, 203890 bytes.
head -c 1000 "$work/gz" > "$work/part"
check "-C - goes on from the size of the file" 0 "206 202890" -s -C - -o "$work/part" \
  -w '%{http_code} %{size_download}' "http://127.0.0.1:$http/ranged"
if cmp -s "$work/part" "$work/gz"; then
  echo "ok     and the file is whole"
else
  echo "FAIL   the file is not the text"
  fail=1
fi
check "  and a whole file gets 416, which is fine" 0 "416" -s -C - -o "$work/part" -w '%{http_code}' \
  "http://127.0.0.1:$http/ranged"
check "a server that ignores the range" 33 "" -sS -C 100 -o "$work/part2" \
  "http://127.0.0.1:$http/no-ranges"
stderr_has "  with curl's message" "HTTP server does not seem to support byte ranges. Cannot resume."
check "-C with -d" 43 "" -sS -C 5 -d x "http://127.0.0.1:$http/ranged"
stderr_has "  with curl's message" "HTTP upload cannot be resumed"

# -J: the file name comes from the Content-Disposition, in --output-dir, and an existing file
# with that name stays as it is.
rm -rf "$work/jdir" && mkdir -p "$work/jdir"
check "-J -O takes the name of Content-Disposition" 0 "$work/jdir/named.txt" -s -J -O \
  --output-dir "$work/jdir" -w '%{filename_effective}' "http://127.0.0.1:$http/cd/file"
if [ "$(cat "$work/jdir/named.txt")" = "named" ] && [ ! -e "$work/jdir/file" ]; then
  echo "ok     with the body, and no file of the URL name"
else
  echo "FAIL   the files of -J are wrong"
  fail=1
fi
echo "older" > "$work/jdir/named.txt"
check "  and does not write over an existing file" 23 "" -s -J -O --output-dir "$work/jdir" \
  "http://127.0.0.1:$http/cd/file"
if [ "$(cat "$work/jdir/named.txt")" = "older" ]; then
  echo "ok     which keeps its bytes"
else
  echo "FAIL   -J wrote over the file"
  fail=1
fi
# The output file opens when the first bytes arrive, so a transfer that fails before leaves an
# existing file alone.
echo "precious" > "$work/kept"
check "a failed transfer leaves an existing -o file alone" 7 "" -s -o "$work/kept" \
  "http://127.0.0.1:1/"
if [ "$(cat "$work/kept")" = "precious" ]; then
  echo "ok     with its bytes"
else
  echo "FAIL   the file is '$(cat "$work/kept")'"
  fail=1
fi

# --tr-encoding: gzip as a transfer coding. Without it, curl refuses one that it did not ask for.
check "--tr-encoding decodes Transfer-Encoding: gzip" 0 "203890" -s --tr-encoding \
  -w '%{size_delivered}' -o "$work/te" "http://127.0.0.1:$http/te-gzip"
check "  and without it, curl refuses it" 61 "" -sS -o /dev/null "http://127.0.0.1:$http/te-gzip"
stderr_has "  with curl's message" "Unsolicited Transfer-Encoding (gzip) found"

# HSTS: the file of --hsts, the Strict-Transport-Security headers of HTTPS responses, and the
# switch from http:// to https:// for the hosts in the file. /sts?VALUE sends VALUE as the
# header.
# hsts_is NAME FILE EXPECTED: the entries of the HSTS file FILE, one per line joined with '|',
# with each date that starts with 20 shown as DATE.
hsts_is() {
  got=$(grep -v '^#' "$2" | sed 's/"20[0-9]\{6\} [0-9:]\{8\}"/"DATE"/' | tr '\n' '|')
  if [ "$got" = "$3" ]; then
    echo "ok   $1"
  else
    echo "FAIL $1: the file has '$got' (want '$3')"
    fail=1
  fi
}
hsts=$work/hsts
rm -f "$hsts"
check "an HTTPS response adds a host to the HSTS file" 0 "sts" -s --hsts "$hsts" \
  --cacert "$certs/ca.pem" "https://localhost:$https/sts?max-age=1000;%20includeSubDomains"
hsts_is "  with its subdomains" "$hsts" '.localhost "DATE"|'
check "then http:// goes over HTTPS, on the port of the URL" 0 "https://localhost:$https/" -s \
  --hsts "$hsts" --cacert "$certs/ca.pem" -o /dev/null -w '%{url_effective}' \
  "http://localhost:$https/"
check "  and so does a subdomain" 0 "hello over tls" -s -k --hsts "$hsts" \
  --resolve "a.localhost:$https:127.0.0.1" "http://a.localhost:$https/"
check "  and -v says so" 0 "hello over tls" -sv --hsts "$hsts" --cacert "$certs/ca.pem" \
  "http://localhost:$https/"
stderr_has "  with curl's message" \
  "Switched from HTTP to HTTPS due to HSTS => https://localhost:$https/"
check "a header without max-age" 0 "sts" -sv --hsts "$hsts" --cacert "$certs/ca.pem" \
  "https://localhost:$https/sts?includeSubDomains"
stderr_has "  is skipped" "Illegal STS header skipped"
check "max-age=0 removes the host" 0 "sts" -s --hsts "$hsts" --cacert "$certs/ca.pem" \
  "https://localhost:$https/sts?max-age=0"
hsts_is "  from the file" "$hsts" ''
check "a longer max-age than two years" 0 "sts" -s --hsts "$hsts" --cacert "$certs/ca.pem" \
  "https://localhost:$https/sts?max-age=99999999999999999999"
two_years=$(date -u -d "@$(($(date +%s) + 63072000))" +%Y%m%d)
if grep -q "^localhost \"$two_years " "$hsts"; then
  echo "ok     is cut to two years"
else
  echo "FAIL  is cut to two years: the file has '$(grep -v '^#' "$hsts")' (want $two_years)"
  fail=1
fi
rm -f "$hsts"
check "an HTTP response cannot add a host" 0 "sts" -s --hsts "$hsts" \
  --resolve "localhost:$http:127.0.0.1" "http://localhost:$http/sts?max-age=1000"
hsts_is "  to the file" "$hsts" ''
check "an IP address gets no entry" 0 "sts" -s --hsts "$hsts" --cacert "$certs/ca.pem" \
  "https://127.0.0.1:$https/sts?max-age=1000"
hsts_is "  in the file" "$hsts" ''
printf 'old.example "20101001 04:47:41"\nlocalhost "unlimited"\n' > "$hsts"
check "a host that never expires" 0 "hello over tls" -s --hsts "$hsts" \
  --cacert "$certs/ca.pem" "http://localhost:$https/"
hsts_is "  stays, and an expired one goes" "$hsts" 'localhost "unlimited"|'
python3 -c 'print("a.example \"20391001 04:47:41\"\n" + "x" * 4094)' > "$hsts"
check "a line of 4095 bytes in the HSTS file" 100 "" -s --hsts "$hsts" "http://127.0.0.1:$http/"
hsts_is "  ends the file there" "$hsts" 'a.example "DATE"|'

# The output file of a transfer that fails. curl makes the file at the first byte, so a failed
# connect leaves none. --remove-on-error removes a file that got bytes, but only a regular one.
rm -f "$work/out1" "$work/out2" "$work/out3"
check "a failed connect makes no output file" 7 "" -s -o "$work/out1" "http://127.0.0.1:1/"
if [ -e "$work/out1" ]; then
  echo "FAIL   and yet there is one"
  fail=1
else
  echo "ok     there is none"
fi
check "--remove-on-error after a cut body" 61 "" -s --compressed --remove-on-error \
  -o "$work/out2" "http://127.0.0.1:$http/gzip-cut"
if [ -e "$work/out2" ]; then
  echo "FAIL   removes the file: it is still there"
  fail=1
else
  echo "ok     removes the file"
fi
check "  and -v says so" 61 "" -v --compressed --remove-on-error -o "$work/out2" \
  "http://127.0.0.1:$http/gzip-cut"
stderr_has "  with curl's note" "Note: Removed output file: "
check "without it, the cut body stays" 61 "" -s --compressed -o "$work/out3" \
  "http://127.0.0.1:$http/gzip-cut"
if [ -s "$work/out3" ]; then
  echo "ok     in its file"
else
  echo "FAIL   in its file: the file is missing or empty"
  fail=1
fi
check "--remove-on-error leaves what is no regular file" 61 "" --compressed --remove-on-error \
  -o /dev/null "http://127.0.0.1:$http/gzip-cut"
stderr_has "  with curl's warning" "Warning: Skipping removal; not a regular file: /dev/null"

# --limit-rate: 1 MiB at 512 KiB per second takes 2 seconds, as in curl.
started=$(date +%s%N)
check "--limit-rate 512k" 0 "1048576" -s --limit-rate 512k -o /dev/null -w '%{size_download}' \
  "http://127.0.0.1:$http/big"
took=$((($(date +%s%N) - started) / 1000000))
if [ "$took" -ge 1900 ]; then
  echo "ok     takes 2 seconds or more ($took ms)"
else
  echo "FAIL   takes 2 seconds or more: $took ms"
  fail=1
fi
check "  and -m still stops it" 28 "" -s --limit-rate 512k -m 1 -o /dev/null \
  "http://127.0.0.1:$http/big"

# %{size_upload}: the body of the last request, chunks with their framing.
check "%{size_upload}" 0 "6" -s -d abcdef -o /dev/null -w '%{size_upload}' \
  "http://127.0.0.1:$http/"
printf 'hello world' > "$work/upload.txt"
check "  of a chunked upload" 0 "21" -s -T "$work/upload.txt" -H 'Transfer-Encoding: chunked' \
  -o /dev/null -w '%{size_upload}' "http://127.0.0.1:$http/"

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

# --unix-socket: the request names the host of the URL, and goes to the socket file. A proxy,
# --connect-to and --resolve do not apply to it, as in curl.
check "HTTP over a Unix socket" 0 "example.com" -sS --unix-socket "$usock" \
  "http://example.com/host"
check "  with the port of the URL in Host" 0 "example.com:8080" -sS --unix-socket "$usock" \
  "http://example.com:8080/host"
check "  and no proxy" 0 "example.com" -sS --unix-socket "$usock" -x "127.0.0.1:$mute" \
  "http://example.com/host"
curl_env="http_proxy=http://127.0.0.1:$mute"
check "  nor one from the environment" 0 "example.com" -sS --unix-socket "$usock" \
  "http://example.com/host"
curl_env=
check "  nor --connect-to" 0 "example.com" -sS --unix-socket "$usock" \
  --connect-to "example.com:80:127.0.0.1:1" "http://example.com/host"
check "HTTPS over a Unix socket" 0 "hello over tls" -sS --cacert "$certs/ca.pem" \
  --unix-socket "$usocks" "https://localhost/"
check "  checks the name of the URL in the certificate" 60 "" -sS --cacert "$certs/ca.pem" \
  --unix-socket "$usocks" "https://example.com/"
check "-m stops a stalled body over a Unix socket" 28 "" -sS -m 1 -o "$work/stalled" \
  --unix-socket "$usock" "http://example.com/stall"
check "a socket file with no server" 7 "" -sS --unix-socket "$work/no-such.sock" \
  "http://example.com/"
stderr_has "  with curl's message" \
  "curl: (7) Failed to connect to example.com:80 over unix://$work/no-such.sock after "
long=/tmp/$(printf '%0120d' 0)
check "a socket path longer than 107 bytes" 6 "" -sS --unix-socket "$long" "http://example.com/"
stderr_has "  with curl's message" "curl: (6) Unix socket path too long: '$long'"
check "a blank --unix-socket" 2 "" -sS --unix-socket "" "http://example.com/"
rm -f "$work/-x"
check "a file name that looks like an option" 0 "" --unix-socket "$usock" --output-dir "$work" \
  -o -x "http://example.com/host"
stderr_has "  gets curl's warning" "Warning: The filename argument '-x' looks like a flag."
if [ "$(cat "$work/-x" 2>/dev/null)" = "example.com" ]; then
  echo "ok     and is still the name of the file"
else
  echo "FAIL   no file $work/-x with the body"
  fail=1
fi
sockopts "a Unix socket gets no TCP options" "" -s --unix-socket "$usock" "http://example.com/"
# A SOCKS proxy on the host localhost with a path is the Unix-domain socket at that path.
: > "$work/proxy.log"
check "SOCKS5h on a Unix socket" 0 "hello over tls" -sS -x "socks5h://localhost$usocks5" \
  "http://localhost:$http/"
logged "  gets the name" "SOCKS5 atyp=3 localhost:$http user="
check "  and --socks5 with HTTPS" 0 "hello over tls" -sS --cacert "$certs/ca.pem" \
  --socks5 "localhost$usocks5" "https://127.0.0.1:$https/"
check "a SOCKS socket file with no server" 7 "" -sS -x "socks5h://localhost$work/no-such.sock" \
  "http://localhost:$http/"
stderr_has "  with curl's message" \
  "curl: (7) Failed to connect to localhost:$http over proxy $work/no-such.sock after "

# --stderr: what would go to standard error goes to the file from that option on, or to
# standard output with `-`.
# file_is NAME FILE TEXT: FILE holds exactly TEXT.
file_is() {
  if [ "$(cat "$2" 2>/dev/null)" = "$3" ]; then
    echo "ok   $1"
  else
    echo "FAIL $1: '$2' holds '$(cat "$2" 2>/dev/null)' (want '$3')"
    fail=1
  fi
}
echo old > "$work/stderr.txt"
check "--stderr FILE" 1 "" -sS --stderr "$work/stderr.txt" "hej://moo"
file_is "  gets the error, in place of what the file held" "$work/stderr.txt" \
  'curl: (1) Protocol "hej" not supported'
check "--stderr - sends it to standard output" 1 'curl: (1) Protocol "hej" not supported' \
  -sS --stderr - "hej://moo"
check "-w %{stderr} with --stderr" 0 "" -s --stderr "$work/stderr.txt" -o /dev/null \
  -w '%{stderr}%{http_code}' "http://127.0.0.1:$http/"
file_is "  writes to the file" "$work/stderr.txt" "200"
check "-v with --stderr" 0 "hello over tls" -s -v --stderr "$work/stderr.txt" \
  "http://127.0.0.1:$http/"
if grep -q "^> GET / HTTP/1.1" "$work/stderr.txt"; then
  echo "ok     writes the request to the file"
else
  echo "FAIL   no request in $work/stderr.txt"
  fail=1
fi
check "a warning before --stderr stays on standard error" 1 "" --unix-socket -a \
  --stderr "$work/stderr.txt" -o -b "hej://moo"
stderr_has "  where it was" "Warning: The filename argument '-a' looks like a flag."
file_is "  and the ones after it go to the file" "$work/stderr.txt" \
  "$(printf '%s\n%s' "Warning: The filename argument '-b' looks like a flag." \
    'curl: (1) Protocol "hej" not supported')"
check "a --stderr file that does not open" 1 "" -S --stderr "/no-such-dir/x" "hej://moo"
stderr_has "  gets curl's warning" "Warning: Warning: Failed to open /no-such-dir/x"
printf 'stderr = "%s"\nurl = "hej://moo"\n' "$work/stderr.txt" > "$work/stderr.cfg"
check "--stderr in a config file" 1 "" -K "$work/stderr.cfg"
file_is "  works too" "$work/stderr.txt" 'curl: (1) Protocol "hej" not supported'
# Connection reuse: a connection stays open after a transfer, and a later request for the same
# place uses it, as in curl. %{num_connects} counts the new connections of each transfer.
nc='%{num_connects}\n'
two() {
  printf '%s\n%s' "$1" "$2"
}
check "reuse: a later --next group to the same server" 0 "$(two 1 0)" -s -o /dev/null \
  -w "$nc" "http://127.0.0.1:$http/" --next -o /dev/null -w "$nc" "http://127.0.0.1:$http/"
check "reuse: two URLs of one group" 0 "$(two 1 0)" -s -o /dev/null -o /dev/null -w "$nc" \
  "http://127.0.0.1:$http/" "http://127.0.0.1:$http/"
check "reuse: a redirect to the same server" 0 "1" -s -L -o /dev/null -w "$nc" \
  "http://127.0.0.1:$http/to-host"
check "reuse: HTTPS" 0 "$(two 1 0)" -s -k -o /dev/null -w "$nc" "https://localhost:$https/" \
  --next -k -o /dev/null -w "$nc" "https://localhost:$https/"
check "reuse: other credentials of the server" 0 "$(two 1 0)" -s -u a:b -o /dev/null -w "$nc" \
  "http://127.0.0.1:$http/" --next -u c:d -o /dev/null -w "$nc" "http://127.0.0.1:$http/"
check "reuse: the host name in another case" 0 "$(two 1 0)" -s -o /dev/null -w "$nc" \
  "http://LOCALHOST:$http/" --next -o /dev/null -w "$nc" "http://localhost:$http/"
check "reuse: a CONNECT tunnel" 0 "$(two 1 0)" -s -k -x "http://127.0.0.1:$proxy" \
  -o /dev/null -w "$nc" "https://localhost:$https/" --next -k -x "http://127.0.0.1:$proxy" \
  -o /dev/null -w "$nc" "https://localhost:$https/"
check "reuse: a Unix-domain socket" 0 "$(two 1 0)" -s --unix-socket "$usock" -o /dev/null \
  -w "$nc" "http://x/" --next --unix-socket "$usock" -o /dev/null -w "$nc" "http://x/"
check "no reuse: another host name for the same server" 0 "$(two 1 1)" -s -o /dev/null \
  -w "$nc" "http://localhost:$http/" --next -o /dev/null -w "$nc" "http://127.0.0.1:$http/"
check "no reuse: other TLS settings" 0 "$(two 1 1)" -s -k -o /dev/null -w "$nc" \
  "https://localhost:$https/" --next --cacert "$certs/ca.pem" -o /dev/null -w "$nc" \
  "https://localhost:$https/"
check "no reuse: other credentials of the proxy" 0 "$(two 1 1)" -s -k \
  -x "http://127.0.0.1:$proxy" -U a:b -o /dev/null -w "$nc" "https://localhost:$https/" \
  --next -k -x "http://127.0.0.1:$proxy" -U c:d -o /dev/null -w "$nc" "https://localhost:$https/"
check "no reuse: --connect-to and then none" 0 "$(two 1 1)" -s \
  --connect-to "a.test:$http:127.0.0.1:$http" -o /dev/null -w "$nc" "http://a.test:$http/" \
  --next --resolve "a.test:$http:127.0.0.1" -o /dev/null -w "$nc" "http://a.test:$http/"
check "no reuse: a Unix-domain socket and then TCP" 0 "$(two 1 1)" -s --unix-socket "$usock" \
  -o /dev/null -w "$nc" "http://127.0.0.1:$http/" --next -o /dev/null -w "$nc" \
  "http://127.0.0.1:$http/"
check "no reuse: after Connection: close" 0 "$(two 1 1)" -s -o /dev/null -w "$nc" \
  "http://127.0.0.1:$http/close-cut" --next -o /dev/null -w "$nc" "http://127.0.0.1:$http/"
# /linger closes the connection after 0.3 seconds, during the second transfer, which waits for
# the mute server for a second. The third finds the connection closed and opens a new one.
check "no reuse: a connection that the server closed" 0 "$(two 1 1)" -s -o /dev/null \
  -w "$nc" "http://127.0.0.1:$http/linger" --next -m 1 -o /dev/null "http://127.0.0.1:$mute/" \
  --next -o /dev/null -w "$nc" "http://127.0.0.1:$http/"
# After /die-next, the server closes the connection at the next request, with no response. As
# curl, securl sends the request again on a new connection.
check "a reused connection that dies is tried again" 0 "$(two 1 1)" -s -v -o /dev/null \
  -w "$nc" "http://127.0.0.1:$http/die-next" --next -o /dev/null -w "$nc" \
  "http://127.0.0.1:$http/"
stderr_has "  with curl's message" "Connection died, retrying a fresh connect (retry count: 1)"
exit $fail
