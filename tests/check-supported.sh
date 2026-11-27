#!/bin/sh
# Run the curl tests of tests/supported-tests.txt against build/securl, and fail when a test
# fails that tests/supported-known-failures.txt does not list. A listed test that passes gets a
# note, so that the list can shrink.
#
#   tests/check-supported.sh CURL_SRC
set -u
here=$(cd "$(dirname "$0")" && pwd)
log=$(mktemp)
# shellcheck disable=SC2046
"$here/run-curl-tests.sh" "$1" $(cat "$here/supported-tests.txt") > "$log" 2>&1
grep "TESTDONE" "$log"
failed=$(sed -n 's/^TESTFAIL: These test cases failed: //p' "$log")
known=$(grep -v '^#' "$here/supported-known-failures.txt")
status=0
for t in $failed; do
  if ! echo "$known" | grep -qx "$t"; then
    echo "FAIL test $t, which passed before"
    status=1
  fi
done
for t in $known; do
  if ! echo " $failed " | grep -q " $t "; then
    echo "note: test $t passes now; take it out of tests/supported-known-failures.txt"
  fi
done
rm -f "$log"
exit $status
