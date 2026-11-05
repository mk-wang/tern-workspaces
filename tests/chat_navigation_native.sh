#!/usr/bin/env bash
# ponytail: one isolated native journey; the fake shell never executes omp or a model.
# Run: bash tests/chat_navigation_native.sh [PATH_TO_TERN] [normal|failure]
set -uo pipefail
TERN="${1:-/Applications/Tern.app/Contents/MacOS/tern}"
REPO="${REPO:-$(cd "$(dirname "$0")/.." && pwd)}"
MODE="${2:-normal}"
case "$MODE" in normal|failure) ;; *) echo "Expected normal or failure"; exit 2;; esac
WORK="$(mktemp -d /tmp/tern-click-${MODE}.XXXXXX)"
PID=""
cleanup() {
  if [ -n "$PID" ]; then kill "$PID" 2>/dev/null || true; wait "$PID" 2>/dev/null || true; fi
  pkill -f "${WORK//./[.]}/" 2>/dev/null || true
  if [ "${KEEP:-0}" != 1 ]; then rm -rf "$WORK"; fi
}
trap cleanup EXIT
mkdir -p "$WORK/config/plugins" "$WORK/config/plugin-data/workspaces" "$WORK/home" "$WORK/proj" "$WORK/fake" "$WORK/shots"
printf '%s\n' "$REPO" > "$WORK/config/plugins/workspaces.path"
cat > "$WORK/fake/shell" <<EOS
#!/usr/bin/env bash
case "\$*" in
  *"/usr/bin/env"*) printf 'PATH=/usr/bin:/bin:/usr/sbin:/sbin\n'; exit 0;;
esac
printf '%s\n' "\$*" >> "$WORK/fake.log"
exec sleep 600
EOS
chmod +x "$WORK/fake/shell"
cat > "$WORK/config/plugin-data/workspaces/kv.json" <<EOF
{"workspaces":[{"icon":"folder","name":"proj","path":"$WORK/proj"}],"sidebar_enabled:2":true,"workspace_sessions:2":{}}
EOF
unset TERN_ACP TERN_BLOB_DIR TERN_COMPLETE TERN_EXE TERN_IDENTITY TERN_LENSES TERN_PANE TERN_PANE_SOCKET TERN_WINDOW_KEY TERN_WINDOW_SOCKET TERN_WORKSPACE XDG_DATA_HOME PI_CODING_AGENT_DIR PI_CODING_AGENT_SESSION_DIR CODEX_HOME CLAUDE_CONFIG_DIR OMP_PROFILE PI_PROFILE
export HOME="$WORK/home" TERN_CONFIG_DIR="$WORK/config" TERN_DAEMON_SOCKET="$WORK/daemon.sock" SHELL="$WORK/fake/shell"
[ "$MODE" = failure ] && export TERN_EXE=/nonexistent-tern
cd "$WORK/proj"
"$TERN" --control "$WORK/win.sock" --out "$WORK/shots" >/dev/null 2>&1 & PID=$!
ctl() { "$TERN" ctl --control "$WORK/win.sock" "$@"; }
lua() { ctl "carly lua $1" >/dev/null 2>&1; }
wait_for() { local t=$(( $1 * 2 )); shift; for _ in $(seq "$t"); do ctl tree 2>/dev/null | grep -q "$1" && return 0; sleep 0.5; done; return 1; }
fail() { echo "FAIL[$MODE]: $1"; exit 1; }
pass() { echo "PASS[$MODE]: $1"; }
logcount() { if [ -f "$WORK/fake.log" ]; then grep -c 'omp --resume ' "$WORK/fake.log" || true; else printf '0\n'; fi; }
tabcount() { ctl state 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); print(sum(s.get("tabs",0) for s in d.get("sessions",[])))'; }
clicktext() { python3 - "$WORK/tree.json" "$1" <<'PY'
import json, sys
t = json.load(open(sys.argv[1]))["tree"]
def walk(node):
    if isinstance(node, list):
        for child in node:
            if walk(child): return True
    elif isinstance(node, dict):
        if node.get("text") == sys.argv[2] and "sf" in (node.get("class") or ""):
            x, y, width, height = node["rect"]
            print(x + width / 2, y + height / 2)
            return True
        return walk(node.get("children") or [])
    return False
walk(t)
PY
}
clickrow() { ctl tree > "$WORK/tree.json"; local xy; xy=$(clicktext "$1"); [ -n "$xy" ] || fail "row missing: $1"; ctl click $xy >/dev/null; }
SESS="$WORK/home/.omp/agent/sessions/${WORK//\//-}-proj"
mkdir -p "$SESS"
R=aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa; C=bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb
F=cccccccc-cccc-4ccc-8ccc-cccccccccccc; G=dddddddd-dddd-4ddd-8ddd-dddddddddddd
RF="$SESS/2026-11-01T10-00-00-000Z_$R.jsonl"; CF="$SESS/2026-11-04T10-00-00-000Z_$C.jsonl"
FF="$SESS/2026-11-02T10-00-00-000Z_$F.jsonl"; GF="$SESS/2026-11-05T10-00-00-000Z_$G.jsonl"
for _ in $(seq 60); do ctl tree >/dev/null 2>&1 && break; sleep 0.5; done
ctl size 1280 1700 >/dev/null 2>&1 || true
printf '%s\n%s\n' '{"type":"title","v":1,"title":"CHAIN CHAT"}' "{\"type\":\"session\",\"version\":3,\"id\":\"$R\",\"cwd\":\"$WORK/proj\"}" > "$RF"
printf '%s\n%s\n' '{"type":"title","v":1,"title":"CHAIN CHAT"}' "{\"type\":\"session\",\"version\":3,\"id\":\"$C\",\"cwd\":\"$WORK/proj\",\"continuationOf\":\"$R\"}" > "$CF"
printf '%s\n%s\n' '{"type":"title","v":1,"title":"ABSENT CHAT"}' "{\"type\":\"session\",\"version\":3,\"id\":\"$F\",\"cwd\":\"$WORK/proj\"}" > "$FF"
touch -t 202611011000 "$RF"; touch -t 202611041000 "$CF"; touch -t 202611021000 "$FF"
"$TERN" plugin reload workspaces --json >/dev/null 2>&1 || fail "plugin reload"
wait_for 20 'CHAIN CHAT' || fail "sidebar rows did not appear"
if [ "$MODE" = failure ]; then
  ctl key Escape >/dev/null 2>&1 || true
  T0=$(tabcount); L0=$(logcount)
  clickrow 'ABSENT CHAT'; sleep 1.5
  T1=$(tabcount); L1=$(logcount)
  [ "$T1" = "$T0" ] && [ "$L1" = "$L0" ] || fail "inspection failure opened a tab or launched a resume"
  pass "inspection failure leaves tabs and launches unchanged"
  exit 0
fi
# A leaf history row must focus its already-open ancestor, even in another session.
lua "local s=cx.sessions:create({name='B',cwd='$WORK/proj'}); cx.layout:new_tab({cwd='$WORK/proj',command='omp --resume $RF'}); tern.fs.write('$WORK/existing.json',tern.json.encode({session=s.id,pane=cx.session:focused()}))"
sleep 0.8
lua "cx.sessions:switch('Default')"; sleep 0.5
ctl key Escape >/dev/null 2>&1 || true
T0=$(tabcount); L0=$(logcount)
clickrow 'CHAIN CHAT'; sleep 1.2
lua "local e=tern.json.decode(tern.fs.read('$WORK/existing.json')); tern.fs.write('$WORK/after_chain.json',tern.json.encode({current=cx.sessions:current().id,focused=cx.session:focused(),want_session=e.session,want_pane=e.pane}))"
python3 - "$WORK/after_chain.json" <<'PY' || fail "wrong chain pane focused"
import json, sys
state = json.load(open(sys.argv[1]))
assert state["current"] == state["want_session"] and state["focused"] == state["want_pane"], state
PY
[ "$(tabcount)" = "$T0" ] && [ "$(logcount)" = "$L0" ] || fail "focusing existing chat created a tab or process"
pass "continuation row focuses its existing ancestor across sessions without a new tab"
lua "cx.sessions:switch('Default')"; sleep 0.4
T0=$(tabcount); L0=$(logcount)
clickrow 'ABSENT CHAT'; sleep 2
T1=$(tabcount); L1=$(logcount)
[ "$T1" -gt "$T0" ] && [ "$((L1-L0))" = 1 ] || fail "absent chat did not launch exactly one resume"
pass "absent chat launches one resume"
lua "cx.layout:close(cx.session:focused())"; sleep 0.5
T0=$(tabcount); L0=$(logcount)
clickrow 'ABSENT CHAT'; sleep 2
[ "$(( $(tabcount)-T0 ))" = 1 ] && [ "$(( $(logcount)-L0 ))" = 1 ] || fail "closed chat did not launch exactly one resume"
pass "closed chat resumes once"
rm -f "$RF" "$CF"
printf '%s\n%s\n' '{"type":"title","v":1,"title":"RAPID CHAT"}' "{\"type\":\"session\",\"version\":3,\"id\":\"$G\",\"cwd\":\"$WORK/proj\"}" > "$GF"
touch -t 202611051000 "$GF"
"$TERN" plugin reload workspaces --json >/dev/null 2>&1 || fail "plugin reload after history change"
wait_for 20 'RAPID CHAT' || fail "rapid-click row missing"
lua "cx.sessions:switch('Default')"; sleep 0.3
T0=$(tabcount); L0=$(logcount)
ctl tree > "$WORK/tree.json"; XY=$(clicktext 'RAPID CHAT'); [ -n "$XY" ] || fail "rapid-click row not clickable"
ctl dblclick $XY >/dev/null; sleep 2.5
[ "$(( $(tabcount)-T0 ))" = 1 ] && [ "$(( $(logcount)-L0 ))" = 1 ] || fail "rapid clicks duplicated the tab or resume"
pass "rapid clicks produce one tab and one resume"
