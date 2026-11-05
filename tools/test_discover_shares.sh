#!/bin/bash
# Test-Gehelper (NOT shipped in the PLG): emulates the Share enumeration of
# engine.sh::discover_shares() incl. the trailing-slash pitfall.
# Must print all three share names, one per line, and exit 0 (with set -e).
set -euo pipefail

tmp="$(mktemp -d ./ab_test.XXXXXX)"
mkdir -p "$tmp/a/alpha" "$tmp/a/beta" "$tmp/b/gamma"
SOURCES=("$tmp/a" "$tmp/b")

discover_shares() {
  local s name use d on_array nm
  SHARES=(); ORPHANS=(); EXC_ARGS=()
  local -A cand=()
  for s in ${SOURCES[@]+"${SOURCES[@]}"}; do
    for nm in "$s"/*/; do
      [ -d "$nm" ] || continue
      nm=${nm%/}
      nm=${nm##*/}
      [ -n "$nm" ] || continue
      cand["$nm"]=1
    done
  done
  for name in "${!cand[@]}"; do
    SHARES+=("$name")
  done
  for name in $(printf '%s\n' "${SHARES[@]}" | sort); do
    echo "share=$name"
  done
}

discover_shares
rm -rf -- "./ab_test."*
[ ${#SHARES[@]} -eq 3 ] || { echo "FAIL: expected 3 shares"; exit 1; }
echo "OK"
