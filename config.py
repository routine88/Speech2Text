"""
Path configuration for Speech2Text.

Override these with environment variables:
    WHISPER_CLI     - path to whisper-cli binary
    WHISPER_MODEL   - path to ggml model file
    S2T_OUTPUT_DIR  - default output directory
    S2T_USE_GPU     - "0" to force CPU, "1" to force GPU (default: auto-detect)
"""

import os
import platform
import shutil
import subprocess
from pathlib import Path

if platform.system() == "Windows":
    _default_cli = Path.home() / "whisper.cpp" / "build" / "bin" / "Release" / "whisper-cli.exe"
else:
    _default_cli = Path.home() / "whisper.cpp" / "build" / "bin" / "whisper-cli"

WHISPER_CLI = os.environ.get("WHISPER_CLI", str(_default_cli))

WHISPER_MODEL = os.environ.get(
    "WHISPER_MODEL",
    str(Path.home() / "whisper.cpp" / "models" / "ggml-large-v3.bin"),
)

VAD_MODEL = os.environ.get(
    "WHISPER_VAD_MODEL",
    str(Path.home() / "whisper.cpp" / "models" / "ggml-silero-v6.2.0.bin"),
)

DEFAULT_OUTDIR = os.environ.get(
    "S2T_OUTPUT_DIR",
    str(Path.home() / "transcripts"),
)


def detect_gpu():
    """Detect available GPU acceleration.

    Returns (type, device_name) where type is "cuda", "rocm", or "none".
    """
    env_override = os.environ.get("S2T_USE_GPU")
    if env_override == "0":
        return "none", None

    # Check CUDA (NVIDIA) via nvidia-smi
    if shutil.which("nvidia-smi"):
        try:
            result = subprocess.run(
                ["nvidia-smi", "--query-gpu=name", "--format=csv,noheader"],
                capture_output=True, text=True, timeout=5,
            )
            if result.returncode == 0 and result.stdout.strip():
                return "cuda", result.stdout.strip().split("\n")[0]
        except (subprocess.TimeoutExpired, FileNotFoundError):
            pass

    # Check ROCm (AMD)
    if shutil.which("rocm-smi"):
        try:
            result = subprocess.run(
                ["rocminfo"],
                capture_output=True, text=True, timeout=5,
            )
            if result.returncode == 0:
                for line in result.stdout.splitlines():
                    if "Marketing Name:" in line and "CPU" not in line:
                        name = line.split("Marketing Name:")[1].strip()
                        if name:
                            return "rocm", name
        except (subprocess.TimeoutExpired, FileNotFoundError):
            pass

    # Fallback: check via PyTorch
    try:
        import torch
        if torch.cuda.is_available():
            name = torch.cuda.get_device_name(0)
            hip = getattr(torch.version, "hip", None)
            return ("rocm" if hip else "cuda"), name
    except (ImportError, RuntimeError):
        pass

    return "none", None


GPU_TYPE, GPU_NAME = detect_gpu()
