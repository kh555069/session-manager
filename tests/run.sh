#!/usr/bin/env bash
# Run every tests/test_*.sh file; exit 1 if any of them fails.
cd "$(dirname "$0")" || exit 1

status=0
for t in test_*.sh; do
  echo "== $t"
  bash "$t" || status=1
done
exit $status
