#!/bin/sh
# Run each libFuzzer target that tools/build-fuzzers.sh built, for SECONDS seconds (60 by
# default), from its seeds in tests/fuzz/corpus. The inputs that libFuzzer finds go to a copy of
# the seeds in build/fuzz/corpus, and an input that makes a target crash, hang or run out of
# memory stays in build/fuzz as crash-*, timeout-* or oom-*. Exits with 1 when one did.
#
#   tools/run-fuzzers.sh [SECONDS] [NAME ...]
set -u
root=$(cd "$(dirname "$0")/.." && pwd)
seconds=${1:-60}
if [ $# -gt 0 ]; then
  shift
fi
if [ $# -eq 0 ]; then
  set -- $(cd "$root/tests/fuzz" && ls *.vx | sed 's/\.vx$//')
fi
cd "$root/build/fuzz" || exit 1
fail=0
for name in "$@"; do
  mkdir -p "corpus/$name"
  cp "$root/tests/fuzz/corpus/$name/"* "corpus/$name/"
  if ./"fuzz-$name" -max_total_time="$seconds" -timeout=10 -print_final_stats=1 \
      "corpus/$name" > "run-$name.log" 2>&1; then
    runs=$(grep '^stat::number_of_executed_units' "run-$name.log" | sed 's/.*: *//')
    echo "ok   fuzz-$name: $runs inputs in $seconds seconds"
  else
    echo "FAIL fuzz-$name: see build/fuzz/run-$name.log"
    grep -E 'ERROR|panic|deadly|Test unit written' "run-$name.log" | head -5
    fail=1
  fi
done
exit $fail
