#!/usr/bin/env bash
# Render PNG screenshots of the real game in a display-less Linux box.
#
#   bash tools/cloud/screenshot.sh [outdir]      (default: docs/screenshots in the repo)
#
# Runs tools/cloud/capture.gd under xvfb-run with mesa's software GL (llvmpipe), because a
# --headless run renders nothing. Fails loudly on a non-zero exit, a SCRIPT ERROR / ERROR: line or
# a missing shot, and prints the PNGs it wrote. Env: GODOT (binary, default godot), TIMEOUT (s).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="${1:-$ROOT/docs/screenshots}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
GODOT="${GODOT:-godot}"
TIMEOUT="${TIMEOUT:-300}"
LOG="$(mktemp -t capture.XXXXXX.log)"

command -v "$GODOT" >/dev/null || { echo "screenshot.sh: '$GODOT' not found" >&2; exit 2; }
command -v xvfb-run >/dev/null || { echo "screenshot.sh: xvfb-run not found (apt-get install xvfb)" >&2; exit 2; }

# only clear what this tool writes, so a shared folder keeps its other files
rm -f "$OUT"/[0-9][0-9]_*.png

echo "capturing into $OUT (log: $LOG)"
LIBGL_ALWAYS_SOFTWARE=1 timeout "$TIMEOUT" \
	xvfb-run -a -s "-screen 0 1280x1024x24" \
	"$GODOT" --path "$ROOT" --rendering-driver opengl3 --audio-driver Dummy \
	--script res://tools/cloud/capture.gd -- --out="$OUT" 2>&1 | tee "$LOG"
status=${PIPESTATUS[0]}

fail=0
if [ "$status" -ne 0 ]; then
	echo "screenshot.sh: godot exited with status $status" >&2
	fail=1
fi
if grep -nE "SCRIPT ERROR|^ERROR:|Parse Error|CAPTURE FAILED" "$LOG" >&2; then
	echo "screenshot.sh: errors in the godot log above" >&2
	fail=1
fi
if ! grep -q "^DONE " "$LOG"; then
	echo "screenshot.sh: capture never reached DONE" >&2
	fail=1
fi
if grep -nE "^WARNING:" "$LOG" >/dev/null; then
	echo "screenshot.sh: warnings (not fatal):" >&2
	grep -nE "^WARNING:" "$LOG" >&2
fi

echo "PNGs written:"
ls -1 "$OUT"/[0-9][0-9]_*.png 2>/dev/null || echo "  (none)"
[ "$fail" -eq 0 ] || { echo "screenshot.sh: FAILED" >&2; exit 1; }
echo "screenshot.sh: OK"
