#!/usr/bin/env bash
# ponytail: one isolated native journey; the fake shell never launches omp or a model.
# Pins are clicked at their real coordinates; assertions read the live element tree.
# Run: bash tests/pinning_native.sh [PATH_TO_TERN]. KEEP=1 keeps the disposable fixture.
set -uo pipefail

TERN="${1:-/Applications/Tern.app/Contents/MacOS/tern}"
REPO="${REPO:-$(cd "$(dirname "$0")/.." && pwd)}"
WORK="$(mktemp -d /tmp/tern-pinning-reg.XXXXXX)"
E="$WORK/evidence"
CHECK=""
PID=""
cleanup() {
  if [ -n "$PID" ]; then kill "$PID" 2>/dev/null || true; wait "$PID" 2>/dev/null || true; fi
  # Only processes whose command contains this unique disposable directory.
  pkill -f "${WORK//./[.]}/" 2>/dev/null || true
  [ -n "$CHECK" ] && rm -rf "$CHECK"
  [ "${KEEP:-0}" = 1 ] || rm -rf "$WORK"
  return 0
}
trap cleanup EXIT

mkdir -p "$WORK/config/plugins" "$WORK/config/plugin-data/workspaces" "$WORK/home" \
  "$WORK/proj-long" "$WORK/proj-idle" "$WORK/proj-active" "$WORK/shots" "$WORK/fake" "$E"
touch "$WORK/config/welcomed"
printf '%s\n' "$REPO" > "$WORK/config/plugins/workspaces.path"

LONG="long-name-project-alpha-beta-gamma-delta-epsilon-zeta-eta-theta-iota-kappa"
cat > "$WORK/fake/shell" <<EOS
#!/usr/bin/env bash
case "\$*" in
  *"/usr/bin/env"*) printf 'PATH=/usr/bin:/bin:/usr/sbin:/sbin\n'; exit 0;;
esac
exec sleep 600
EOS
chmod +x "$WORK/fake/shell"

# Saved order is long, idle, active: a pin must keep that relative order, not click order.
cat > "$WORK/config/plugin-data/workspaces/kv.json" <<EOF
{"workspaces":[{"icon":"folder","name":"$LONG","path":"$WORK/proj-long"},{"icon":"folder","name":"alpha-idle","path":"$WORK/proj-idle"},{"icon":"folder","name":"bravo-active","path":"$WORK/proj-active"}],"workspace_sessions:2":{}}
EOF

unset TERN_ACP TERN_BLOB_DIR TERN_COMPLETE TERN_EXE TERN_IDENTITY TERN_LENSES TERN_PANE TERN_PANE_SOCKET TERN_WINDOW_KEY TERN_WINDOW_SOCKET TERN_WORKSPACE XDG_DATA_HOME PI_CODING_AGENT_DIR PI_CODING_AGENT_SESSION_DIR CODEX_HOME CLAUDE_CONFIG_DIR OMP_PROFILE PI_PROFILE
export HOME="$WORK/home" TERN_CONFIG_DIR="$WORK/config" TERN_DAEMON_SOCKET="$WORK/daemon.sock" SHELL="$WORK/fake/shell"
cd "$WORK/proj-idle"

cat > "$WORK/probe.py" <<'PY'
import json, sys

def sel(path):
    d = json.load(open(path))
    if not d.get("ok"): raise SystemExit("ctl failed: " + path)
    return d["nodes"]

def rows(path):
    out = []
    for n in sel(path):
        text = n.get("text") or ""
        out.append({"name": text.split("📁 ", 1)[1] if "📁 " in text else text,
                    "path": n.get("title"), "y": n["rect"][1], "x": n["rect"][0]})
    return sorted(out, key=lambda r: r["y"])

def heads(path):
    out = []
    for n in sel(path):
        text = n.get("text") or ""
        for label in ("With Status", "No Status", "Stick"):
            if text.startswith(label) and text[len(label):].isdigit():
                out.append({"label": label, "count": int(text[len(label):]),
                            "y": n["rect"][1], "x": n["rect"][0],
                            "w": n["rect"][2], "h": n["rect"][3]})
                break
    return sorted(out, key=lambda h: h["y"])

def near(rs, y):
    best = min(rs, key=lambda r: abs(r["y"] - y)) if rs else None
    return best if best and abs(best["y"] - y) <= 40 else None

cmd = sys.argv[1]
if cmd == "outline":
    hs, rs, marks = heads(sys.argv[3]), rows(sys.argv[4]), sel(sys.argv[5])
    for h in hs:
        print(f'{h["label"]} {h["count"]}')
        later = [x["y"] for x in hs if x["y"] > h["y"]]
        stop = min(later) if later else float("inf")
        for r in rs:
            if h["y"] <= r["y"] < stop:
                busy = any(abs(m["rect"][1] - r["y"]) <= 40 for m in marks)
                print(r["name"] + (" (working)" if busy else ""))
elif cmd == "pin_xy":
    rs = rows(sys.argv[3])
    for n in sel(sys.argv[2]):
        r = near(rs, n["rect"][1])
        if r and (r["path"] == sys.argv[4] or r["name"] == sys.argv[4]):
            x, y, w, h = n["rect"]
            print(x + w / 2, y + h / 2)
            break
    else:
        raise SystemExit("pin not found: " + sys.argv[4])
elif cmd == "pin_x":
    rs = rows(sys.argv[3])
    for n in sel(sys.argv[2]):
        r = near(rs, n["rect"][1])
        if r and (r["path"] == sys.argv[4] or r["name"] == sys.argv[4]):
            print(round(n["rect"][0], 1))
            break
    else:
        raise SystemExit("pin not found: " + sys.argv[4])
elif cmd == "head_xy":
    for h in heads(sys.argv[2]):
        if h["label"] == sys.argv[3]:
            print(h["x"] + h["w"] / 2, h["y"] + h["h"] / 2)
            break
    else:
        raise SystemExit("section not found: " + sys.argv[3])
elif cmd == "kv":
    for r in json.load(open(sys.argv[2])).get("workspaces", []):
        print(f'{r["name"]}|{r["path"]}|{r.get("icon")}|{"true" if r.get("pinned") else "false"}')
else:
    raise SystemExit("unknown command " + cmd)
PY

ctl() { "$TERN" ctl --control "$WORK/win.sock" "$@"; }
lua() { ctl "carly lua $1" >/dev/null 2>&1; }
fail() { echo "FAIL: $1"; ctl tree > "$E/tree-fail.json" 2>/dev/null; exit 1; }
pass() { echo "PASS: $1"; }

"$TERN" --control "$WORK/win.sock" --out "$WORK/shots" >"$WORK/window.log" 2>&1 &
PID=$!
for _ in $(seq 60); do ctl tree >/dev/null 2>&1 && break; sleep 0.5; done
ctl size 1280 1700 >/dev/null 2>&1 || true

# pipefail + grep -q would turn an early match into SIGPIPE: write, then search.
has() { ctl tree > "$WORK/live.json" 2>/dev/null && grep -qF "$1" "$WORK/live.json"; }
wait_for() {
  local t=$(( $1 * 4 )); shift
  for _ in $(seq "$t"); do has "$1" && return 0; sleep 0.25; done
  return 1
}

# The one shape assertion: section headers+counts, their rows in saved order, working markers.
expect_outline() {
  local want out
  want="$(cat)"
  for _ in $(seq 40); do
    ctl tree > "$WORK/tree.json"
    ctl tree '[data-role="workspaces-section-heading"]' > "$WORK/heads.json"
    ctl tree '[data-role="workspaces-project-name"]' > "$WORK/names.json"
    ctl tree '[data-role="workspaces-status-working"]' > "$WORK/marks.json"
    out=$(python3 "$WORK/probe.py" outline "$WORK/tree.json" "$WORK/heads.json" "$WORK/names.json" "$WORK/marks.json" 2>/dev/null)
    [ "$out" = "$want" ] && return 0
    sleep 0.25
  done
  echo "--- want:"; printf '%s\n' "$want"
  echo "--- got:";  printf '%s\n' "$out"
  fail "section outline mismatch"
}

click_head() {
  local xy
  ctl tree '[data-role="workspaces-section-heading"]' > "$WORK/heads.json"
  xy=$(python3 "$WORK/probe.py" head_xy "$WORK/heads.json" "$1") || fail "section header missing: $1"
  ctl click $xy >/dev/null || fail "click failed: $1 header"
  sleep 0.5
}

click_pin() {
  local xy
  local scope=""
  [ -n "${2:-}" ] && scope="[data-id=\"main.section:$2\"] "
  ctl tree "${scope}[data-role=\"workspaces-pin\"]" > "$WORK/pins.json"
  ctl tree "${scope}[data-role=\"workspaces-project-name\"]" > "$WORK/names.json"
  xy=$(python3 "$WORK/probe.py" pin_xy "$WORK/pins.json" "$WORK/names.json" "$1") || fail "pin missing: $1"
  ctl click $xy >/dev/null || fail "click failed: $1 pin"
  sleep 0.6
}

omp_status() {
  lua "local s={workspaces={['$1']={working=1}},sessions={}}; for _,p in ipairs(cx.session:panes()) do if p.block=='workspaces.sidebar' then cx.session:event(p.pane,{ev='action',act='omp_status',text=tern.json.encode(s)}) end end"
}

# The fixture must never reach a real user window, HOME or daemon.
case "$WORK" in /tmp/tern-pinning-reg.*) ;; *) fail "fixture is not disposable";; esac
wait_for 20 'Workspaces' || fail "sidebar did not mount"

# One project is active through the same synthetic payload the OMP status regression uses.
omp_status "$WORK/proj-active"
wait_for 15 'With Status' || fail "synthetic status did not render"

# Stick exists at zero; every present section starts expanded.
expect_outline <<EOF
Stick 0
With Status 1
bravo-active (working)
No Status 2
$LONG
alpha-idle
EOF
pass "Stick exists at zero and all three sections start expanded"

# Long names must not push the pin out of the row: every pin shares the row's right edge.
ctl tree '[data-role="workspaces-pin"]' > "$WORK/pins.json"
ctl tree '[data-role="workspaces-project-name"]' > "$WORK/names.json"
grep -qF "$LONG" "$WORK/names.json" || fail "long name is not rendered in full"
X1=$(python3 "$WORK/probe.py" pin_x "$WORK/pins.json" "$WORK/names.json" "$WORK/proj-long")
X2=$(python3 "$WORK/probe.py" pin_x "$WORK/pins.json" "$WORK/names.json" "$WORK/proj-active")
[ "$X1" = "$X2" ] || fail "long project name moved its pin (x $X1 vs $X2)"
pass "long project name keeps the same pin position as a short one"

# Actual click on the idle project's pin.
click_pin "$WORK/proj-idle"
expect_outline <<EOF
Stick 1
alpha-idle
With Status 1
bravo-active (working)
No Status 1
$LONG
EOF
pass "clicking Pin moves the idle project into Stick exactly once"

# Real header clicks: a collapsed section keeps its header and count, and hides its rows.
click_head 'Stick'
expect_outline <<EOF
Stick 1
With Status 1
bravo-active (working)
No Status 1
$LONG
EOF
pass "collapsed Stick hides rows and keeps its header count"
click_head 'Stick'
expect_outline <<EOF
Stick 1
alpha-idle
With Status 1
bravo-active (working)
No Status 1
$LONG
EOF
pass "reopened Stick restores its row"

click_head 'With Status'
expect_outline <<EOF
Stick 1
alpha-idle
With Status 1
No Status 1
$LONG
EOF
click_head 'With Status'
expect_outline <<EOF
Stick 1
alpha-idle
With Status 1
bravo-active (working)
No Status 1
$LONG
EOF
pass "With Status collapses and reopens"

# Pin the active project: Stick keeps saved order (idle before active), indicator retained.
click_pin "$WORK/proj-active"
expect_outline <<EOF
Stick 2
alpha-idle
bravo-active (working)
With Status 1
bravo-active (working)
No Status 1
$LONG
EOF
pass "pinned active project appears in Stick and With Status with both OMP indicators"

# The two copies have separate view state but one saved pin state.
click_head 'Stick'
expect_outline <<EOF
Stick 2
With Status 1
bravo-active (working)
No Status 1
$LONG
EOF
click_head 'Stick'
expect_outline <<EOF
Stick 2
alpha-idle
bravo-active (working)
With Status 1
bravo-active (working)
No Status 1
$LONG
EOF
pass "collapsing Stick leaves the active duplicate visible in With Status"
ctl shot pinning-overlap >/dev/null 2>&1 || fail "overlapping sections capture failed"
cp "$WORK/tree.json" "$E/tree-overlap.json"
python3 "$WORK/probe.py" outline "$WORK/tree.json" "$WORK/heads.json" "$WORK/names.json" "$WORK/marks.json" > "$E/outline-overlap.txt"

# Unpin from the With Status copy: only the Stick membership disappears.
click_pin "$WORK/proj-active" status
expect_outline <<EOF
Stick 1
alpha-idle
With Status 1
bravo-active (working)
No Status 1
$LONG
EOF
cp "$WORK/tree.json" "$E/tree-active-unpin.json"
python3 "$WORK/probe.py" outline "$WORK/tree.json" "$WORK/heads.json" "$WORK/names.json" "$WORK/marks.json" > "$E/outline-active-unpin.txt"
pass "unpinning the status copy removes Stick membership and retains the active row"

# Re-pin to keep the persisted bravo case covered.
click_pin "$WORK/proj-active"
expect_outline <<EOF
Stick 2
alpha-idle
bravo-active (working)
With Status 1
bravo-active (working)
No Status 1
$LONG
EOF

# Unpin the idle project: it returns to its saved place in No Status.
click_pin "$WORK/proj-idle"
expect_outline <<EOF
Stick 1
bravo-active (working)
With Status 1
bravo-active (working)
No Status 2
$LONG
alpha-idle
EOF
pass "clicking Unpin returns the idle project to its saved place in No Status"

# A status refresh and a tab transfer must not expand a collapsed section.
click_head 'No Status'
expect_outline <<EOF
Stick 1
bravo-active (working)
With Status 1
bravo-active (working)
No Status 2
EOF
omp_status "$WORK/proj-active"
sleep 1
expect_outline <<EOF
Stick 1
bravo-active (working)
With Status 1
bravo-active (working)
No Status 2
EOF
ctl key Meta+t >/dev/null || fail "could not open a second tab"
sleep 1
has 'Workspaces' || fail "sidebar did not transfer to the new tab"
has "$LONG" && fail "tab transfer expanded No Status"
ctl tree '[data-role="workspaces-section-heading"]' > "$WORK/heads-live.json"
grep -qF 'No Status' "$WORK/heads-live.json" || fail "collapsed header lost on tab transfer"
pass "collapsed state survives a status refresh and a tab transfer"

# A moved pane has fresh block state: restore the synthetic status, then reopen.
omp_status "$WORK/proj-active"
sleep 1
click_head 'No Status'
expect_outline <<EOF
Stick 1
bravo-active (working)
With Status 1
bravo-active (working)
No Status 2
$LONG
alpha-idle
EOF
pass "reopened No Status restores its rows"

# Reload must not lose or reorder pins (synthetic status lives in memory only).
"$TERN" plugin reload workspaces --json > "$E/plugin-reload.json" 2>&1 || fail "plugin reload failed"
wait_for 15 'Stick' || fail "sidebar missing after reload"
expect_outline <<EOF
Stick 1
bravo-active
No Status 2
$LONG
alpha-idle
EOF
pass "pins survive a plugin reload in their saved order"

# Persisted records keep saved order and metadata; only the pinned flag changed.
python3 "$WORK/probe.py" kv "$WORK/config/plugin-data/workspaces/kv.json" > "$E/kv.txt"
cat > "$E/kv-expected.txt" <<EOF
$LONG|$WORK/proj-long|folder|false
alpha-idle|$WORK/proj-idle|folder|false
bravo-active|$WORK/proj-active|folder|true
EOF
diff -u "$E/kv-expected.txt" "$E/kv.txt" > "$E/kv.diff" || { cat "$E/kv.diff"; fail "persisted records changed"; }
pass "persisted order and metadata are unchanged; only bravo-active stays pinned"

# Filtering must include the pinned row and clear back to every row.
ctl click '[data-role="workspaces-filter"]' >/dev/null || fail "filter not clickable"
ctl type "bravo" >/dev/null || fail "typing into filter failed"
expect_outline <<EOF
Stick 1
bravo-active
EOF
has 'alpha-idle' && fail "filter kept an unpinned project"
ctl key Meta+a >/dev/null; ctl key Backspace >/dev/null
expect_outline <<EOF
Stick 1
bravo-active
No Status 2
$LONG
alpha-idle
EOF
pass "filtering matches the pinned project and clearing restores every row"

# workspace_check.luau in a disposable plugin harness. Tern's require resolves only
# real children of the package (absolute paths and symlinks are rejected), and /tmp is
# another device, so hardlink the real files from a temp dir beside the repo: same
# inode, no duplicated source, removed on exit.
CHECK=$(mktemp -d "$(dirname "$REPO")/.tern-pincheck.XXXXXX") || fail "no linkable temp dir"
ln "$REPO/workspace.luau" "$CHECK/workspace.luau" || fail "workspace.luau is not hardlinkable"
ln "$REPO/tests/workspace_check.luau" "$CHECK/workspace_check.luau" || fail "workspace_check.luau is not hardlinkable"
cat > "$CHECK/plugin.toml" <<'EOF'
schema = 1
id = "pincheck"
name = "Pin Check"
version = "0.0.1"
host = "host.luau"
EOF
cat > "$CHECK/host.luau" <<EOF
local workspace = require("./workspace")
local check = require("./workspace_check")
local ok, err = pcall(check, workspace)
tern.fs.write("$E/workspace-check.txt", if ok then "PASS" else "FAIL: " .. tostring(err))
EOF
printf '%s\n' "$CHECK" > "$WORK/config/plugins/pincheck.path"
"$TERN" plugin reload pincheck --window "$WORK/win.sock" --json > "$E/check-reload.json" 2>&1 \
  || fail "check plugin failed to load"
[ -f "$E/workspace-check.txt" ] || fail "workspace_check produced no result"
grep -qx 'PASS' "$E/workspace-check.txt" || { cat "$E/workspace-check.txt"; fail "workspace_check"; }
pass "workspace_check.luau passes in a disposable plugin harness"

# Evidence: one pinned row in Stick, every section expanded.
ctl shot pinning-final >/dev/null 2>&1 || fail "final shot failed"
ctl tree > "$E/tree-final.json"
ctl state > "$E/state.json" 2>/dev/null || true
cp "$WORK/heads.json" "$WORK/names.json" "$WORK/pins.json" "$E/" 2>/dev/null || true
echo "EVIDENCE: $E"
echo "FIXTURE: $WORK"
echo "Pinning regression: all checks passed"
