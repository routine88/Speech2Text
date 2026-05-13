#!/usr/bin/env python3
"""
Speech-to-text with speaker diarization.

Uses whisper.cpp (CPU) for transcription and pyannote-audio for speaker
identification. Assigns each transcribed segment to the speaker who was
talking during that time window.

Usage:
    python transcribe.py audio.wav
    python transcribe.py audio.mp3 --language auto --num-speakers 3
    python transcribe.py meeting.wav --min-speakers 2 --max-speakers 6
    python transcribe.py audio.wav --output transcript.json --format json
"""

import argparse
import json
import os
import subprocess
import sys
import tempfile
import time
import warnings

warnings.filterwarnings("ignore")

import numpy as np
import soundfile as sf
import torch
from pyannote.audio import Pipeline

from config import WHISPER_CLI, WHISPER_MODEL, VAD_MODEL, GPU_TYPE, GPU_NAME


def convert_to_wav(input_path: str) -> str:
    """Convert audio to 16kHz mono WAV for whisper.cpp. Returns path to WAV."""
    if input_path.lower().endswith(".wav"):
        info = sf.info(input_path)
        if info.samplerate == 16000 and info.channels == 1:
            return input_path

    tmp = tempfile.NamedTemporaryFile(suffix=".wav", delete=False)
    tmp.close()
    subprocess.run(
        ["ffmpeg", "-y", "-i", input_path, "-ar", "16000", "-ac", "1", tmp.name],
        capture_output=True,
        check=True,
    )
    return tmp.name


def run_whisper(wav_path: str, language: str, threads: int, use_gpu: bool = False) -> list[dict]:
    """Run whisper.cpp and parse JSON output."""
    with tempfile.TemporaryDirectory() as tmpdir:
        out_base = os.path.join(tmpdir, "out")
        cmd = [
            WHISPER_CLI,
            "-m", WHISPER_MODEL,
            "-f", wav_path,
            "-t", str(threads),
            "-oj",
            "-of", out_base,
            "-l", language,
            "--suppress-nst",             # suppress non-speech tokens
            # Anti-hallucination: don't feed decoded text back as context. The
            # autoregressive feedback is what turns a single wrong phrase into
            # a "X. Yeah. X. Yeah." infinite loop. -mc 0 makes each 30s window
            # decode independently.
            "-mc", "0",
        ]
        # Enable VAD to prevent hallucination loops on long audio
        if os.path.isfile(VAD_MODEL):
            cmd += [
                "--vad",
                "-vm", VAD_MODEL,
                "--vad-max-speech-duration-s", "30",
            ]
        if not use_gpu:
            cmd.append("--no-gpu")

        result = subprocess.run(cmd, capture_output=True, text=True)

        if result.returncode != 0:
            print("whisper.cpp error:", result.stderr, file=sys.stderr)
            sys.exit(1)

        json_path = out_base + ".json"
        with open(json_path) as f:
            data = json.load(f)

    segments = []
    for seg in data.get("transcription", []):
        ts = seg["timestamps"]
        segments.append({
            "start": _ts_to_seconds(ts["from"]),
            "end": _ts_to_seconds(ts["to"]),
            "text": seg["text"].strip(),
        })
    return segments


def _ts_to_seconds(ts: str) -> float:
    """Convert 'HH:MM:SS,mmm' or 'HH:MM:SS.mmm' to seconds."""
    ts = ts.replace(",", ".")
    parts = ts.split(":")
    h, m = int(parts[0]), int(parts[1])
    s = float(parts[2])
    return h * 3600 + m * 60 + s


def run_diarization(
    wav_path: str,
    num_speakers: int | None,
    min_speakers: int | None,
    max_speakers: int | None,
    use_gpu: bool = False,
) -> list[dict]:
    """Run pyannote speaker diarization."""
    pipeline = Pipeline.from_pretrained("pyannote/speaker-diarization-3.1")
    device = torch.device("cuda" if use_gpu and torch.cuda.is_available() else "cpu")
    pipeline.to(device)

    waveform, sample_rate = sf.read(wav_path)
    if waveform.ndim == 1:
        waveform = waveform[np.newaxis, :]
    else:
        waveform = waveform.T
    audio = {
        "waveform": torch.tensor(waveform, dtype=torch.float32),
        "sample_rate": sample_rate,
    }

    kwargs = {}
    if num_speakers is not None:
        kwargs["num_speakers"] = num_speakers
    if min_speakers is not None:
        kwargs["min_speakers"] = min_speakers
    if max_speakers is not None:
        kwargs["max_speakers"] = max_speakers

    result = pipeline(audio, **kwargs)
    annotation = result.speaker_diarization

    turns = []
    for turn, _, speaker in annotation.itertracks(yield_label=True):
        turns.append({
            "start": turn.start,
            "end": turn.end,
            "speaker": speaker,
        })
    return turns


def assign_speakers(segments: list[dict], diarization: list[dict]) -> list[dict]:
    """Assign a speaker label to each whisper segment based on overlap."""
    for seg in segments:
        best_speaker = "UNKNOWN"
        best_overlap = 0.0

        for turn in diarization:
            overlap_start = max(seg["start"], turn["start"])
            overlap_end = min(seg["end"], turn["end"])
            overlap = max(0.0, overlap_end - overlap_start)

            if overlap > best_overlap:
                best_overlap = overlap
                best_speaker = turn["speaker"]

        seg["speaker"] = best_speaker

    return segments


def format_timestamp(seconds: float) -> str:
    """Format seconds as HH:MM:SS.mmm"""
    h = int(seconds // 3600)
    m = int((seconds % 3600) // 60)
    s = seconds % 60
    return f"{h:02d}:{m:02d}:{s:06.3f}"


def format_output(segments: list[dict], fmt: str) -> str:
    if fmt == "json":
        return json.dumps(segments, indent=2, ensure_ascii=False)

    elif fmt == "srt":
        lines = []
        for i, seg in enumerate(segments, 1):
            start = format_timestamp(seg["start"]).replace(".", ",")
            end = format_timestamp(seg["end"]).replace(".", ",")
            lines.append(f"{i}")
            lines.append(f"{start} --> {end}")
            lines.append(f"[{seg['speaker']}] {seg['text']}")
            lines.append("")
        return "\n".join(lines)

    else:  # text
        lines = []
        current_speaker = None
        for seg in segments:
            if seg["speaker"] != current_speaker:
                current_speaker = seg["speaker"]
                lines.append(f"\n[{current_speaker}]")
            lines.append(f"  [{format_timestamp(seg['start'])} -> {format_timestamp(seg['end'])}] {seg['text']}")
        return "\n".join(lines).strip()


def main():
    parser = argparse.ArgumentParser(description="Transcribe audio with speaker diarization")
    parser.add_argument("audio", help="Path to audio file")
    parser.add_argument("-l", "--language", default="en", help="Language code or 'auto' (default: en)")
    parser.add_argument("-t", "--threads", type=int, default=16, help="CPU threads for whisper (default: 16)")
    parser.add_argument("--num-speakers", type=int, help="Exact number of speakers (if known)")
    parser.add_argument("--min-speakers", type=int, help="Minimum number of speakers")
    parser.add_argument("--max-speakers", type=int, help="Maximum number of speakers")
    parser.add_argument("-f", "--format", choices=["text", "json", "srt"], default="text", help="Output format (default: text)")
    parser.add_argument("-o", "--output", help="Output file (default: stdout)")
    parser.add_argument("--no-gpu", action="store_true", help="Disable GPU acceleration")
    args = parser.parse_args()

    if not os.path.exists(args.audio):
        print(f"Error: {args.audio} not found", file=sys.stderr)
        sys.exit(1)

    use_gpu = GPU_TYPE in ("cuda", "rocm") and not args.no_gpu
    if use_gpu:
        print(f"GPU: {GPU_NAME} ({GPU_TYPE.upper()})", file=sys.stderr)
    else:
        print("GPU: disabled (using CPU)", file=sys.stderr)

    print("Preparing audio...", file=sys.stderr)
    wav_path = convert_to_wav(args.audio)

    print("Transcribing with Whisper large-v3...", file=sys.stderr)
    t0 = time.time()
    segments = run_whisper(wav_path, args.language, args.threads, use_gpu=use_gpu)
    t_whisper = time.time() - t0
    print(f"  Transcription: {t_whisper:.1f}s ({len(segments)} segments)", file=sys.stderr)

    print("Running speaker diarization...", file=sys.stderr)
    t0 = time.time()
    diarization = run_diarization(
        wav_path, args.num_speakers, args.min_speakers, args.max_speakers,
        use_gpu=use_gpu,
    )
    t_diarize = time.time() - t0
    speakers = set(d["speaker"] for d in diarization)
    print(f"  Diarization: {t_diarize:.1f}s ({len(speakers)} speakers detected)", file=sys.stderr)

    segments = assign_speakers(segments, diarization)

    output = format_output(segments, args.format)
    if args.output:
        with open(args.output, "w") as f:
            f.write(output)
        print(f"Output written to {args.output}", file=sys.stderr)
    else:
        print(output)

    if wav_path != args.audio:
        os.unlink(wav_path)


if __name__ == "__main__":
    main()
