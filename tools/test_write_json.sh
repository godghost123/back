#!/bin/bash
# test_write_json.sh - Unit tests for the json helpers of engine.sh
# (json_escape / write_json), extractable without running the engine.
#
# Run from the repository root:  bash tools/test_write_json.sh
#
# The tests deliberately run on a machine WITHOUT php (Git-Bash on Windows, or
# a broken php CLI): the php branch then fails and the pure-bash fallback must
# produce the same readable JSON. On a machine WITH php the strict path is
# exercised instead - both must pass, that is the point of the two-layer design.
set -u
log() { echo "LOG: $*"; }
syslog_err() { :; }

src=$(dirname "$0")/../unraid-array-backup/src/include/engine.sh
[ -f "$src" ] || { echo "engine.sh not found: $src" >&2; exit 1; }
# extract only the two helpers (no side effects, no main())
eval "$(awk '/^json_escape\(\) \{/,/^\}/{print} /^write_json\(\) \{/,/^\}/{print}' "$src")"

sanitize_token() { local t="$1"; printf '%s' "${t//[^A-Za-z0-9._-]/_}"; }

fails=0
check() { # check <label> <condition-result>
  if [ "$2" -eq 0 ]; then echo "PASS: $1"; else echo "FAIL: $1"; fails=$((fails+1)); fi
}
is_valid_json() { # structural check without php: balanced braces/quotes via python or jq if present
  if command -v jq >/dev/null 2>&1; then jq -e . "$1" >/dev/null 2>&1
  elif command -v python3 >/dev/null 2>&1; then python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$1"
  else tr -c '{}' '\n\n' <"$1" | tr -d -c '\n' | awk 'END{exit (NR%2)?1:0}'
  fi
}

out=$(mktemp -d ./tmp_wj_out.XXXXXX)
trap 'rm -rf "$out"' EXIT

echo "=== 1: plain body"
write_json "$out/status.json" '"state":"running","run_id":"r-1","sources":{"disk1":{"pct":"42"}}'
check "status.json written" $([ -s "$out/status.json" ]; echo $?)
check "status.json parses"  $(is_valid_json "$out/status.json"; echo $?)

echo "=== 2: body carrying an escaped quote (rsync error text with a quote in the path)"
write_json "$out/err.json" '"error":"rsync: \"permission denied\" on /mnt/disk1/a\"b","dry_run":false'
check "err.json written" $([ -s "$out/err.json" ]; echo $?)
check "err.json parses"  $(is_valid_json "$out/err.json"; echo $?)

echo "=== 3: unbalanced quote -> must be REFUSED (no file)"
write_json "$out/bad.json" '"state":"run"ning"' >/dev/null 2>&1
check "bad body refused"   $([ ! -e "$out/bad.json" ]; echo $?)

echo "=== 4: raw control char in body -> must be REFUSED (no file)"
write_json "$out/ctrl.json" "$(printf '"a":"x\ny"')" >/dev/null 2>&1
check "control char refused" $([ ! -e "$out/ctrl.json" ]; echo $?)

echo "=== 5: nested dir is created on demand"
write_json "$out/a/b/c/meta.json" '"run_id":"r-2","state":"success"' >/dev/null 2>&1
check "nested path created" $([ -s "$out/a/b/c/meta.json" ]; echo $?)

echo "=== 6: json_escape handles quotes, backslashes and tabs"
e1=$(json_escape 'plain path /mnt/disk1')
e2=$(json_escape 'quote " and backslash \ and '"$(printf '\t')"'tab')
check "plain escape valid"    $([ "$e1" = '"plain path /mnt/disk1"' ]; echo $?)
check "hard chars escaped"    $([ "$e2" = '"quote \" and backslash \\ and \ttab"' ]; echo $?)

echo "=== 7: runmeta body as composed by run_backup (orphan list)"
ORPHANS=("backup-on-array" "sas3 01")
olist=""
for o in "${ORPHANS[@]}"; do olist="${olist}${olist:+,}\"$(sanitize_token "$o")\""; done
ometa="[$olist]"
write_json "$out/runmeta.json" "\"run_id\":\"r-3\",\"state\":\"success\",\"orphan_dirs\":${ometa},\"sources\":{\"disk1\":{\"exit\":0,\"delta_bytes\":0}}"
check "runmeta.json written" $([ -s "$out/runmeta.json" ]; echo $?)
check "runmeta.json parses"  $(is_valid_json "$out/runmeta.json"; echo $?)
check "orphan names sanitized" $(grep -q '"orphan_dirs":\["backup-on-array","sas3_01"\]' "$out/runmeta.json"; echo $?)

echo "=== 8: empty orphan list stays [] (no leading comma in the array)"
ORPHANS=()
ometa="[]"
olist=""
for o in ${ORPHANS[@]+"${ORPHANS[@]}"}; do olist="${olist}${olist:+,}\"$(sanitize_token "$o")\""; done
[ -n "$olist" ] && ometa="[$olist]"
write_json "$out/noph.json" "\"run_id\":\"r-4\",\"orphan_dirs\":${ometa}"
check "empty list stays []"    $([ "$ometa" = "[]" ]; echo $?)
check "no leading comma in json" $(grep -q '"orphan_dirs":\[\]' "$out/noph.json"; echo $?)

echo
if [ "$fails" -eq 0 ]; then
  echo "RESULT: PASS (php available: $(command -v php >/dev/null 2>&1 && echo yes || echo no))"
else
  echo "RESULT: FAIL ($fails) (php available: $(command -v php >/dev/null 2>&1 && echo yes || echo no))"
  exit 1
fi
