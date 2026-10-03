#!/usr/bin/env bash
# test-announce.sh - hardware-FREE pure-shell test for the operator broadcast tool
# scripts/deploy/announce.sh. No VM, no network, no server process - it drives the
# real announce.sh against a TEMP feed (NOTICES_FILE override) so the live served
# server/notices.json is NEVER touched.
#
# Covers: fresh-feed defaults (id/level/expires/title), monotonic unique ids, strictly-
# monotonic server-stamped ts (two same-second pushes get ts and ts+1) and post-clear
# delivery (a fresh push after --clear still orders ahead of a prior seen-ts), --title
# and --level alert, --expires arithmetic, invalid --level rejection (feed unchanged),
# JSON validity + array shape after every op, feed bounding to the 50 most recent
# (oldest dropped, ids stay the most-recent contiguous run), --clear, and --list.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SELF_DIR}/../.." && pwd)"
# shellcheck source=lib-assert.sh
source "${SELF_DIR}/lib-assert.sh"

ANNOUNCE="${REPO_ROOT}/scripts/deploy/announce.sh"
[ -f "${ANNOUNCE}" ] || { echo "FAIL: announce.sh not found at ${ANNOUNCE}"; exit 1; }

# A temp feed - the override that keeps the test off the live server/notices.json.
TMPDIR_T="$(mktemp -d "${TMPDIR:-/tmp}/partyos-announcetest.XXXXXX")"
FEED="${TMPDIR_T}/notices.json"
LIVE_FEED="${REPO_ROOT}/server/notices.json"
# Snapshot the live feed's pre-test state so we can prove the test never touched it.
LIVE_BEFORE="absent"
[ -e "${LIVE_FEED}" ] && LIVE_BEFORE="$(cksum "${LIVE_FEED}" | awk '{print $1"-"$2}')"

cleanup() { rm -rf "${TMPDIR_T}"; }
trap cleanup EXIT

# announce - run announce.sh against the TEMP feed (override on every call).
announce() { NOTICES_FILE="${FEED}" bash "${ANNOUNCE}" "$@"; }

# jq-free JSON probe via python3. `feed_field EXPR` prints python's eval of EXPR with
# the parsed array bound to `d`; exits non-zero on parse failure (used to prove JSON
# validity too). e.g. feed_field 'len(d)', feed_field 'd[0]["id"]'.
feed_field() {
    FEED="${FEED}" python3 - "$1" <<'PY'
import json, os, sys
with open(os.environ["FEED"]) as f:
    d = json.load(f)
assert isinstance(d, list), "feed is not a JSON array"
print(eval(sys.argv[1]))
PY
}

# is_valid_array - 0 if the feed parses as a JSON array, non-zero otherwise.
is_valid_array() {
    FEED="${FEED}" python3 - <<'PY'
import json, os, sys
with open(os.environ["FEED"]) as f:
    d = json.load(f)
sys.exit(0 if isinstance(d, list) else 1)
PY
}

# The default notice title is PARTY_NAME from deploy.conf, or "partyOS" when the
# key is absent or empty. Read it the same way announce.sh does, so the test holds
# whether or not an event has set a party name.
DEFAULT_TITLE="$(grep -E '^PARTY_NAME=' "${REPO_ROOT}/deploy.conf" 2>/dev/null | tail -1 | cut -d= -f2- \
    | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//")"
DEFAULT_TITLE="${DEFAULT_TITLE:-partyOS}"

echo "================ announce.sh operator broadcast test ================"

# ----------------------------------------------------------------------------
echo
echo "---- 1. fresh feed: first announce creates a valid 1-element array ----"
announce "hello" >/dev/null
assert_true "$?" "first announce exits 0"
assert_true "$(is_valid_array; echo $?)" "feed is a valid JSON array after first announce"
assert_eq "$(feed_field 'len(d)')" "1"      "feed has exactly 1 element"
assert_eq "$(feed_field 'd[0]["id"]')" "1"  "first notice id == 1"
assert_eq "$(feed_field 'd[0]["level"]')" "info" "default level == info"
assert_eq "$(feed_field 'd[0]["expires"]')" "0"  "default expires == 0 (never)"
assert_eq "$(feed_field 'd[0]["title"]')" "${DEFAULT_TITLE}" "default title == party name fallback"
assert_eq "$(feed_field 'd[0]["message"]')" "hello" "message stored verbatim"

# ----------------------------------------------------------------------------
echo
echo "---- 2. ids strictly increase and are unique ----"
announce "second" >/dev/null
announce "third"  >/dev/null
assert_eq "$(feed_field 'len(d)')" "3" "feed has 3 elements after two more announces"
assert_eq "$(feed_field 'd[1]["id"]')" "2" "second notice id == 2"
assert_eq "$(feed_field 'd[2]["id"]')" "3" "third notice id == 3"
ids_sorted_unique="$(feed_field ' all(d[i]["id"] < d[i+1]["id"] for i in range(len(d)-1)) and len({n["id"] for n in d})==len(d)')"
assert_eq "${ids_sorted_unique}" "True" "ids strictly increasing and unique"

# ----------------------------------------------------------------------------
echo
echo "---- 3. --title and --level alert honoured ----"
announce --level alert --title "Tournament" "go" >/dev/null
assert_true "$?" "announce with --level alert --title exits 0"
assert_eq "$(feed_field 'd[-1]["level"]')" "alert"      "last notice level == alert"
assert_eq "$(feed_field 'd[-1]["title"]')" "Tournament" "last notice title == Tournament"
assert_eq "$(feed_field 'd[-1]["message"]')" "go"       "last notice message == go"

# ----------------------------------------------------------------------------
echo
echo "---- 4. --expires arithmetic (expires == ts + SECONDS), absent == 0 ----"
announce --expires 3600 "timed" >/dev/null
exp_ts="$(feed_field 'd[-1]["ts"]')"
exp_exp="$(feed_field 'd[-1]["expires"]')"
delta=$(( exp_exp - exp_ts ))
assert_true "$([ "${exp_exp}" -gt "${exp_ts}" ]; echo $?)" "expires > ts when --expires given"
# allow a small clock delta between the script's date +%s and python's read (<=2s).
assert_true "$([ "${delta}" -ge 3598 ] && [ "${delta}" -le 3602 ]; echo $?)" "expires ~= ts + 3600 (delta=${delta})"
# a notice WITHOUT --expires must have expires == 0.
announce "no-expiry" >/dev/null
assert_eq "$(feed_field 'd[-1]["expires"]')" "0" "expires == 0 when --expires absent"

# ----------------------------------------------------------------------------
echo
echo "---- 5. invalid --level rejected, feed UNCHANGED ----"
before_cksum="$(cksum "${FEED}" | awk '{print $1"-"$2}')"
announce --level loud "should fail" >/dev/null 2>&1
rc=$?
assert_false "${rc}" "invalid --level loud exits non-zero"
after_cksum="$(cksum "${FEED}" | awk '{print $1"-"$2}')"
assert_eq "${after_cksum}" "${before_cksum}" "feed UNCHANGED after a rejected announce"

# ----------------------------------------------------------------------------
echo
echo "---- 6. JSON stays a valid array after every op (json.tool parse) ----"
python3 -m json.tool "${FEED}" >/dev/null 2>&1
assert_true "$?" "feed parses with python3 -m json.tool"
assert_true "$(is_valid_array; echo $?)" "feed is a JSON ARRAY"

# ----------------------------------------------------------------------------
echo
echo "---- 7. bounding: push > 55 notices, feed caps at 50, newest kept ----"
# We already have 6 notices (ids 1..6). Push enough to exceed 55 total pushes so the
# cap (50) is well crossed. Push up to id 60 (54 more): total pushed = 60.
last_id="$(feed_field 'd[-1]["id"]')"
target=60
i=$(( last_id + 1 ))
while [ "${i}" -le "${target}" ]; do
    announce "bulk-${i}" >/dev/null
    i=$(( i + 1 ))
done
assert_eq "$(feed_field 'len(d)')" "50" "feed bounded to exactly 50 notices"
assert_eq "$(feed_field 'd[-1]["id"]')" "${target}" "max id is the last pushed (${target})"
# the kept ids must be the most-recent contiguous run: 11..60 (oldest 1..10 dropped).
assert_eq "$(feed_field 'd[0]["id"]')" "11" "oldest kept id == 11 (1..10 dropped)"
contiguous="$(feed_field 'all(d[i]["id"]+1 == d[i+1]["id"] for i in range(len(d)-1))')"
assert_eq "${contiguous}" "True" "kept ids are a contiguous most-recent run"
assert_true "$(is_valid_array; echo $?)" "feed still a valid JSON array after bulk push"

# ----------------------------------------------------------------------------
echo
echo "---- 8. --clear resets the feed to [] ----"
announce --clear >/dev/null
assert_true "$?" "announce --clear exits 0"
assert_true "$(is_valid_array; echo $?)" "feed is a valid JSON array after --clear"
assert_eq "$(feed_field 'len(d)')" "0" "feed length 0 after --clear"

# ----------------------------------------------------------------------------
echo
echo "---- 9. --list runs (exit 0) and shows a pushed notice ----"
announce --title "ListCheck" "find-me-please" >/dev/null
list_out="$(announce --list)"
assert_true "$?" "announce --list exits 0"
assert_contains "${list_out}" "ListCheck"        "--list output contains the pushed title"
assert_contains "${list_out}" "find-me-please"   "--list output contains the pushed message"
# --list on an empty feed is graceful too.
announce --clear >/dev/null
empty_list="$(announce --list)"
assert_true "$?" "announce --list on empty feed exits 0"
assert_contains "${empty_list}" "no notices" "--list on empty feed says there are no notices"

# ----------------------------------------------------------------------------
echo
echo "---- 10. ts is STRICTLY monotonic: two same-second pushes get ts, ts+1 ----"
# Two back-to-back pushes land in the same wall-clock second, so a now-only ts would
# tie. The strictly-monotonic floor (max(now, max-existing-ts+1)) must still separate
# them: d[-1]["ts"] > d[-2]["ts"]. Start from a clean feed.
announce --clear >/dev/null
announce "rapid-a" >/dev/null
announce "rapid-b" >/dev/null
assert_eq "$(feed_field 'len(d)')" "2" "two rapid pushes -> 2 notices"
rapid_strict="$(feed_field 'd[-1]["ts"] > d[-2]["ts"]')"
assert_eq "${rapid_strict}" "True" "second push ts strictly > first push ts (same second)"

# ----------------------------------------------------------------------------
echo
echo "---- 11. post-clear delivery: a push after --clear still orders ahead ----"
# Capture a notice's ts as a stand-in for a client's seen-ts (PRE_TS), --clear the feed
# (which restarts ids at 1), push again, and assert the new ts > PRE_TS. This is the
# whole point of ts-keying: after a clear the new push still exceeds a prior seen-ts, so
# the client would still deliver it (an id-keyed watermark would have swallowed it).
announce --clear >/dev/null
announce "pre-clear" >/dev/null
PRE_TS="$(feed_field 'd[-1]["ts"]')"
announce --clear >/dev/null
assert_eq "$(feed_field 'len(d)')" "0" "feed empty after --clear"
# --clear empties the feed, so the monotonic floor (max-existing-ts) resets to 0; the
# next push therefore stamps wall-clock now. Wait one full second so now strictly
# exceeds PRE_TS - this models the real scenario (a client saw a notice, time passed,
# the operator cleared and re-pushed). Without the wait both could land in one second.
sleep 1
announce "post-clear" >/dev/null
assert_eq "$(feed_field 'd[-1]["id"]')" "1" "id restarts at 1 after --clear (id keying would lose this)"
POST_TS="$(feed_field 'd[-1]["ts"]')"
assert_true "$([ "${POST_TS}" -gt "${PRE_TS}" ]; echo $?)" "post-clear ts (${POST_TS}) strictly > prior seen-ts (${PRE_TS})"

# ----------------------------------------------------------------------------
echo
echo "---- 12. poller show-rule (ts-keyed) delivers a post-clear notice ----"
# A self-contained mirror of the poller's pure show-decision (build-custom-image.sh's
# parse_feed): given a feed + a client's seen-ts, which ts get shown? Proves ts-keying
# delivers a realistic post-clear push (where the new ts is well above any old seen-ts).
show_rule_ok="$(python3 - <<'PY'
def shown_ts(feed, seents, now=10**12):
    out = []
    for n in feed:
        try:
            ts = int(n.get("ts"))
        except (TypeError, ValueError):
            continue
        exp = int(n.get("expires", 0))
        expired = (exp != 0 and exp <= now)
        if ts > seents and not expired:
            out.append(ts)
    return sorted(out)

ok = True
# normal: a newer ts than seen is shown.
ok &= shown_ts([{"ts": 100}], 50) == [100]
# post-clear realistic: announce stamps now-unix (>> any old seen-ts), so the new push
# is still > seen and IS delivered even though ids restarted.
ok &= shown_ts([{"ts": 200}], 150) == [200]
# already-seen (ts <= seen) is NOT shown.
ok &= shown_ts([{"ts": 40}], 50) == []
# expired notice (exp in the past) is suppressed even if ts > seen.
ok &= shown_ts([{"ts": 100, "expires": 5}], 50, now=10) == []
print("True" if ok else "False")
PY
)"
assert_eq "${show_rule_ok}" "True" "ts-keyed show-rule: post-clear delivered, seen/expired suppressed"

# ----------------------------------------------------------------------------
echo
echo "---- live feed untouched guard ----"
LIVE_AFTER="absent"
[ -e "${LIVE_FEED}" ] && LIVE_AFTER="$(cksum "${LIVE_FEED}" | awk '{print $1"-"$2}')"
assert_eq "${LIVE_AFTER}" "${LIVE_BEFORE}" "live server/notices.json untouched by the test"

assert_summary "test-announce" || exit 1
echo "test-announce: ALL PASS"
