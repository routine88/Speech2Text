"""
Path configuration for Speech2Text.

Override these with environment variables:
    WHISPER_CLI     - path to whisper-cli binary
    WHISPER_MODEL   - path to ggml model file
    S2T_OUTPUT_DIR  - default output directory
"""

import os
from pathlib import Path

WHISPER_CLI = os.environ.get(
    "WHISPER_CLI",
    str(Path.home() / "whisper.cpp" / "build" / "bin" / "whisper-cli"),
)

WHISPER_MODEL = os.environ.get(
    "WHISPER_MODEL",
    str(Path.home() / "whisper.cpp" / "models" / "ggml-large-v3.bin"),
)

DEFAULT_OUTDIR = os.environ.get(
    "S2T_OUTPUT_DIR",
    str(Path.home() / "transcripts"),
)
