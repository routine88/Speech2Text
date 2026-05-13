#!/usr/bin/env python3
"""
Cross-platform tkinter GUI for Speech2Text.

Tkinter ships with the Python standard library on Windows and macOS, and is
available via `python3-tk` (apt) / `python-tk` (brew) on Linux. Pure Python,
no PyGObject -- so this works on Windows where gui.py (GTK4) cannot.

Pipeline helpers are duplicated from gui.py rather than imported so that
importing this module never pulls in `gi` (which gui.py does at top level).
"""

import json
import os
import platform
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import tkinter as tk
from pathlib import Path
from tkinter import filedialog, messagebox, ttk

from config import (
    DEFAULT_OUTDIR,
    GPU_NAME,
    GPU_TYPE,
    VAD_MODEL,
    WHISPER_CLI,
    WHISPER_MODEL,
)

# Drag-and-drop is optional. tkinterdnd2 ships a tcl/tk extension (tkdnd) plus
# a TkinterDnD.Tk subclass that adds drop_target_register / dnd_bind. If the
# package is missing we silently fall back to plain tk.Tk and the user can
# still pick files via the Browse button.
try:
    from tkinterdnd2 import DND_FILES, TkinterDnD  # type: ignore[import-not-found]

    _RootTk = TkinterDnD.Tk
    _HAS_DND = True
except Exception:
    _RootTk = tk.Tk
    DND_FILES = None  # sentinel; never used when _HAS_DND is False
    _HAS_DND = False


ACCEPTED_EXTENSIONS = (
    ".wav", ".mp3", ".flac", ".ogg", ".m4a", ".wma", ".aac", ".opus", ".webm",
)

OUTPUT_FORMATS = [
    ("Text (.txt)", "text"),
    ("JSON (.json)", "json"),
    ("SRT subtitles (.srt)", "srt"),
]
FORMAT_EXTENSIONS = {"text": ".txt", "json": ".json", "srt": ".srt"}

LANGUAGES = [
    "auto", "en", "zh", "de", "es", "ru", "ko", "fr", "ja", "pt", "tr",
    "pl", "ca", "nl", "ar", "sv", "it", "id", "hi", "fi", "vi", "he",
    "uk", "el", "ms", "cs", "ro", "da", "hu", "ta", "no", "th", "ur",
    "hr", "bg", "lt", "la", "mi", "ml", "cy", "sk", "te", "fa", "lv",
    "bn", "sr", "az", "sl", "kn", "et", "mk", "br", "eu", "is", "hy",
    "ne", "mn", "bs", "kk", "sq", "sw", "gl", "mr", "pa", "si", "km",
    "sn", "yo", "so", "af", "oc", "ka", "be", "tg", "sd", "gu", "am",
    "yi", "lo", "uz", "fo", "ht", "ps", "tk", "nn", "mt", "sa", "lb",
    "my", "bo", "tl", "mg", "as", "tt", "haw", "ln", "ha", "ba", "jw",
    "su", "yue",
]


# -- Audio helpers --------------------------------------------------------

def convert_to_wav(input_path):
    import soundfile as sf
    if input_path.lower().endswith(".wav"):
        info = sf.info(input_path)
        if info.samplerate == 16000 and info.channels == 1:
            return input_path
    tmp = tempfile.NamedTemporaryFile(suffix=".wav", delete=False)
    tmp.close()
    subprocess.run(
        ["ffmpeg", "-y", "-i", input_path, "-ar", "16000", "-ac", "1", tmp.name],
        capture_output=True, check=True,
    )
    return tmp.name


def get_audio_duration(path):
    import soundfile as sf
    return sf.info(path).duration


# -- Pipeline -------------------------------------------------------------

def _ts_to_seconds(ts):
    ts = ts.replace(",", ".")
    parts = ts.split(":")
    return int(parts[0]) * 3600 + int(parts[1]) * 60 + float(parts[2])


def run_whisper(wav_path, language, threads, log_fn, use_gpu=False):
    with tempfile.TemporaryDirectory() as tmpdir:
        out_base = os.path.join(tmpdir, "out")
        cmd = [
            str(WHISPER_CLI), "-m", str(WHISPER_MODEL),
            "-f", wav_path, "-t", str(threads),
            "-oj", "-of", out_base, "-l", language,
            "--suppress-nst",
        ]
        if os.path.isfile(VAD_MODEL):
            cmd += ["--vad", "-vm", str(VAD_MODEL), "--vad-max-speech-duration-s", "30"]
            log_fn("  VAD enabled (anti-hallucination)")
        if not use_gpu:
            cmd.append("--no-gpu")
        log_fn(f"  Running: {Path(cmd[0]).name} ...")
        result = subprocess.run(cmd, capture_output=True, text=True)
        if result.returncode != 0:
            raise RuntimeError(f"whisper.cpp failed:\n{result.stderr}")
        with open(out_base + ".json", encoding="utf-8") as f:
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


def run_diarization(wav_path, num_speakers, min_speakers, max_speakers, log_fn, use_gpu=False):
    import warnings
    warnings.filterwarnings("ignore")
    import numpy as np
    import soundfile as sf
    import torch
    from pyannote.audio import Pipeline

    log_fn("  Loading pyannote pipeline...")
    pipeline = Pipeline.from_pretrained("pyannote/speaker-diarization-3.1")
    device = torch.device("cuda" if use_gpu and torch.cuda.is_available() else "cpu")
    pipeline.to(device)
    log_fn(f"  Diarization device: {device}")

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
    if num_speakers:
        kwargs["num_speakers"] = num_speakers
    if min_speakers:
        kwargs["min_speakers"] = min_speakers
    if max_speakers:
        kwargs["max_speakers"] = max_speakers

    log_fn("  Running diarization (this may take a while)...")
    result = pipeline(audio, **kwargs)
    annotation = result.speaker_diarization
    turns = []
    for turn, _, speaker in annotation.itertracks(yield_label=True):
        turns.append({"start": turn.start, "end": turn.end, "speaker": speaker})
    return turns


def assign_speakers(segments, diarization):
    for seg in segments:
        best_speaker, best_overlap = "UNKNOWN", 0.0
        for turn in diarization:
            overlap = max(0.0, min(seg["end"], turn["end"]) - max(seg["start"], turn["start"]))
            if overlap > best_overlap:
                best_overlap = overlap
                best_speaker = turn["speaker"]
        seg["speaker"] = best_speaker
    return segments


def format_timestamp(seconds):
    h = int(seconds // 3600)
    m = int((seconds % 3600) // 60)
    s = seconds % 60
    return f"{h:02d}:{m:02d}:{s:06.3f}"


def format_output(segments, fmt):
    if fmt == "json":
        return json.dumps(segments, indent=2, ensure_ascii=False)
    if fmt == "srt":
        lines = []
        for i, seg in enumerate(segments, 1):
            start = format_timestamp(seg["start"]).replace(".", ",")
            end = format_timestamp(seg["end"]).replace(".", ",")
            lines += [str(i), f"{start} --> {end}", f"[{seg['speaker']}] {seg['text']}", ""]
        return "\n".join(lines)
    # plain text
    lines, cur = [], None
    for seg in segments:
        if seg["speaker"] != cur:
            cur = seg["speaker"]
            lines.append(f"\n[{cur}]")
        lines.append(f"  [{format_timestamp(seg['start'])} -> {format_timestamp(seg['end'])}] {seg['text']}")
    return "\n".join(lines).strip()


def open_folder(path):
    """Open a folder in the system file manager. Cross-platform."""
    try:
        system = platform.system()
        if system == "Windows":
            os.startfile(path)  # type: ignore[attr-defined]
        elif system == "Darwin":
            subprocess.Popen(["open", path])
        else:
            subprocess.Popen(["xdg-open", path])
    except Exception:
        pass


def _fmt_duration(seconds):
    s = int(seconds)
    if s < 60:
        return f"{s}s"
    m, s = divmod(s, 60)
    if m < 60:
        return f"{m}m {s:02d}s"
    h, m = divmod(m, 60)
    return f"{h}h {m:02d}m"


def _set_subtree_state(widget, state):
    """Enable/disable an entire widget subtree. Frames don't support `state`
    so we silently skip them and recurse into their children."""
    for child in widget.winfo_children():
        try:
            child.configure(state=state)
        except tk.TclError:
            pass
        _set_subtree_state(child, state)


# -- GUI ------------------------------------------------------------------

class TranscribeApp(_RootTk):
    def __init__(self):
        super().__init__()
        self.title("Speech2Text - Whisper + Diarization")
        self.geometry("820x780")
        self.minsize(680, 620)

        self.input_path = None
        self.audio_duration = 0.0
        self.running = False
        self._etr_phase = ""
        self._etr_phase_start = 0.0
        self._etr_est_total = 0.0
        self._etr_after_id = None
        self._gpu_after_id = None

        self._build_ui()
        if _HAS_DND:
            self._enable_dnd()
        self._log("Ready. " + (
            "Drop a file anywhere on the window, or click Browse." if _HAS_DND
            else "Click Browse to select an audio file."
        ))
        self._log(f"Model: {Path(WHISPER_MODEL).name}")
        self._log(f"Output folder: {DEFAULT_OUTDIR}")
        if GPU_TYPE in ("cuda", "rocm"):
            self._log(f"GPU: {GPU_NAME} ({GPU_TYPE.upper()})")
        else:
            self._log("GPU: None detected (using CPU)")
        if not _HAS_DND:
            self._log("(Drag-and-drop not available -- pip install tkinterdnd2 to enable.)")
        self._gpu_monitor_start()

    def _build_ui(self):
        main = ttk.Frame(self, padding=10)
        main.pack(fill="both", expand=True)
        main.columnconfigure(0, weight=1)

        # ---- Audio file -------------------------------------------------
        ttk.Label(main, text="Audio file", font=("", 10, "bold")).grid(
            row=0, column=0, sticky="w", pady=(0, 4)
        )
        in_frame = ttk.Frame(main)
        in_frame.grid(row=1, column=0, sticky="ew", pady=(0, 8))
        in_frame.columnconfigure(0, weight=1)

        self.file_var = tk.StringVar(value="(no file selected)")
        self.file_entry = ttk.Entry(in_frame, textvariable=self.file_var, state="readonly")
        self.file_entry.grid(row=0, column=0, sticky="ew", padx=(0, 6))
        ttk.Button(in_frame, text="Browse...", command=self._browse_input).grid(row=0, column=1)

        self.duration_var = tk.StringVar(value="")
        ttk.Label(in_frame, textvariable=self.duration_var, foreground="#666").grid(
            row=1, column=0, sticky="w", pady=(2, 0)
        )

        # ---- Output folder ---------------------------------------------
        ttk.Label(main, text="Output folder", font=("", 10, "bold")).grid(
            row=2, column=0, sticky="w", pady=(6, 4)
        )
        out_frame = ttk.Frame(main)
        out_frame.grid(row=3, column=0, sticky="ew", pady=(0, 8))
        out_frame.columnconfigure(0, weight=1)

        self.outdir_var = tk.StringVar(value=DEFAULT_OUTDIR)
        ttk.Entry(out_frame, textvariable=self.outdir_var).grid(row=0, column=0, sticky="ew", padx=(0, 6))
        ttk.Button(out_frame, text="Browse...", command=self._browse_outdir).grid(row=0, column=1)

        # ---- Output format ---------------------------------------------
        fmt_frame = ttk.LabelFrame(main, text="Output format", padding=8)
        fmt_frame.grid(row=4, column=0, sticky="ew", pady=(4, 8))
        self.fmt_var = tk.StringVar(value="text")
        for i, (label, value) in enumerate(OUTPUT_FORMATS):
            ttk.Radiobutton(fmt_frame, text=label, variable=self.fmt_var, value=value).grid(
                row=0, column=i, padx=(0, 12), sticky="w"
            )

        # ---- Settings ---------------------------------------------------
        set_frame = ttk.LabelFrame(main, text="Settings", padding=8)
        set_frame.grid(row=5, column=0, sticky="ew", pady=(0, 8))
        set_frame.columnconfigure(1, weight=1)

        ttk.Label(set_frame, text="Language:").grid(row=0, column=0, sticky="w", padx=(0, 8), pady=2)
        self.lang_var = tk.StringVar(value="en")
        ttk.Combobox(
            set_frame, textvariable=self.lang_var, values=LANGUAGES,
            state="readonly", width=8,
        ).grid(row=0, column=1, sticky="w", pady=2)

        ttk.Label(set_frame, text="CPU threads:").grid(row=1, column=0, sticky="w", padx=(0, 8), pady=2)
        self.threads_var = tk.IntVar(value=16)
        ttk.Spinbox(
            set_frame, from_=1, to=64, textvariable=self.threads_var, width=6,
        ).grid(row=1, column=1, sticky="w", pady=2)

        self.diarize_var = tk.BooleanVar(value=True)
        ttk.Checkbutton(
            set_frame, text="Speaker diarization (identify individual speakers)",
            variable=self.diarize_var, command=self._on_diarize_toggle,
        ).grid(row=2, column=0, columnspan=2, sticky="w", pady=(4, 2))

        has_gpu = GPU_TYPE in ("cuda", "rocm")
        if has_gpu:
            gpu_label = f"GPU acceleration  [{GPU_NAME} ({GPU_TYPE.upper()})]"
        else:
            gpu_label = "GPU acceleration (none detected)"
        self.gpu_var = tk.BooleanVar(value=has_gpu)
        self.gpu_check = ttk.Checkbutton(set_frame, text=gpu_label, variable=self.gpu_var)
        if not has_gpu:
            self.gpu_check.state(["disabled"])
        self.gpu_check.grid(row=3, column=0, columnspan=2, sticky="w", pady=2)

        # ---- Speakers --------------------------------------------------
        self.spk_frame = ttk.LabelFrame(main, text="Speaker detection", padding=8)
        self.spk_frame.grid(row=6, column=0, sticky="ew", pady=(0, 8))

        self.spk_mode_var = tk.StringVar(value="auto")
        ttk.Radiobutton(
            self.spk_frame, text="Auto-detect speakers", variable=self.spk_mode_var,
            value="auto", command=self._on_spk_mode,
        ).grid(row=0, column=0, columnspan=3, sticky="w")

        ttk.Radiobutton(
            self.spk_frame, text="Exact count:", variable=self.spk_mode_var,
            value="exact", command=self._on_spk_mode,
        ).grid(row=1, column=0, sticky="w")
        self.num_spk_var = tk.IntVar(value=2)
        self.num_spk_spin = ttk.Spinbox(
            self.spk_frame, from_=1, to=20, textvariable=self.num_spk_var, width=4,
        )
        self.num_spk_spin.grid(row=1, column=1, sticky="w", padx=(6, 0))

        ttk.Radiobutton(
            self.spk_frame, text="Range:", variable=self.spk_mode_var,
            value="range", command=self._on_spk_mode,
        ).grid(row=2, column=0, sticky="w")
        rng_frame = ttk.Frame(self.spk_frame)
        rng_frame.grid(row=2, column=1, sticky="w", padx=(6, 0))
        ttk.Label(rng_frame, text="min:").pack(side="left")
        self.min_spk_var = tk.IntVar(value=2)
        self.min_spk_spin = ttk.Spinbox(rng_frame, from_=1, to=20, textvariable=self.min_spk_var, width=4)
        self.min_spk_spin.pack(side="left", padx=(2, 8))
        ttk.Label(rng_frame, text="max:").pack(side="left")
        self.max_spk_var = tk.IntVar(value=6)
        self.max_spk_spin = ttk.Spinbox(rng_frame, from_=1, to=20, textvariable=self.max_spk_var, width=4)
        self.max_spk_spin.pack(side="left", padx=(2, 0))
        self._on_spk_mode()

        # ---- Action buttons --------------------------------------------
        btn_frame = ttk.Frame(main)
        btn_frame.grid(row=7, column=0, sticky="ew", pady=(0, 8))
        self.run_btn = ttk.Button(btn_frame, text="Transcribe", command=self._start)
        self.run_btn.pack(side="left", padx=(0, 6))
        self.cancel_btn = ttk.Button(btn_frame, text="Cancel", command=self._cancel, state="disabled")
        self.cancel_btn.pack(side="left", padx=(0, 12))
        self.progress_var = tk.StringVar(value="")
        ttk.Label(btn_frame, textvariable=self.progress_var, foreground="#666").pack(side="left")

        # ---- Log --------------------------------------------------------
        ttk.Label(main, text="Log", font=("", 10, "bold")).grid(row=8, column=0, sticky="w", pady=(4, 4))
        log_frame = ttk.Frame(main)
        log_frame.grid(row=9, column=0, sticky="nsew")
        main.rowconfigure(9, weight=1)
        log_frame.columnconfigure(0, weight=1)
        log_frame.rowconfigure(0, weight=1)

        mono = "Consolas" if platform.system() == "Windows" else "Menlo" if platform.system() == "Darwin" else "Monospace"
        self.log_text = tk.Text(
            log_frame, height=10, wrap="word", state="disabled",
            font=(mono, 9), background="#1e1e1e", foreground="#e0e0e0",
            insertbackground="#e0e0e0", relief="flat", padx=8, pady=6,
        )
        self.log_text.grid(row=0, column=0, sticky="nsew")
        log_scroll = ttk.Scrollbar(log_frame, orient="vertical", command=self.log_text.yview)
        log_scroll.grid(row=0, column=1, sticky="ns")
        self.log_text["yscrollcommand"] = log_scroll.set

        # ---- GPU status row (NVIDIA only) -------------------------------
        self.gpu_status_var = tk.StringVar(value="")
        gpu_row = ttk.Frame(main)
        gpu_row.grid(row=10, column=0, sticky="ew", pady=(4, 0))
        ttk.Label(gpu_row, textvariable=self.gpu_status_var, foreground="#888").pack(side="left")

    # -- DnD -----------------------------------------------------------

    def _enable_dnd(self):
        # Register the whole window so dropping anywhere works, plus the file
        # entry specifically so the cursor shows the right affordance there.
        for widget in (self, self.file_entry):
            try:
                widget.drop_target_register(DND_FILES)
                widget.dnd_bind("<<Drop>>", self._on_dnd_drop)
            except Exception:
                pass

    def _on_dnd_drop(self, event):
        # event.data on Windows looks like: "{C:/Users/x/My Audio.wav}"
        # On Linux/macOS without braces. tk.splitlist handles both.
        try:
            paths = self.tk.splitlist(event.data)
        except tk.TclError:
            paths = [event.data]
        for raw in paths:
            path = raw.strip().strip("{}")
            if path and os.path.isfile(path):
                ext = Path(path).suffix.lower()
                if ext in ACCEPTED_EXTENSIONS:
                    self._load_audio_file(path)
                    return
                self._log(f"Unsupported file extension: {ext}")
                return

    # -- GPU monitor ---------------------------------------------------

    def _gpu_monitor_start(self):
        # Only NVIDIA for now -- pyannote-side ROCm support exists but rocm-smi
        # has a different output format and is rarer on consumer machines.
        if GPU_TYPE != "cuda" or not shutil.which("nvidia-smi"):
            return
        self._gpu_monitor_tick()

    def _gpu_monitor_tick(self):
        try:
            r = subprocess.run(
                [
                    "nvidia-smi",
                    "--query-gpu=utilization.gpu,memory.used,memory.total,power.draw",
                    "--format=csv,noheader,nounits",
                ],
                capture_output=True, text=True, timeout=2,
                creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
            )
            if r.returncode == 0 and r.stdout.strip():
                line = r.stdout.strip().splitlines()[0]
                parts = [p.strip() for p in line.split(",")]
                if len(parts) >= 3:
                    util = parts[0]
                    try:
                        mem_used_gb = float(parts[1]) / 1024.0
                        mem_total_gb = float(parts[2]) / 1024.0
                        mem_text = f"{mem_used_gb:.1f}/{mem_total_gb:.1f} GB"
                    except ValueError:
                        mem_text = f"{parts[1]}/{parts[2]} MiB"
                    power_text = ""
                    if len(parts) >= 4 and parts[3] not in ("[N/A]", "[Not Supported]", ""):
                        try:
                            power_text = f"  |  {float(parts[3]):.0f} W"
                        except ValueError:
                            power_text = f"  |  {parts[3]} W"
                    self.gpu_status_var.set(
                        f"GPU: {util}% util  |  {mem_text}{power_text}"
                    )
        except Exception:
            pass
        self._gpu_after_id = self.after(2000, self._gpu_monitor_tick)

    def destroy(self):
        if self._gpu_after_id is not None:
            try:
                self.after_cancel(self._gpu_after_id)
            except Exception:
                pass
        super().destroy()

    # -- UI helpers ----------------------------------------------------

    def _log(self, msg):
        self.log_text.configure(state="normal")
        self.log_text.insert("end", msg + "\n")
        self.log_text.see("end")
        self.log_text.configure(state="disabled")

    def _log_thread(self, msg):
        self.after(0, self._log, msg)

    def _on_diarize_toggle(self):
        state = "normal" if self.diarize_var.get() else "disabled"
        _set_subtree_state(self.spk_frame, state)
        # After enabling, re-apply the active sub-mode so the inactive spinboxes
        # remain disabled.
        if state == "normal":
            self._on_spk_mode()

    def _on_spk_mode(self):
        mode = self.spk_mode_var.get()
        self.num_spk_spin.configure(state=("normal" if mode == "exact" else "disabled"))
        rng_state = "normal" if mode == "range" else "disabled"
        self.min_spk_spin.configure(state=rng_state)
        self.max_spk_spin.configure(state=rng_state)

    def _browse_input(self):
        patterns = " ".join(f"*{ext}" for ext in ACCEPTED_EXTENSIONS)
        path = filedialog.askopenfilename(
            title="Choose an audio file",
            filetypes=[("Audio files", patterns), ("All files", "*.*")],
        )
        if path:
            self._load_audio_file(path)

    def _browse_outdir(self):
        path = filedialog.askdirectory(
            title="Choose an output folder",
            initialdir=self.outdir_var.get() or str(Path.home()),
        )
        if path:
            self.outdir_var.set(path)

    def _load_audio_file(self, path):
        self.input_path = path
        self.file_var.set(path)
        try:
            dur = get_audio_duration(path)
            self.audio_duration = dur
            m, s = divmod(dur, 60)
            h, m = divmod(m, 60)
            self.duration_var.set(f"Duration: {int(h):02d}:{int(m):02d}:{s:05.2f}")
            self._log(f"Loaded: {Path(path).name}")
            est = dur * (0.1 if self.gpu_var.get() else 0.4)
            if self.diarize_var.get():
                est += dur * (0.05 if self.gpu_var.get() else 0.15)
            self._log(f"  Estimated processing time: ~{_fmt_duration(est)}")
        except Exception as e:
            self.audio_duration = 0.0
            self.duration_var.set("")
            self._log(f"Could not read audio duration: {e}")

    # -- ETR -----------------------------------------------------------

    def _etr_start(self, phase, est_seconds):
        self._etr_phase = phase
        self._etr_phase_start = time.time()
        self._etr_est_total = est_seconds
        self._etr_tick()

    def _etr_tick(self):
        if not self.running:
            self._etr_after_id = None
            return
        elapsed = time.time() - self._etr_phase_start
        remaining = max(0, self._etr_est_total - elapsed)
        self.progress_var.set(
            f"{self._etr_phase}  |  {_fmt_duration(elapsed)} elapsed"
            f"  |  ~{_fmt_duration(remaining)} remaining"
        )
        self._etr_after_id = self.after(1000, self._etr_tick)

    def _etr_stop(self):
        if self._etr_after_id is not None:
            self.after_cancel(self._etr_after_id)
            self._etr_after_id = None

    # -- Pipeline orchestration ---------------------------------------

    def _start(self):
        if not self.input_path or not os.path.isfile(self.input_path):
            messagebox.showerror("No audio file", "Click Browse and select an audio file first.")
            return
        outdir = self.outdir_var.get().strip()
        if not outdir:
            messagebox.showerror("No output folder", "Set an output folder.")
            return
        try:
            os.makedirs(outdir, exist_ok=True)
        except OSError as e:
            messagebox.showerror("Cannot create folder", f"Could not create {outdir!r}: {e}")
            return

        self.running = True
        self.run_btn.state(["disabled"])
        self.cancel_btn.state(["!disabled"])
        self.progress_var.set("Working...")

        thread = threading.Thread(
            target=self._run_pipeline, args=(self.input_path, outdir), daemon=True
        )
        thread.start()

    def _cancel(self):
        self.running = False
        self._log_thread("Cancelling after current step...")

    def _run_pipeline(self, input_path, outdir):
        try:
            t_total = time.time()
            use_gpu = self.gpu_var.get()
            dur = self.audio_duration or 0
            whisper_rate = 0.1 if use_gpu else 0.4
            diarize_rate = 0.05 if use_gpu else 0.15

            self.after(0, self.progress_var.set, "Converting audio...")
            self._log_thread("Preparing audio (converting to 16kHz WAV)...")
            if use_gpu:
                self._log_thread(f"  GPU acceleration: enabled ({GPU_NAME})")
            wav_path = convert_to_wav(input_path)

            if not self.running:
                self._finish("Cancelled.")
                return

            est_w = dur * whisper_rate
            self._log_thread(f"Transcribing with Whisper large-v3 (est. {_fmt_duration(est_w)})...")
            self.after(0, self._etr_start, "Transcribing", est_w)
            t0 = time.time()
            segments = run_whisper(
                wav_path, self.lang_var.get(), int(self.threads_var.get()),
                self._log_thread, use_gpu=use_gpu,
            )
            t_w = time.time() - t0
            self.after(0, self._etr_stop)
            self._log_thread(f"  Transcription complete: {len(segments)} segments in {t_w:.1f}s")

            if not self.running:
                self._finish("Cancelled.")
                return

            if self.diarize_var.get():
                est_d = dur * diarize_rate
                self._log_thread(f"Running speaker diarization (est. {_fmt_duration(est_d)})...")
                self.after(0, self._etr_start, "Diarizing", est_d)
                t0 = time.time()
                mode = self.spk_mode_var.get()
                num_spk = int(self.num_spk_var.get()) if mode == "exact" else None
                min_spk = int(self.min_spk_var.get()) if mode == "range" else None
                max_spk = int(self.max_spk_var.get()) if mode == "range" else None
                diarization = run_diarization(
                    wav_path, num_spk, min_spk, max_spk,
                    self._log_thread, use_gpu=use_gpu,
                )
                self.after(0, self._etr_stop)
                t_d = time.time() - t0
                speakers = set(d["speaker"] for d in diarization)
                self._log_thread(f"  Diarization complete: {len(speakers)} speakers in {t_d:.1f}s")
                segments = assign_speakers(segments, diarization)
            else:
                for seg in segments:
                    seg["speaker"] = "SPEAKER"

            if not self.running:
                self._finish("Cancelled.")
                return

            fmt = self.fmt_var.get()
            ext = FORMAT_EXTENSIONS[fmt]
            stem = Path(input_path).stem
            out_path = os.path.join(outdir, f"{stem}{ext}")
            counter = 1
            while os.path.exists(out_path):
                out_path = os.path.join(outdir, f"{stem}_{counter}{ext}")
                counter += 1

            output = format_output(segments, fmt)
            with open(out_path, "w", encoding="utf-8") as f:
                f.write(output)

            t_total = time.time() - t_total
            self._log_thread(f"\nDone in {t_total:.1f}s")
            self._log_thread(f"Output saved to: {out_path}")

            if wav_path != input_path:
                try:
                    os.unlink(wav_path)
                except OSError:
                    pass

            self._finish(None)
            self.after(0, open_folder, outdir)

        except Exception as e:
            self._log_thread(f"\nERROR: {e}")
            self._finish(str(e))

    def _finish(self, error_msg):
        def _do():
            self.running = False
            self._etr_stop()
            self.run_btn.state(["!disabled"])
            self.cancel_btn.state(["disabled"])
            self.progress_var.set("" if error_msg else "Done")
            if error_msg:
                self._log(error_msg)
        self.after(0, _do)


def main():
    try:
        os.makedirs(DEFAULT_OUTDIR, exist_ok=True)
    except OSError:
        pass

    app = TranscribeApp()
    if len(sys.argv) > 1 and os.path.isfile(sys.argv[1]):
        app.after(100, app._load_audio_file, sys.argv[1])
    app.mainloop()


if __name__ == "__main__":
    main()
