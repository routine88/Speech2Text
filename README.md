# Speech2Text

Local speech-to-text transcription with speaker diarization (speaker identification). Runs entirely on your machine — no cloud APIs needed.

## Features

- **Whisper large-v3** via [whisper.cpp](https://github.com/ggerganov/whisper.cpp) for high-quality transcription
- **Speaker diarization** via [pyannote-audio](https://github.com/pyannote/pyannote-audio) — identifies who said what
- **GTK4 GUI** with native Wayland drag-and-drop support
- **CLI** for scripting and batch processing
- **100+ languages** supported (auto-detection available)
- **Multiple output formats**: plain text, JSON, SRT subtitles
- **Audio format support**: WAV, MP3, FLAC, OGG, M4A, WMA, AAC, OPUS, WEBM

## Requirements

- Linux (tested on Ubuntu 24.04)
- Python 3.10+
- cmake, git, ffmpeg
- GTK4 + libadwaita (for the GUI)
- A [HuggingFace](https://huggingface.co) account (free, for pyannote model access)
- ~4GB disk space (model + dependencies)

### System packages (Ubuntu/Debian)

```bash
sudo apt install python3-dev python3-venv cmake git ffmpeg \
    libcairo2-dev libgirepository-2.0-dev pkg-config \
    gir1.2-gtk-4.0 gir1.2-adw-1
```

## Installation

```bash
git clone https://github.com/routine88/Speech2Text.git
cd Speech2Text
bash install.sh
```

The installer will:
1. Create a Python virtual environment
2. Install all Python dependencies (PyTorch CPU, pyannote-audio, etc.)
3. Clone and build whisper.cpp
4. Download the Whisper large-v3 model (~3GB)
5. Create launcher scripts and a desktop shortcut

### HuggingFace setup (required for diarization)

1. Create a free account at [huggingface.co](https://huggingface.co)
2. Accept the model licenses:
   - [pyannote/speaker-diarization-3.1](https://huggingface.co/pyannote/speaker-diarization-3.1)
   - [pyannote/segmentation-3.0](https://huggingface.co/pyannote/segmentation-3.0)
3. Log in:
   ```bash
   source venv/bin/activate
   python3 -c "from huggingface_hub import login; login()"
   ```

## Usage

### GUI

```bash
./bin/transcribe-gui
```

Or double-click the "Whisper Transcribe + Diarization" desktop shortcut. You can drag audio files directly onto the window.

### CLI

```bash
# Basic transcription with diarization
./bin/transcribe recording.wav

# Auto-detect language, specify speaker count
./bin/transcribe meeting.mp3 --language auto --num-speakers 3

# Set speaker range
./bin/transcribe call.wav --min-speakers 2 --max-speakers 6

# JSON or SRT output
./bin/transcribe audio.wav -f json -o transcript.json
./bin/transcribe audio.wav -f srt -o subtitles.srt
```

### Configuration

Paths can be overridden with environment variables:

| Variable | Default | Description |
|---|---|---|
| `WHISPER_CLI` | `~/whisper.cpp/build/bin/whisper-cli` | Path to whisper-cli binary |
| `WHISPER_MODEL` | `~/whisper.cpp/models/ggml-large-v3.bin` | Path to GGML model file |
| `S2T_OUTPUT_DIR` | `~/transcripts` | Default output directory |

## Performance

Benchmarked on AMD Ryzen AI MAX+ 395 (32 threads, AVX-512):

| Audio length | Transcription | Diarization | Total |
|---|---|---|---|
| 11 seconds | ~4s | ~2s | ~6s |
| 1 hour (est.) | ~24 min | ~15 min | ~40 min |
| 2 hours (est.) | ~48 min | ~30 min | ~1.5 hr |

Performance scales roughly linearly with audio length. Uses CPU only — the Whisper large-v3 model requires ~3GB RAM.

## Output example

```
[SPEAKER_00]
  [00:00:00.000 -> 00:00:03.000] And so, my fellow Americans,
  [00:00:03.000 -> 00:00:08.000] ask not what your country can do for you,
  [00:00:08.000 -> 00:00:11.000] ask what you can do for your country.
```

## License

MIT
