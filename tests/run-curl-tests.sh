#!/bin/sh
# Run curl's own test suite against curl-vx.
#
#   tests/run-curl-tests.sh CURL_SRC [TEST ...]
#
# CURL_SRC is a checkout of https://github.com/curl/curl, built with cmake into CURL_SRC/build,
# so that its test servers exist (README.md has the commands). Without TEST arguments,
# it runs every test with the keyword HTTP. curl's runtests.pl skips the tests that need a
# protocol or a feature that `curl-vx --version` does not list.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
curl_src=$(cd "$1" && pwd)
shift
if [ $# -eq 0 ]; then
  set -- HTTP
fi
cd "$curl_src/build/tests"
exec perl -I"$curl_src/tests" "$curl_src/tests/runtests.pl" -a -j8 \
  -c "$root/build/curl-vx" "$@"
