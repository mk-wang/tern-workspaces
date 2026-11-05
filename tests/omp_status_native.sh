#!/usr/bin/env bash
# ponytail: one isolated native check; the absolute-path TSP stand-in never calls a model.
# Covers Working, unread Finished, cross-session status, isolation, stop cleanup and status-first ordering.
# Waiting is not exercised: Tern derives waiting_input internally, not from a replayable TSP field.
# Run: bash tests/omp_status_native.sh [PATH_TO_TERN]. KEEP=1 preserves captures, not processes.
set -euo pipefail

TERN="${1:-/Applications/Tern.app/Contents/MacOS/tern}"
REPO="${REPO:-$(cd "$(dirname "$0")/.." && pwd)}"
WORK="$(mktemp -d /tmp/tern-omp-status-reg.XXXXXX)"
WIN_PID=""
cleanup() {
  if [ -n "$WIN_PID" ]; then
    kill "$WIN_PID" 2>/dev/null || true
    wait "$WIN_PID" 2>/dev/null || true
  fi
  # Only processes whose command contains this unique disposable directory.
  pkill -f "${WORK//./[.]}/" 2>/dev/null || true
  if [ "${KEEP:-0}" != 1 ]; then rm -rf "$WORK"; fi
}
trap cleanup EXIT

mkdir -p "$WORK/config/plugins" "$WORK/home" "$WORK/proj-a" "$WORK/proj-b" "$WORK/shots" "$WORK/fake"
printf '%s\n' "$REPO" > "$WORK/config/plugins/workspaces.path"
mkdir -p "$WORK/home/.omp/agent/sessions/native"
CHILD="$(cd "$WORK/home/.omp/agent/sessions/native" && pwd -P)/child.jsonl"
cat > "$CHILD" <<EOF
{"type":"session","id":"11111111-1111-4111-8111-111111111111","cwd":"$WORK/proj-a","title":"Active child chat"}
EOF
cat > "$WORK/fake/fake1.jsonl" <<'EOF'
{"t":0,"dir":"out","verb":"q","body":{"q":"hello","v":[1],"app":"omp","ver":"playback","features":["send","scroll"]}}
{"t":5,"dir":"out","verb":"o","body":{"id":"main","mode":"inline","title":"omp","role":"omp.session"}}
{"t":6,"dir":"out","verb":"f","body":{"sf":"main","s":1,"ops":[["add","t1","main",null,{"id":"t1","k":"text","p":{"text":"Fake omp ready"}}],["add","in1","main",null,{"id":"in1","k":"input","p":{"sendable":true,"placeholder":"Ask fake omp"}}],["focus","in1"]]}}
EOF
cat > "$WORK/fake/omp" <<PYEOF
#!/usr/bin/env python3
import sys, time, json
R = "$WORK/fake"
def emit(name):
    for line in open(f"{R}/{name}.jsonl"):
        line = line.strip()
        if not line: continue
        m = json.loads(line)
        if m.get("dir") != "out": continue
        body = m["body"]
        if not isinstance(body, str): body = json.dumps(body, separators=(",", ":"))
        params = m.get("params") or {}
        p = "".join(";%s=%s" % (k, v) for k, v in params.items())
        sys.stdout.write("\\x1b_tsp;%s%s;%s\\x1b\\\\" % (m["verb"], p, body))
    sys.stdout.flush()
sys.stdout.write("\\033]2;omp\\007\\033[?25l"); sys.stdout.flush()
emit("fake1")
time.sleep(float(sys.argv[1] if len(sys.argv) > 1 else 0))
if len(sys.argv) > 2 and sys.argv[2] == "bell":
    sys.stdout.write("\\a"); sys.stdout.flush()
time.sleep(600)
PYEOF
chmod +x "$WORK/fake/omp"
FAKE="$WORK/fake/omp"

unset TERN_ACP TERN_BLOB_DIR TERN_COMPLETE TERN_EXE TERN_IDENTITY TERN_LENSES TERN_PANE TERN_PANE_SOCKET TERN_WINDOW_KEY TERN_WINDOW_SOCKET
export HOME="$WORK/home" TERN_CONFIG_DIR="$WORK/config" TERN_DAEMON_SOCKET="$WORK/daemon.sock"
export OMP_PROFILE="" XDG_DATA_HOME="$HOME/.local/share" PI_CODING_AGENT_DIR="$HOME/.omp/agent" PI_CODING_AGENT_SESSION_DIR="$HOME/.omp/agent/sessions"
export CODEX_HOME="$HOME/.codex" CLAUDE_CONFIG_DIR="$HOME/.claude"
cd "$WORK/proj-a"
"$TERN" --control "$WORK/win.sock" --out "$WORK/shots" &
WIN_PID=$!

ctl() { "$TERN" ctl --control "$WORK/win.sock" "$@"; }
# Local Lua evaluation, never carly ask.
lua() { ctl "carly lua $1" >/dev/null 2>&1; }
wait_for() {
  local tries=$(( $1 * 2 )); shift
  for _ in $(seq "$tries"); do
    ctl tree 2>/dev/null | grep -q "$1" && return 0
    sleep 0.5
  done
  return 1
}
gone() { ! ctl tree 2>/dev/null | grep -q "$1"; }
fail() { echo "FAIL: $1"; exit 1; }
pass() { echo "PASS: $1"; }
assert_project_order() {
  local last=""
  for _ in $(seq 20); do
    if last="$(ctl tree | python3 -c '
import json, sys
def names(node):
    if isinstance(node, list):
        for child in node: yield from names(child)
    elif isinstance(node, dict):
        if node.get("text") in ("proj-a", "proj-b") and "sf-t-strong" in (node.get("class") or "").split():
            yield node["text"]
        yield from names(node.get("children") or [])
order = list(names(json.load(sys.stdin)["tree"]))
assert order == sys.argv[1:], f"Unexpected project order: {order}, expected {sys.argv[1:]}"
' "$@" 2>&1)"; then return 0; fi
    sleep 0.5
  done
  fail "$last"
}

for _ in $(seq 40); do ctl tree >/dev/null 2>&1 && break; sleep 0.5; done
wait_for 20 'Workspaces' || fail "sidebar did not mount"
pass "plugin loads; sidebar mounted"

ok=0
for _ in 1 2 3; do
  lua "cx:open('workspaces://open?path=$WORK/proj-a')"
  wait_for 8 'proj-a' && ok=1 && break
done
[ "$ok" = 1 ] || fail "workspace session not opened"
lua "cx:open('workspaces://add_current')"
sleep 1
grep -q "proj-a" "$WORK/config/plugin-data/workspaces/kv.json" 2>/dev/null \
  || fail "workspace record not persisted"
pass "workspace opened, bound session created, record persisted"

# A pending prompt makes Tern report working; only the absolute fake executable is launched.
lua "cx.agents:start({prompt='regression', cwd='$WORK/proj-a', command='$FAKE', how='tab'})"
wait_for 15 'OMP: Working' || fail "no working status in bound session"
pass "Working indicator for pending-prompt agent in bound session"

lua "cx.sessions:create({name='unbound', cwd='$WORK'})"
sleep 1
lua "cx.agents:start({prompt='leak', cwd='$WORK', command='$FAKE', how='tab'})"
sleep 3
gone 'OMP: Working 2' || fail "unbound-session agent counted"
pass "no leakage from unbound session"

lua "cx:open('workspaces://open?path=$WORK/proj-a')"
for _ in $(seq 20); do
  ctl state 2>/dev/null | grep -q '"name":"proj-a","tabs":[0-9]*,"current":true' && break
  sleep 0.5
done
ctl state 2>/dev/null | grep -q '"name":"proj-a","tabs":[0-9]*,"current":true' \
  || fail "did not return to bound proj-a session"
pass "returned to bound proj-a session"

# No queued prompt: this agent is idle. Its bell arrives while another session is shown.
lua "cx.layout:new_tab({cwd='$WORK/proj-a', command='$FAKE 2 bell'})"
sleep 0.5
lua "cx:open('workspaces://open?path=$WORK/proj-b')"
wait_for 15 'OMP: Finished' || fail "no finished status for background idle agent with unseen alert"
wait_for 10 'OMP: Working' || fail "proj-a working status lost after switching to proj-b"
pass "background counts and foreign-pane alert survive session switch"
ctl shot cross-session-final >/dev/null 2>&1

ctl click '[data-surface="plugin.workspaces.sidebar"] [data-role="workspaces-project-name"]' >/dev/null
for _ in $(seq 20); do
  ctl state 2>/dev/null | grep -q '"name":"proj-a","tabs":[0-9]*,"current":true' && break
  sleep 0.5
done
ctl state 2>/dev/null | grep -q '"name":"proj-a","tabs":[0-9]*,"current":true' \
  || fail "project title click did not restore its session"
pass "project title click restores its session"

lua "local a=cx.agents:list(); for _,x in ipairs(a) do if x.state=='working' then pcall(cx.agents.stop, cx.agents, x.pane) end end"
sleep 3
gone 'OMP: Working' || fail "working status survived agent stop"
pass "Working indicator cleared on agent stop"

# Clear the stopped project's unread alerts before making the later project active.
lua "for _,p in ipairs(cx.session:panes()) do if p.block~='workspaces.sidebar' then cx.layout:focus(p.pane) end end"
sleep 1
gone 'OMP: Finished' || fail "idle project still has an unread alert"
lua "cx:open('workspaces://open?path=$WORK/proj-b')"
sleep 1
lua "cx:open('workspaces://add_current')"
lua "cx.agents:start({prompt='partition', cwd='$WORK/proj-b', command='$FAKE', how='tab'})"
wait_for 15 'OMP: Working' || fail "later project did not become active"
assert_project_order proj-b proj-a
pass "later active project moves ahead of earlier idle project"

# Child-only activity belongs in With Status even when its bound session is idle.
lua "for _,p in ipairs(cx.session:panes()) do if p.block=='workspaces.sidebar' then cx.session:event(p.pane,{ev='action',act='refresh'}) end end"
wait_for 10 'Active child chat' || fail "child chat fixture did not load"
lua "local s={workspaces={['$WORK/proj-b']={working=1}},sessions={['$CHILD']={working=1}}}; for _,p in ipairs(cx.session:panes()) do if p.block=='workspaces.sidebar' then cx.session:event(p.pane,{ev='action',act='omp_status',text=tern.json.encode(s)}) end end"
wait_for 10 'OMP: Working' || fail "child-only activity did not render"
assert_project_order proj-a proj-b
lua "local s={workspaces={['$WORK/proj-b']={working=1}},sessions={}}; for _,p in ipairs(cx.session:panes()) do if p.block=='workspaces.sidebar' then cx.session:event(p.pane,{ev='action',act='omp_status',text=tern.json.encode(s)}) end end"
assert_project_order proj-b proj-a
pass "child-only activity changes its project's section without changing its session"
echo "OMP status regression: all checks passed"
