#!/bin/sh
# Run curl's own test suite against securl.
#
#   tests/run-curl-tests.sh CURL_SRC [TEST ...]
#
# CURL_SRC is a checkout of https://github.com/curl/curl, built with cmake into CURL_SRC/build,
# so that its test servers exist (docs/testing.md has the commands). Without TEST arguments,
# it runs every test with the keyword HTTP. curl's runtests.pl skips the tests that need a
# protocol or a feature that `securl --version` does not list.
#
# It leaves out the tests with the keyword libtest, unittest or tunittest: runtests.pl runs a C
# program of the curl build for those, linked with curl's own libcurl, so they never run
# securl and their results say nothing about it.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
curl_src=$(cd "$1" && pwd)
shift
if [ $# -eq 0 ]; then
  set -- HTTP
fi
set -- "$@" '!libtest' '!unittest' '!tunittest'
# The servers that tools/build-test-tools.sh builds into the virtualenv: nghttpx for the HTTP/2
# tests and stunnel for the HTTPS tests. runtests.pl finds stunnel on PATH, and nghttpx in
# $NGHTTPX.
venv=$root/build/h2-venv
if [ -x "$venv/bin/stunnel" ]; then
  PATH="$venv/bin:$PATH"
  export PATH
fi
if [ -x "$venv/bin/nghttpx" ] && [ -z "${NGHTTPX:-}" ]; then
  NGHTTPX=$venv/bin/nghttpx
  export NGHTTPX
fi
cd "$curl_src/build/tests"
exec perl -I"$curl_src/tests" "$curl_src/tests/runtests.pl" -a -j8 \
  -c "$root/build/securl" "$@"
