#!/bin/bash
set -e

# Speech2Text installer
# Sets up whisper.cpp + pyannote-audio for local speech-to-text with diarization

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VENV_DIR="$SCRIPT_DIR/venv"
WHISPER_DIR="$HOME/whisper.cpp"
MODEL="large-v3"

echo "=== Speech2Text Installer ==="
echo ""

# ── Check prerequisites ──────────────────────────────────────────────────────
echo "Checking prerequisites..."

if ! command -v python3.12 &>/dev/null && ! command -v python3 &>/dev/null; then
    echo "ERROR: Python 3.10+ is required."
    exit 1
fi
PYTHON=$(command -v python3.12 || command -v python3)
echo "  Python: $($PYTHON --version)"

if ! command -v cmake &>/dev/null; then
    echo "ERROR: cmake is required (for building whisper.cpp)."
    exit 1
fi

if ! command -v ffmpeg &>/dev/null; then
    echo "WARNING: ffmpeg not found. It is required for non-WAV audio input."
    echo "  Install with: sudo apt install ffmpeg  (or brew install ffmpeg)"
fi

if ! command -v git &>/dev/null; then
    echo "ERROR: git is required."
    exit 1
fi

# ── Detect GPU ────────────────────────────────────────────────────────────────
GPU_BUILD=""
TORCH_INDEX="https://download.pytorch.org/whl/cpu"
GPU_TYPE="none"

# Check CUDA (NVIDIA)
if command -v nvidia-smi &>/dev/null; then
    CUDA_VER=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1)
    GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)
    if [ -n "$GPU_NAME" ]; then
        echo "  NVIDIA GPU detected: $GPU_NAME (driver $CUDA_VER)"
        GPU_BUILD="-DGGML_CUDA=ON"
        GPU_TYPE="cuda"
        # Detect CUDA toolkit version for PyTorch wheel
        NVCC_VER=$(nvcc --version 2>/dev/null | grep -oP 'release \K[0-9]+\.[0-9]+' || true)
        if [[ "$NVCC_VER" == 12.* ]]; then
            TORCH_INDEX="https://download.pytorch.org/whl/cu124"
            echo "  CUDA toolkit: $NVCC_VER (using cu124 PyTorch)"
        elif [[ "$NVCC_VER" == 11.* ]]; then
            TORCH_INDEX="https://download.pytorch.org/whl/cu118"
            echo "  CUDA toolkit: $NVCC_VER (using cu118 PyTorch)"
        else
            echo "  CUDA toolkit not found via nvcc, using default PyTorch CUDA"
            TORCH_INDEX="https://download.pytorch.org/whl/cu124"
        fi
    fi
fi

# Check ROCm (AMD) — only if no CUDA
if [ "$GPU_TYPE" = "none" ] && [ -d /opt/rocm ]; then
    echo "  ROCm detected at /opt/rocm"
    GPU_ARCH=$(rocminfo 2>/dev/null | grep -oP 'gfx\d+' | head -1 || true)
    if [ -n "$GPU_ARCH" ]; then
        echo "  GPU architecture: $GPU_ARCH"
        GPU_BUILD="-DGGML_HIP=ON -DAMDGPU_TARGETS=$GPU_ARCH -DCMAKE_PREFIX_PATH=/opt/rocm"
    fi
fi

if [ "$GPU_TYPE" = "none" ]; then
    echo "  No GPU detected, using CPU only."
fi

# ── Create Python venv ───────────────────────────────────────────────────────
echo ""
echo "Creating Python virtual environment..."
$PYTHON -m venv "$VENV_DIR"
source "$VENV_DIR/bin/activate"
pip install --upgrade pip wheel setuptools -q

# ── Install Python dependencies ──────────────────────────────────────────────
echo "Installing Python dependencies..."
pip install numpy soundfile PyGObject pycairo -q

echo "Installing PyTorch ($( [ "$GPU_TYPE" = "cuda" ] && echo "CUDA" || echo "CPU" ))..."
pip install torch torchaudio --index-url "$TORCH_INDEX" -q

echo "Installing pyannote-audio..."
pip install pyannote.audio -q

# ── Build whisper.cpp ─────────────────────────────────────────────────────────
echo ""
if [ -d "$WHISPER_DIR" ]; then
    echo "whisper.cpp already exists at $WHISPER_DIR, updating..."
    cd "$WHISPER_DIR" && git pull -q
else
    echo "Cloning whisper.cpp..."
    git clone https://github.com/ggerganov/whisper.cpp.git "$WHISPER_DIR" -q
fi

echo "Building whisper.cpp..."
cd "$WHISPER_DIR"
cmake -B build $GPU_BUILD -DCMAKE_BUILD_TYPE=Release -q 2>&1 | tail -3
cmake --build build -j$(nproc) --target whisper-cli 2>&1 | tail -3

# ── Download model ───────────────────────────────────────────────────────────
echo ""
if [ -f "$WHISPER_DIR/models/ggml-${MODEL}.bin" ]; then
    echo "Model $MODEL already downloaded."
else
    echo "Downloading Whisper $MODEL model (~3GB)..."
    bash "$WHISPER_DIR/models/download-ggml-model.sh" "$MODEL"
fi

# ── Create launcher scripts ──────────────────────────────────────────────────
echo ""
echo "Creating launcher scripts..."

mkdir -p "$SCRIPT_DIR/bin"

cat > "$SCRIPT_DIR/bin/transcribe" << 'LAUNCHER'
#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$SCRIPT_DIR/venv/bin/activate"
exec python3 "$SCRIPT_DIR/transcribe.py" "$@"
LAUNCHER
chmod +x "$SCRIPT_DIR/bin/transcribe"

cat > "$SCRIPT_DIR/bin/transcribe-gui" << 'LAUNCHER'
#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# Pick up system paths for ffmpeg, etc.
[ -f /home/linuxbrew/.linuxbrew/bin/brew ] && eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv 2>/dev/null)"
source "$SCRIPT_DIR/venv/bin/activate"
exec python3 "$SCRIPT_DIR/gui.py" "$@"
LAUNCHER
chmod +x "$SCRIPT_DIR/bin/transcribe-gui"

# ── Desktop shortcut ─────────────────────────────────────────────────────────
DESKTOP_FILE="$HOME/.local/share/applications/whisper-transcribe.desktop"
mkdir -p "$(dirname "$DESKTOP_FILE")"
cat > "$DESKTOP_FILE" << EOF
[Desktop Entry]
Name=Whisper Transcribe + Diarization
Comment=Transcribe audio with speaker identification (Whisper large-v3 + pyannote)
Exec=$SCRIPT_DIR/bin/transcribe-gui %f
Terminal=false
Type=Application
Categories=AudioVideo;Audio;
Icon=audio-x-generic
MimeType=audio/wav;audio/x-wav;audio/mpeg;audio/mp3;audio/flac;audio/ogg;audio/x-m4a;audio/aac;audio/webm;audio/opus;
EOF
update-desktop-database "$HOME/.local/share/applications/" 2>/dev/null || true

# Copy to Desktop if it exists
if [ -d "$HOME/Desktop" ]; then
    cp "$DESKTOP_FILE" "$HOME/Desktop/whisper-transcribe.desktop"
    chmod +x "$HOME/Desktop/whisper-transcribe.desktop"
    echo "  Desktop shortcut created."
fi

# ── HuggingFace login reminder ────────────────────────────────────────────────
echo ""
echo "=== Installation complete ==="
echo ""
echo "Before first use, you need to:"
echo "  1. Log in to HuggingFace (for pyannote diarization models):"
echo "       source $VENV_DIR/bin/activate && python3 -c \"from huggingface_hub import login; login()\""
echo ""
echo "  2. Accept the pyannote model licenses:"
echo "       https://huggingface.co/pyannote/speaker-diarization-3.1"
echo "       https://huggingface.co/pyannote/segmentation-3.0"
echo ""
echo "Usage:"
echo "  CLI:  $SCRIPT_DIR/bin/transcribe audio.wav"
echo "  GUI:  $SCRIPT_DIR/bin/transcribe-gui"
echo ""
echo "Add to PATH:  export PATH=\"$SCRIPT_DIR/bin:\$PATH\""
