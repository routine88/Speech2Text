#!/bin/bash
# ============================================================
# Speech2Text — One-Click Launcher
# https://github.com/routine88/Speech2Text
#
# Place this file anywhere. Double-click or run from terminal.
# First run:  clones repo + installs everything (~10-15 min)
# After that:  pulls latest code + launches (~2 sec)
# ============================================================
set -euo pipefail

REPO_URL="https://github.com/routine88/Speech2Text.git"
RAW_URL="https://raw.githubusercontent.com/routine88/Speech2Text/main/launch.sh"
REPO_DIR="${S2T_REPO_DIR:-$HOME/Speech2Text}"
WHISPER_DIR="${WHISPER_DIR:-$HOME/whisper.cpp}"
MODEL="${WHISPER_MODEL_NAME:-large-v3}"
SELF="$(realpath "$0")"

# ── Colors ────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()  { echo -e "${CYAN}[·]${NC} $*"; }
ok()    { echo -e "${GREEN}[✓]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
err()   { echo -e "${RED}[✗]${NC} $*" >&2; }
header(){ echo -e "\n${BOLD}── $* ──${NC}"; }

# ── Phase 0: Self-Update ─────────────────────────────────────
if [ "${S2T_SELF_UPDATED:-}" != "1" ]; then
    _tmp=$(mktemp)
    if curl -fsSL --connect-timeout 5 "$RAW_URL" -o "$_tmp" 2>/dev/null; then
        if ! cmp -s "$SELF" "$_tmp"; then
            cp "$_tmp" "$SELF" && chmod +x "$SELF"
            rm -f "$_tmp"
            info "Launcher updated. Restarting..."
            export S2T_SELF_UPDATED=1
            exec "$SELF" "$@"
        fi
    else
        warn "Could not check for launcher updates (offline?)"
    fi
    rm -f "$_tmp"
fi

# ── Phase 1: Repo Sync ───────────────────────────────────────
header "Syncing code"
if [ -d "$REPO_DIR/.git" ]; then
    if git -C "$REPO_DIR" pull --ff-only origin main 2>&1 | grep -qv "Already up to date"; then
        ok "Code updated"
    else
        ok "Already up to date"
    fi
else
    info "First run — cloning Speech2Text..."
    git clone "$REPO_URL" "$REPO_DIR"
    ok "Repository cloned to $REPO_DIR"
fi

# Copy repo's launch.sh over self (belt-and-suspenders with curl)
if [ -f "$REPO_DIR/launch.sh" ] && ! cmp -s "$SELF" "$REPO_DIR/launch.sh"; then
    cp "$REPO_DIR/launch.sh" "$SELF" && chmod +x "$SELF"
fi

# ── Phase 2: State Check ─────────────────────────────────────
STATE_DIR="$REPO_DIR/.s2t_state"
VENV_DIR="$REPO_DIR/venv"
mkdir -p "$STATE_DIR"

# Find Python
PYTHON=""
for candidate in python3.12 python3.11 python3.10 python3; do
    if command -v "$candidate" &>/dev/null; then
        ver=$("$candidate" --version 2>&1 | grep -oP '\d+\.\d+' | head -1)
        major=${ver%%.*}; minor=${ver##*.}
        if [ "$major" -ge 3 ] && [ "$minor" -ge 10 ]; then
            PYTHON="$(command -v "$candidate")"
            break
        fi
    fi
done
if [ -z "$PYTHON" ]; then
    err "Python 3.10+ required. Install with:  sudo apt install python3.12 python3.12-venv"
    exit 1
fi
PYTHON_VER="$($PYTHON --version 2>&1)"

# GPU detection
GPU_BUILD=""
TORCH_INDEX="https://download.pytorch.org/whl/cpu"
GPU_TYPE="none"

if command -v nvidia-smi &>/dev/null; then
    GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 || true)
    if [ -n "$GPU_NAME" ]; then
        GPU_TYPE="cuda"
        GPU_BUILD="-DGGML_CUDA=ON"
        NVCC_VER=$(nvcc --version 2>/dev/null | grep -oP 'release \K[0-9]+\.[0-9]+' || true)
        if [[ "$NVCC_VER" == 12.* ]]; then
            TORCH_INDEX="https://download.pytorch.org/whl/cu124"
        elif [[ "$NVCC_VER" == 11.* ]]; then
            TORCH_INDEX="https://download.pytorch.org/whl/cu118"
        else
            TORCH_INDEX="https://download.pytorch.org/whl/cu124"
        fi
    fi
fi
if [ "$GPU_TYPE" = "none" ] && [ -d /opt/rocm ]; then
    GPU_ARCH=$(rocminfo 2>/dev/null | grep -oP 'gfx\d+' | head -1 || true)
    if [ -n "$GPU_ARCH" ]; then
        GPU_BUILD="-DGGML_HIP=ON -DAMDGPU_TARGETS=$GPU_ARCH -DCMAKE_PREFIX_PATH=/opt/rocm"
    fi
fi

# Determine what needs work
needs_venv=0; needs_pip=0; needs_whisper=0; needs_model=0; needs_syscheck=0

# Venv
if [ ! -f "$STATE_DIR/venv" ] || [ ! -f "$VENV_DIR/bin/activate" ]; then
    needs_venv=1
elif [ "$(cat "$STATE_DIR/venv" 2>/dev/null)" != "$PYTHON_VER" ]; then
    needs_venv=1
fi

# Pip deps
DEP_STRING="numpy soundfile PyGObject pycairo torch torchaudio pyannote.audio|$TORCH_INDEX"
DEP_HASH=$(echo "$DEP_STRING" | sha256sum | cut -d' ' -f1)
if [ ! -f "$STATE_DIR/pip_deps" ] || [ "$(cat "$STATE_DIR/pip_deps" 2>/dev/null)" != "$DEP_HASH" ]; then
    needs_pip=1
fi

# whisper.cpp
if [ ! -d "$WHISPER_DIR" ]; then
    needs_whisper=1
elif [ -d "$WHISPER_DIR/.git" ]; then
    WHISPER_HEAD=$(git -C "$WHISPER_DIR" rev-parse HEAD 2>/dev/null || true)
    if [ ! -f "$STATE_DIR/whisper_build" ] || [ "$(cat "$STATE_DIR/whisper_build" 2>/dev/null)" != "$WHISPER_HEAD" ]; then
        needs_whisper=1
    fi
fi

# Model
if [ ! -f "$WHISPER_DIR/models/ggml-${MODEL}.bin" ]; then
    needs_model=1
fi

# System deps (only check once)
if [ ! -f "$STATE_DIR/system_deps" ]; then
    needs_syscheck=1
fi

# ── Phase 3: Install (only what's needed) ─────────────────────
if [ $needs_syscheck -eq 1 ] || [ $needs_venv -eq 1 ] || [ $needs_pip -eq 1 ] || [ $needs_whisper -eq 1 ] || [ $needs_model -eq 1 ]; then
    header "Setting up dependencies"
fi

# 3a: System deps
if [ $needs_syscheck -eq 1 ]; then
    missing=""
    command -v cmake  &>/dev/null || missing="$missing cmake"
    command -v ffmpeg &>/dev/null || missing="$missing ffmpeg"
    command -v git    &>/dev/null || missing="$missing git"
    if [ -n "$missing" ]; then
        err "Missing required tools:$missing"
        err "Install with:  sudo apt install$missing"
        exit 1
    fi
    # Check venv module
    if ! $PYTHON -m venv --help &>/dev/null; then
        err "Python venv module missing. Install with:  sudo apt install python3-venv"
        exit 1
    fi
    echo "ok" > "$STATE_DIR/system_deps"
    ok "System dependencies verified"
fi

# 3b: Venv
if [ $needs_venv -eq 1 ]; then
    info "Creating Python virtual environment..."
    rm -rf "$VENV_DIR"
    $PYTHON -m venv "$VENV_DIR"
    echo "$PYTHON_VER" > "$STATE_DIR/venv"
    needs_pip=1  # force pip install in new venv
    ok "Virtual environment created"
fi

# 3c: Pip deps
if [ $needs_pip -eq 1 ]; then
    info "Installing Python packages (this may take a few minutes)..."
    source "$VENV_DIR/bin/activate"
    pip install --upgrade pip wheel setuptools -q
    pip install numpy soundfile -q
    # PyGObject deps (Linux GUI)
    pip install PyGObject pycairo -q 2>/dev/null || warn "PyGObject install failed (GUI may not work)"
    pip install torch torchaudio --index-url "$TORCH_INDEX" -q
    pip install pyannote.audio -q
    echo "$DEP_HASH" > "$STATE_DIR/pip_deps"
    ok "Python packages installed"
fi

# 3d: whisper.cpp
if [ $needs_whisper -eq 1 ]; then
    if [ -d "$WHISPER_DIR/.git" ]; then
        info "Updating whisper.cpp..."
        git -C "$WHISPER_DIR" pull -q 2>/dev/null || true
    else
        info "Cloning whisper.cpp..."
        git clone https://github.com/ggerganov/whisper.cpp.git "$WHISPER_DIR" -q
    fi
    info "Building whisper.cpp (this may take a few minutes)..."
    cmake -B "$WHISPER_DIR/build" -S "$WHISPER_DIR" $GPU_BUILD -DCMAKE_BUILD_TYPE=Release 2>&1 | tail -3
    cmake --build "$WHISPER_DIR/build" -j"$(nproc)" --target whisper-cli 2>&1 | tail -3
    NEW_HEAD=$(git -C "$WHISPER_DIR" rev-parse HEAD)
    echo "$NEW_HEAD" > "$STATE_DIR/whisper_build"
    ok "whisper.cpp built"
fi

# 3e: Model
if [ $needs_model -eq 1 ]; then
    info "Downloading Whisper $MODEL model (~3GB)..."
    bash "$WHISPER_DIR/models/download-ggml-model.sh" "$MODEL"
    echo "$MODEL" > "$STATE_DIR/whisper_model"
    ok "Model downloaded"
fi

# 3f: VAD model (for anti-hallucination)
VAD_MODEL_PATH="$WHISPER_DIR/models/ggml-silero-v6.2.0.bin"
if [ ! -f "$VAD_MODEL_PATH" ] && [ -f "$WHISPER_DIR/models/download-vad-model.sh" ]; then
    info "Downloading VAD model (anti-hallucination)..."
    bash "$WHISPER_DIR/models/download-vad-model.sh" silero-v6.2.0
    ok "VAD model downloaded"
fi

# Summary
if [ $needs_venv -eq 0 ] && [ $needs_pip -eq 0 ] && [ $needs_whisper -eq 0 ] && [ $needs_model -eq 0 ] && [ $needs_syscheck -eq 0 ]; then
    ok "All dependencies up to date"
fi

# ── Phase 4: Launch ───────────────────────────────────────────
header "Launching Speech2Text"
source "$VENV_DIR/bin/activate"
# Pick up system paths for ffmpeg etc.
[ -f /home/linuxbrew/.linuxbrew/bin/brew ] && eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv 2>/dev/null)" || true
exec python3 "$REPO_DIR/gui.py" "$@"
