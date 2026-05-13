#!/usr/bin/env python3
"""
GTK4 GUI for Whisper Large-v3 transcription with speaker diarization.
Native Wayland drag-and-drop support.
"""

import json
import os
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

import gi
gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Gtk, Adw, Gio, Gdk, GLib

from config import WHISPER_CLI, WHISPER_MODEL, DEFAULT_OUTDIR

ACCEPTED_EXTENSIONS = {".wav", ".mp3", ".flac", ".ogg", ".m4a", ".wma", ".aac", ".opus", ".webm"}

OUTPUT_FORMATS = {"Text (.txt)": "text", "JSON (.json)": "json", "SRT subtitles (.srt)": "srt"}
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


# ── Audio helpers ──────────────────────────────────────────────────────────────

def convert_to_wav(input_path: str) -> str:
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


def get_audio_duration(path: str) -> float:
    import soundfile as sf
    return sf.info(path).duration


# ── Core pipeline ─────────────────────────────────────────────────────────────

def run_whisper(wav_path, language, threads, log_fn):
    with tempfile.TemporaryDirectory() as tmpdir:
        out_base = os.path.join(tmpdir, "out")
        cmd = [
            str(WHISPER_CLI), "-m", str(WHISPER_MODEL),
            "-f", wav_path, "-t", str(threads),
            "--no-gpu", "-oj", "-of", out_base, "-l", language,
        ]
        log_fn(f"  Command: {' '.join(cmd[:6])}...")
        result = subprocess.run(cmd, capture_output=True, text=True)
        if result.returncode != 0:
            raise RuntimeError(f"whisper.cpp failed:\n{result.stderr}")
        with open(out_base + ".json") as f:
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


def _ts_to_seconds(ts):
    ts = ts.replace(",", ".")
    parts = ts.split(":")
    return int(parts[0]) * 3600 + int(parts[1]) * 60 + float(parts[2])


def run_diarization(wav_path, num_speakers, min_speakers, max_speakers, log_fn):
    import warnings
    warnings.filterwarnings("ignore")
    import numpy as np
    import soundfile as sf
    import torch
    from pyannote.audio import Pipeline

    log_fn("  Loading pyannote pipeline...")
    pipeline = Pipeline.from_pretrained("pyannote/speaker-diarization-3.1")
    pipeline.to(torch.device("cpu"))

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
    elif fmt == "srt":
        lines = []
        for i, seg in enumerate(segments, 1):
            start = format_timestamp(seg["start"]).replace(".", ",")
            end = format_timestamp(seg["end"]).replace(".", ",")
            lines += [str(i), f"{start} --> {end}", f"[{seg['speaker']}] {seg['text']}", ""]
        return "\n".join(lines)
    else:
        lines, cur = [], None
        for seg in segments:
            if seg["speaker"] != cur:
                cur = seg["speaker"]
                lines.append(f"\n[{cur}]")
            lines.append(f"  [{format_timestamp(seg['start'])} -> {format_timestamp(seg['end'])}] {seg['text']}")
        return "\n".join(lines).strip()


def open_folder(path):
    """Open a folder in the system file manager."""
    subprocess.Popen(["xdg-open", path])


# ── GTK4 App ──────────────────────────────────────────────────────────────────

class TranscribeWindow(Adw.ApplicationWindow):
    def __init__(self, app):
        super().__init__(application=app, title="Whisper Transcribe + Diarization",
                         default_width=820, default_height=750)
        self.running = False
        self.input_path = None
        self._build_ui()

    def _build_ui(self):
        main_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)
        self.set_content(main_box)

        header = Adw.HeaderBar()
        main_box.append(header)

        scroll = Gtk.ScrolledWindow(vexpand=True)
        scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        main_box.append(scroll)

        content = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12,
                          margin_start=16, margin_end=16, margin_top=12, margin_bottom=12)
        scroll.set_child(content)

        # ── Drop zone ────────────────────────────────────────────────────
        self.drop_frame = Gtk.Frame()
        self.drop_frame.add_css_class("card")
        content.append(self.drop_frame)

        drop_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8,
                           margin_start=20, margin_end=20, margin_top=24, margin_bottom=24,
                           halign=Gtk.Align.CENTER)
        self.drop_frame.set_child(drop_box)

        self.drop_icon = Gtk.Image.new_from_icon_name("document-open-symbolic")
        self.drop_icon.set_pixel_size(48)
        self.drop_icon.add_css_class("dim-label")
        drop_box.append(self.drop_icon)

        self.drop_label = Gtk.Label(label="Drop audio file here or click to browse")
        self.drop_label.add_css_class("title-3")
        drop_box.append(self.drop_label)

        self.drop_formats = Gtk.Label(label="WAV  MP3  FLAC  OGG  M4A  WMA  AAC  OPUS  WEBM")
        self.drop_formats.add_css_class("dim-label")
        drop_box.append(self.drop_formats)

        click = Gtk.GestureClick()
        click.connect("released", self._on_drop_click)
        self.drop_frame.add_controller(click)

        drop_target = Gtk.DropTarget.new(Gio.File, Gdk.DragAction.COPY)
        drop_target.connect("drop", self._on_file_drop)
        drop_target.connect("enter", self._on_drop_enter)
        drop_target.connect("leave", self._on_drop_leave)
        self.drop_frame.add_controller(drop_target)

        # File info row
        file_row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        content.append(file_row)

        self.file_label = Gtk.Label(label="No file selected", hexpand=True,
                                    xalign=0, ellipsize=3)
        self.file_label.add_css_class("dim-label")
        file_row.append(self.file_label)

        self.duration_label = Gtk.Label(label="")
        self.duration_label.add_css_class("dim-label")
        file_row.append(self.duration_label)

        # ── Output section ───────────────────────────────────────────────
        out_group = Adw.PreferencesGroup(title="Output")
        content.append(out_group)

        self.outdir_row = Adw.ActionRow(title="Output folder", subtitle=DEFAULT_OUTDIR)
        browse_out_btn = Gtk.Button(icon_name="folder-open-symbolic", valign=Gtk.Align.CENTER)
        browse_out_btn.connect("clicked", self._browse_outdir)
        self.outdir_row.add_suffix(browse_out_btn)
        self.outdir_row.set_activatable_widget(browse_out_btn)
        out_group.add(self.outdir_row)

        fmt_row = Adw.ActionRow(title="Format")
        fmt_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=0,
                          valign=Gtk.Align.CENTER)
        fmt_box.add_css_class("linked")

        self.fmt_buttons = {}
        first = None
        for label in OUTPUT_FORMATS:
            btn = Gtk.ToggleButton(label=label)
            if first is None:
                first = btn
                btn.set_active(True)
            else:
                btn.set_group(first)
            self.fmt_buttons[label] = btn
            fmt_box.append(btn)

        fmt_row.add_suffix(fmt_box)
        out_group.add(fmt_row)

        # ── Settings section ─────────────────────────────────────────────
        settings_group = Adw.PreferencesGroup(title="Settings")
        content.append(settings_group)

        self.lang_row = Adw.ComboRow(title="Language")
        lang_list = Gtk.StringList()
        for lang in LANGUAGES:
            lang_list.append(lang)
        self.lang_row.set_model(lang_list)
        self.lang_row.set_selected(1)  # "en"
        settings_group.add(self.lang_row)

        self.threads_row = Adw.SpinRow.new_with_range(1, 32, 1)
        self.threads_row.set_title("CPU threads")
        self.threads_row.set_value(16)
        settings_group.add(self.threads_row)

        self.diarize_row = Adw.SwitchRow(title="Speaker diarization",
                                         subtitle="Identify individual speakers")
        self.diarize_row.set_active(True)
        self.diarize_row.connect("notify::active", self._on_diarize_toggle)
        settings_group.add(self.diarize_row)

        # Speaker settings group
        self.speaker_group = Adw.PreferencesGroup(title="Speaker Detection")
        content.append(self.speaker_group)

        self.speaker_mode_auto = Gtk.CheckButton(label="Auto-detect speakers")
        self.speaker_mode_exact = Gtk.CheckButton(label="Exact count")
        self.speaker_mode_range = Gtk.CheckButton(label="Range")
        self.speaker_mode_exact.set_group(self.speaker_mode_auto)
        self.speaker_mode_range.set_group(self.speaker_mode_auto)
        self.speaker_mode_auto.set_active(True)

        auto_row = Adw.ActionRow(title="Auto-detect speakers",
                                 subtitle="Let pyannote determine the number of speakers")
        auto_row.add_prefix(self.speaker_mode_auto)
        auto_row.set_activatable_widget(self.speaker_mode_auto)
        self.speaker_group.add(auto_row)

        exact_row = Adw.ActionRow(title="Exact speaker count")
        exact_row.add_prefix(self.speaker_mode_exact)
        exact_row.set_activatable_widget(self.speaker_mode_exact)
        self.num_speakers_spin = Gtk.SpinButton.new_with_range(1, 20, 1)
        self.num_speakers_spin.set_value(2)
        self.num_speakers_spin.set_valign(Gtk.Align.CENTER)
        exact_row.add_suffix(self.num_speakers_spin)
        self.speaker_group.add(exact_row)

        range_row = Adw.ActionRow(title="Speaker range")
        range_row.add_prefix(self.speaker_mode_range)
        range_row.set_activatable_widget(self.speaker_mode_range)
        range_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8,
                            valign=Gtk.Align.CENTER)
        range_box.append(Gtk.Label(label="min:"))
        self.min_speakers_spin = Gtk.SpinButton.new_with_range(1, 20, 1)
        self.min_speakers_spin.set_value(2)
        range_box.append(self.min_speakers_spin)
        range_box.append(Gtk.Label(label="max:"))
        self.max_speakers_spin = Gtk.SpinButton.new_with_range(1, 20, 1)
        self.max_speakers_spin.set_value(6)
        range_box.append(self.max_speakers_spin)
        range_row.add_suffix(range_box)
        self.speaker_group.add(range_row)

        # ── Action buttons ───────────────────────────────────────────────
        btn_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8,
                          margin_top=4)
        content.append(btn_box)

        self.run_btn = Gtk.Button(label="Transcribe")
        self.run_btn.add_css_class("suggested-action")
        self.run_btn.add_css_class("pill")
        self.run_btn.connect("clicked", self._start)
        btn_box.append(self.run_btn)

        self.cancel_btn = Gtk.Button(label="Cancel")
        self.cancel_btn.add_css_class("pill")
        self.cancel_btn.set_sensitive(False)
        self.cancel_btn.connect("clicked", self._cancel)
        btn_box.append(self.cancel_btn)

        self.spinner = Gtk.Spinner()
        btn_box.append(self.spinner)

        self.progress_label = Gtk.Label(label="", hexpand=True, xalign=0)
        self.progress_label.add_css_class("dim-label")
        btn_box.append(self.progress_label)

        # ── Log ──────────────────────────────────────────────────────────
        log_frame = Gtk.Frame(vexpand=True)
        log_frame.add_css_class("card")
        content.append(log_frame)

        log_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)
        log_frame.set_child(log_box)

        log_header = Gtk.Label(label="Log", xalign=0, margin_start=12, margin_top=8,
                               margin_bottom=4)
        log_header.add_css_class("heading")
        log_box.append(log_header)

        log_scroll = Gtk.ScrolledWindow(vexpand=True, min_content_height=180)
        log_scroll.set_policy(Gtk.PolicyType.AUTOMATIC, Gtk.PolicyType.AUTOMATIC)
        log_box.append(log_scroll)

        self.log_view = Gtk.TextView(editable=False, cursor_visible=False,
                                     monospace=True, wrap_mode=Gtk.WrapMode.WORD_CHAR,
                                     margin_start=12, margin_end=12,
                                     margin_top=4, margin_bottom=8)
        log_scroll.set_child(self.log_view)
        self.log_buffer = self.log_view.get_buffer()
        self.log_scroll = log_scroll

        self._log("Ready. Drop an audio file or click the input area to browse.")
        self._log(f"Model: {Path(WHISPER_MODEL).name}")
        self._log(f"Output folder: {DEFAULT_OUTDIR}")

    # ── Drop handlers ─────────────────────────────────────────────────────

    def _on_file_drop(self, target, value, x, y):
        if not isinstance(value, Gio.File):
            return False
        path = value.get_path()
        if not path:
            path = value.get_uri()
            if path and path.startswith("file://"):
                from urllib.parse import unquote, urlparse
                path = unquote(urlparse(path).path)
        if path and os.path.isfile(path):
            ext = Path(path).suffix.lower()
            if ext in ACCEPTED_EXTENSIONS:
                self._load_audio_file(path)
                return True
            else:
                self._log(f"Unsupported format: {ext}")
        return False

    def _on_drop_enter(self, target, x, y):
        self.drop_frame.add_css_class("accent")
        return Gdk.DragAction.COPY

    def _on_drop_leave(self, target):
        self.drop_frame.remove_css_class("accent")

    def _on_drop_click(self, gesture, n_press, x, y):
        self._browse_input()

    # ── File loading ──────────────────────────────────────────────────────

    def _load_audio_file(self, path):
        self.input_path = path
        name = Path(path).name
        self.drop_label.set_text(name)
        self.drop_formats.set_text("Drop another file to replace")
        self.drop_icon.set_from_icon_name("audio-x-generic-symbolic")
        self.file_label.set_text(path)
        self.file_label.remove_css_class("dim-label")

        try:
            dur = get_audio_duration(path)
            m, s = divmod(dur, 60)
            h, m = divmod(m, 60)
            ts = f"{int(h):02d}:{int(m):02d}:{s:05.2f}"
            self.duration_label.set_text(ts)
            est_minutes = dur * 0.4 / 60
            if self.diarize_row.get_active():
                est_minutes += dur * 0.15 / 60
            self._log(f"Loaded: {name} ({ts})")
            self._log(f"Estimated processing time: ~{max(1, int(est_minutes))} minutes")
        except Exception:
            self.duration_label.set_text("")

    def _browse_input(self):
        dialog = Gtk.FileDialog()
        audio_filter = Gtk.FileFilter()
        audio_filter.set_name("Audio files")
        for ext in ACCEPTED_EXTENSIONS:
            audio_filter.add_pattern(f"*{ext}")
        filters = Gio.ListStore.new(Gtk.FileFilter)
        filters.append(audio_filter)
        all_filter = Gtk.FileFilter()
        all_filter.set_name("All files")
        all_filter.add_pattern("*")
        filters.append(all_filter)
        dialog.set_filters(filters)
        dialog.set_default_filter(audio_filter)
        dialog.open(self, None, self._on_file_chosen)

    def _on_file_chosen(self, dialog, result):
        try:
            f = dialog.open_finish(result)
            if f:
                self._load_audio_file(f.get_path())
        except GLib.Error:
            pass

    def _browse_outdir(self, btn):
        dialog = Gtk.FileDialog()
        dialog.set_initial_folder(Gio.File.new_for_path(self.outdir_row.get_subtitle()))
        dialog.select_folder(self, None, self._on_outdir_chosen)

    def _on_outdir_chosen(self, dialog, result):
        try:
            f = dialog.select_folder_finish(result)
            if f:
                self.outdir_row.set_subtitle(f.get_path())
        except GLib.Error:
            pass

    def _on_diarize_toggle(self, row, param):
        self.speaker_group.set_sensitive(row.get_active())

    # ── Logging ───────────────────────────────────────────────────────────

    def _log(self, msg):
        end = self.log_buffer.get_end_iter()
        self.log_buffer.insert(end, msg + "\n")
        GLib.idle_add(self._scroll_log)

    def _scroll_log(self):
        adj = self.log_scroll.get_vadjustment()
        adj.set_value(adj.get_upper())
        return False

    def _log_thread(self, msg):
        GLib.idle_add(self._log, msg)

    # ── Pipeline ──────────────────────────────────────────────────────────

    def _get_selected_format(self):
        for label, btn in self.fmt_buttons.items():
            if btn.get_active():
                return OUTPUT_FORMATS[label]
        return "text"

    def _get_selected_language(self):
        idx = self.lang_row.get_selected()
        return LANGUAGES[idx] if idx < len(LANGUAGES) else "en"

    def _start(self, btn):
        if not self.input_path or not os.path.isfile(self.input_path):
            self._log("ERROR: No valid audio file selected.")
            return

        outdir = self.outdir_row.get_subtitle()
        if not outdir:
            self._log("ERROR: No output folder selected.")
            return
        os.makedirs(outdir, exist_ok=True)

        self.running = True
        self.run_btn.set_sensitive(False)
        self.cancel_btn.set_sensitive(True)
        self.spinner.start()
        self.progress_label.set_text("Working...")

        thread = threading.Thread(
            target=self._run_pipeline,
            args=(self.input_path, outdir),
            daemon=True,
        )
        thread.start()

    def _cancel(self, btn):
        self.running = False
        self._log_thread("Cancelling after current step...")

    def _run_pipeline(self, input_path, outdir):
        try:
            t_total = time.time()

            GLib.idle_add(self.progress_label.set_text, "Converting audio...")
            self._log_thread("Preparing audio (converting to 16kHz WAV)...")
            wav_path = convert_to_wav(input_path)

            if not self.running:
                self._finish("Cancelled.")
                return

            GLib.idle_add(self.progress_label.set_text, "Transcribing...")
            self._log_thread("Transcribing with Whisper large-v3...")
            t0 = time.time()
            threads = int(self.threads_row.get_value())
            language = self._get_selected_language()
            segments = run_whisper(wav_path, language, threads, self._log_thread)
            t_w = time.time() - t0
            self._log_thread(f"  Transcription complete: {len(segments)} segments in {t_w:.1f}s")

            if not self.running:
                self._finish("Cancelled.")
                return

            if self.diarize_row.get_active():
                GLib.idle_add(self.progress_label.set_text, "Diarizing speakers...")
                self._log_thread("Running speaker diarization...")
                t0 = time.time()

                num_spk = min_spk = max_spk = None
                if self.speaker_mode_exact.get_active():
                    num_spk = int(self.num_speakers_spin.get_value())
                elif self.speaker_mode_range.get_active():
                    min_spk = int(self.min_speakers_spin.get_value())
                    max_spk = int(self.max_speakers_spin.get_value())

                diarization = run_diarization(wav_path, num_spk, min_spk, max_spk, self._log_thread)
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

            fmt = self._get_selected_format()
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
                os.unlink(wav_path)

            self._finish(None)
            GLib.idle_add(open_folder, outdir)

        except Exception as e:
            self._log_thread(f"\nERROR: {e}")
            self._finish(str(e))

    def _finish(self, error_msg):
        def _do():
            self.running = False
            self.run_btn.set_sensitive(True)
            self.cancel_btn.set_sensitive(False)
            self.spinner.stop()
            self.progress_label.set_text("Done" if not error_msg else "")
            if error_msg:
                self._log(error_msg)
        GLib.idle_add(_do)


# ── Application ───────────────────────────────────────────────────────────────

class TranscribeApp(Adw.Application):
    def __init__(self):
        super().__init__(application_id="com.whisper.transcribe",
                         flags=Gio.ApplicationFlags.HANDLES_OPEN)
        self.connect("activate", self._on_activate)
        self.connect("open", self._on_open)
        self.window = None

    def _on_activate(self, app):
        if not self.window:
            self.window = TranscribeWindow(self)
        self.window.present()

    def _on_open(self, app, files, n_files, hint):
        self._on_activate(app)
        if files:
            path = files[0].get_path()
            if path and os.path.isfile(path):
                self.window._load_audio_file(path)


def main():
    app = TranscribeApp()
    app.run(sys.argv)


if __name__ == "__main__":
    main()
