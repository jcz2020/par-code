#!/bin/sh
# Concatenate per-target checksum files into a single checksums.txt for the release.
# Used by release.yml's coordinator job after all platform builds upload their
# per-target checksum files as workflow artifacts.
set -eu
cd "$(dirname "$0")/.."
{
  for f in checksum-*.txt; do
    [ -f "$f" ] && cat "$f"
  done
} | sort -u > checksums.txt
echo "Wrote checksums.txt ($(wc -l < checksums.txt) entries)"
