#!/usr/bin/env bash
# Prepare a fresh Linux cloud container to develop this Godot project.
#
#   bash tools/cloud/setup.sh                 (from the repo root)
#   bash TinyRealty/tools/cloud/setup.sh   (from its parent, e.g. as an environment setup script)
#
# Installs Godot 4.7.1 to /opt/godot with a /usr/local/bin/godot symlink, the apt packages a windowed
# run under Xvfb needs (mesa software GL, xvfb, the X client libs), then runs the first import so the
# class cache in .godot/ exists. Idempotent and non-interactive: every step checks first and skips
# when already done. Exits non-zero if any step failed; as an environment setup script append
# `|| true` so a network hiccup never blocks a session from starting.
#
# Env: REPO (project dir, else found automatically), GODOT_DIR (default /opt/godot),
# GODOT_LINK (default /usr/local/bin/godot).
set -uo pipefail

GODOT_VERSION="4.7.1-stable"
GODOT_NAME="Godot_v${GODOT_VERSION}_linux.x86_64"
GODOT_URL="https://github.com/godotengine/godot/releases/download/${GODOT_VERSION}/${GODOT_NAME}.zip"
GODOT_SHA512="4ccdab7a48eeccbe8819a2fc1f6262f8d72065d98601bcb3743fcbd7ebd39f373758a788ee3293a05ec5b2c48538266c437404312e372225cd2df273945a2de9"
GODOT_DIR="${GODOT_DIR:-/opt/godot}"
GODOT_BIN="$GODOT_DIR/$GODOT_NAME"
GODOT_LINK="${GODOT_LINK:-/usr/local/bin/godot}"
APT_PACKAGES=(unzip curl ca-certificates xvfb xauth libgl1 libgl1-mesa-dri libglx-mesa0
	libxcursor1 libxinerama1 libxrandr2 libxi6 libxkbcommon0 libfontconfig1)

failed=0
log() { echo "[setup] $*"; }
warn() { echo "[setup] WARNING: $*" >&2; failed=1; }

SUDO=""
if [ "$(id -u)" -ne 0 ]; then
	if command -v sudo >/dev/null 2>&1; then SUDO="sudo -n"; else log "not root and no sudo: system steps may fail"; fi
fi

# --- 1. find the project ---------------------------------------------------------------------
is_project() { [ -f "$1/project.godot" ] && grep -q 'config/name="Tiny Realty"' "$1/project.godot"; }

find_repo() {
	local here cand
	if [ -n "${REPO:-}" ] && is_project "$REPO"; then (cd "$REPO" && pwd); return 0; fi
	here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
	if [ -n "$here" ] && is_project "$here/../.."; then (cd "$here/../.." && pwd); return 0; fi
	if is_project "$PWD"; then echo "$PWD"; return 0; fi
	for cand in "$PWD"/*/ "$PWD"/*/*/; do
		if is_project "$cand"; then (cd "$cand" && pwd); return 0; fi
	done
	return 1
}

ROOT="$(find_repo || true)"
if [ -n "$ROOT" ]; then log "project: $ROOT"; else log "project not found from $PWD; will install tools only"; fi

# --- 2. apt packages ---------------------------------------------------------------------------
missing=()
for p in "${APT_PACKAGES[@]}"; do
	dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q "install ok installed" || missing+=("$p")
done
if [ ${#missing[@]} -eq 0 ]; then
	log "apt packages already installed"
elif ! command -v apt-get >/dev/null 2>&1; then
	warn "apt-get not available; missing: ${missing[*]}"
else
	log "installing: ${missing[*]}"
	export DEBIAN_FRONTEND=noninteractive
	$SUDO apt-get update -qq >/dev/null 2>&1 || log "apt-get update reported errors (continuing)"
	$SUDO apt-get install -y -qq --no-install-recommends "${missing[@]}" >/dev/null 2>&1 \
		|| warn "apt-get install failed for: ${missing[*]} (headless runs still work; Xvfb rendering may not)"
fi

# --- 3. Godot ----------------------------------------------------------------------------------
if [ -x "$GODOT_BIN" ] && "$GODOT_BIN" --headless --version 2>/dev/null | grep -q '^4\.7\.1\.stable'; then
	log "godot already installed: $GODOT_BIN"
else
	log "downloading $GODOT_URL"
	tmp="$(mktemp -d)"
	if curl -fsSL --retry 4 --retry-delay 3 -o "$tmp/godot.zip" "$GODOT_URL" \
		&& echo "$GODOT_SHA512  $tmp/godot.zip" | sha512sum -c --status - \
		&& unzip -q -o "$tmp/godot.zip" -d "$tmp/x" \
		&& $SUDO mkdir -p "$GODOT_DIR" \
		&& $SUDO install -m 0755 "$tmp/x/$GODOT_NAME" "$GODOT_BIN"; then
		log "installed $GODOT_BIN"
	else
		warn "godot download, checksum or unpack failed"
	fi
	rm -rf "$tmp"
fi
if [ -x "$GODOT_BIN" ] && [ "$(readlink -f "$GODOT_LINK" 2>/dev/null)" != "$GODOT_BIN" ]; then
	$SUDO ln -sfn "$GODOT_BIN" "$GODOT_LINK" && log "linked $GODOT_LINK" || warn "could not link $GODOT_LINK"
fi
if [ -x "$GODOT_BIN" ]; then log "godot --version: $("$GODOT_BIN" --headless --version 2>/dev/null | tail -1)"; fi

# --- 4. first import ---------------------------------------------------------------------------
# Always run: it is quick (~10 s) and a no-op when nothing changed, and a fresh clone has no .godot/
# so every class_name reference fails to parse until it has run.
if [ -n "$ROOT" ] && [ -x "$GODOT_BIN" ]; then
	importlog="$(mktemp -t godot_import.XXXXXX.log)"
	log "importing project (log: $importlog)"
	if timeout 600 "$GODOT_BIN" --headless --path "$ROOT" --import >"$importlog" 2>&1 \
		&& ! grep -qE "SCRIPT ERROR|^ERROR:" "$importlog"; then
		log "import ok"
	else
		grep -nE "SCRIPT ERROR|^ERROR:" "$importlog" | head -20 >&2
		warn "import reported errors (see $importlog)"
	fi
fi

if [ "$failed" -eq 0 ]; then log "done"; else log "finished with warnings"; fi
exit "$failed"
