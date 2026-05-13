#Requires -Version 5.1
<#
.SYNOPSIS
    Speech2Text — One-Click Launcher (Windows)
    https://github.com/routine88/Speech2Text

.DESCRIPTION
    Place this file anywhere. Double-click launch.bat (or run this script).
    First run:  installs everything automatically (~10-15 min)
    After that: pulls latest code + launches (~2 sec)
#>

$ErrorActionPreference = "Continue"

$REPO_URL    = "https://github.com/routine88/Speech2Text.git"
$RAW_URL     = "https://raw.githubusercontent.com/routine88/Speech2Text/main/launch.ps1"
$REPO_DIR    = if ($env:S2T_REPO_DIR)       { $env:S2T_REPO_DIR }       else { Join-Path $HOME "Speech2Text" }
$WHISPER_DIR = if ($env:WHISPER_DIR)         { $env:WHISPER_DIR }         else { Join-Path $HOME "whisper.cpp" }
$MODEL       = if ($env:WHISPER_MODEL_NAME)  { $env:WHISPER_MODEL_NAME }  else { "large-v3" }
$SELF        = $MyInvocation.MyCommand.Path

# ── Helpers ───────────────────────────────────────────────────
function Write-Info  ($msg) { Write-Host "[.]  $msg" -ForegroundColor Cyan }
function Write-Ok    ($msg) { Write-Host "[OK] $msg" -ForegroundColor Green }
function Write-Warn  ($msg) { Write-Host "[!]  $msg" -ForegroundColor Yellow }
function Write-Err   ($msg) { Write-Host "[X]  $msg" -ForegroundColor Red }
function Write-Header($msg) { Write-Host "`n-- $msg --" -ForegroundColor White }

function Test-Command($cmd) { $null -ne (Get-Command $cmd -ErrorAction SilentlyContinue) }

function Install-Winget($packageId, $name) {
    Write-Info "Installing $name via winget..."
    $result = winget install --id $packageId --accept-source-agreements --accept-package-agreements -e 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Ok "$name installed"
        # Refresh PATH so the new tool is available immediately
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
        return $true
    } else {
        Write-Err "Failed to install $name"
        Write-Err ($result | Out-String)
        return $false
    }
}

# ── Phase 0: Self-Update ─────────────────────────────────────
if ($env:S2T_SELF_UPDATED -ne "1" -and $SELF) {
    $tmp = [System.IO.Path]::GetTempFileName()
    try {
        Invoke-WebRequest -Uri $RAW_URL -OutFile $tmp -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
        $curHash = (Get-FileHash $SELF -Algorithm SHA256).Hash
        $newHash = (Get-FileHash $tmp -Algorithm SHA256).Hash
        if ($curHash -ne $newHash) {
            Copy-Item $tmp $SELF -Force
            Remove-Item $tmp -ErrorAction SilentlyContinue
            $env:S2T_SELF_UPDATED = "1"
            Write-Info "Launcher updated. Restarting..."
            & powershell -ExecutionPolicy Bypass -NoProfile -File $SELF @args
            exit
        }
    } catch {
        Write-Warn "Could not check for launcher updates (offline?)"
    }
    Remove-Item $tmp -ErrorAction SilentlyContinue
}

# ── Prerequisite: winget ──────────────────────────────────────
$hasWinget = Test-Command "winget"
if (-not $hasWinget) {
    Write-Warn "winget not found. Will try to install dependencies manually."
    Write-Warn "For best experience, install App Installer from the Microsoft Store."
}

# ── Prerequisite: Git ─────────────────────────────────────────
if (-not (Test-Command "git")) {
    Write-Header "Installing Git"
    if ($hasWinget) {
        if (-not (Install-Winget "Git.Git" "Git")) {
            Write-Err "Cannot proceed without Git. Please install Git manually and rerun."
            Read-Host "Press Enter to exit"
            exit 1
        }
    } else {
        Write-Err "Git is required. Download from: https://git-scm.com/download/win"
        Read-Host "Press Enter to exit"
        exit 1
    }
}

# ── Phase 1: Repo Sync ───────────────────────────────────────
Write-Header "Syncing code"

if (Test-Path (Join-Path $REPO_DIR ".git")) {
    $pullOutput = git -C $REPO_DIR pull --ff-only origin main 2>&1
    if ($pullOutput -match "Already up to date") {
        Write-Ok "Already up to date"
    } else {
        Write-Ok "Code updated"
    }
} else {
    Write-Info "First run - cloning Speech2Text..."
    git clone $REPO_URL $REPO_DIR
    Write-Ok "Repository cloned to $REPO_DIR"
}

# Copy repo's launch.ps1 over self
$repoLauncher = Join-Path $REPO_DIR "launch.ps1"
if ($SELF -and (Test-Path $repoLauncher)) {
    $curHash = (Get-FileHash $SELF -Algorithm SHA256).Hash
    $repoHash = (Get-FileHash $repoLauncher -Algorithm SHA256).Hash
    if ($curHash -ne $repoHash) {
        Copy-Item $repoLauncher $SELF -Force
    }
}

# ── Phase 2: State Check ─────────────────────────────────────
$STATE_DIR = Join-Path $REPO_DIR ".s2t_state"
$VENV_DIR  = Join-Path $REPO_DIR "venv"
New-Item -ItemType Directory -Path $STATE_DIR -Force | Out-Null

# ── Auto-install system dependencies ─────────────────────────
$needsRestart = $false

# Python
$PYTHON = $null
foreach ($candidate in @("python3", "python", "py")) {
    if (Test-Command $candidate) {
        try {
            $verOut = & $candidate --version 2>&1
            if ($verOut -match "(\d+)\.(\d+)") {
                $major = [int]$Matches[1]; $minor = [int]$Matches[2]
                if ($major -ge 3 -and $minor -ge 10) {
                    $PYTHON = $candidate
                    break
                }
            }
        } catch {}
    }
}
if (-not $PYTHON) {
    Write-Header "Installing Python"
    if ($hasWinget) {
        Install-Winget "Python.Python.3.12" "Python 3.12" | Out-Null
        # Re-check after install
        foreach ($candidate in @("python3", "python", "py")) {
            if (Test-Command $candidate) {
                try {
                    $verOut = & $candidate --version 2>&1
                    if ($verOut -match "(\d+)\.(\d+)") {
                        $major = [int]$Matches[1]; $minor = [int]$Matches[2]
                        if ($major -ge 3 -and $minor -ge 10) {
                            $PYTHON = $candidate
                            break
                        }
                    }
                } catch {}
            }
        }
    }
    if (-not $PYTHON) {
        Write-Err "Python 3.10+ could not be installed automatically."
        Write-Err "Please install from: https://www.python.org/downloads/"
        Write-Err "Make sure to check 'Add Python to PATH' during install."
        Read-Host "Press Enter to exit"
        exit 1
    }
}
$PYTHON_VER = & $PYTHON --version 2>&1
Write-Ok "Python: $PYTHON_VER"

# CMake
if (-not (Test-Command "cmake")) {
    Write-Header "Installing CMake"
    if ($hasWinget) {
        Install-Winget "Kitware.CMake" "CMake" | Out-Null
    }
    if (-not (Test-Command "cmake")) {
        Write-Err "CMake could not be installed automatically."
        Write-Err "Download from: https://cmake.org/download/"
        Read-Host "Press Enter to exit"
        exit 1
    }
}

# FFmpeg
if (-not (Test-Command "ffmpeg")) {
    Write-Header "Installing FFmpeg"
    if ($hasWinget) {
        Install-Winget "Gyan.FFmpeg" "FFmpeg" | Out-Null
    }
    if (-not (Test-Command "ffmpeg")) {
        Write-Warn "FFmpeg not installed. Non-WAV audio files won't work."
        Write-Warn "Install later with: winget install Gyan.FFmpeg"
    }
}

# C++ Build Tools — check for cl.exe or Visual Studio
$hasCL = $false
if (Test-Command "cl") { $hasCL = $true }
if (-not $hasCL) {
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (Test-Path $vswhere) {
        $vsPath = & $vswhere -latest -property installationPath 2>$null
        if ($vsPath) { $hasCL = $true }
    }
}
if (-not $hasCL) {
    Write-Header "Installing Visual Studio Build Tools"
    if ($hasWinget) {
        Write-Info "Installing C++ build tools (this may take several minutes)..."
        $result = winget install --id Microsoft.VisualStudio.2022.BuildTools `
            --accept-source-agreements --accept-package-agreements `
            --override "--quiet --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended" 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Ok "Visual Studio Build Tools installed"
            $needsRestart = $true
        } else {
            Write-Warn "Build Tools install may need a restart to complete."
            $needsRestart = $true
        }
    } else {
        Write-Err "C++ Build Tools are required to compile whisper.cpp."
        Write-Err "Download: https://visualstudio.microsoft.com/visual-cpp-build-tools/"
        Write-Err "Select 'Desktop development with C++' workload."
        Read-Host "Press Enter to exit"
        exit 1
    }
}

if ($needsRestart) {
    Write-Warn ""
    Write-Warn "Build tools were just installed. You may need to restart your terminal"
    Write-Warn "or reboot for PATH changes to take effect, then double-click launch.bat again."
    Write-Warn ""
    Write-Warn "If you just rebooted and see this again, the install may still be finishing."
    Read-Host "Press Enter to continue anyway (or close and restart)"
}

# GPU detection (CUDA only on Windows)
$GPU_BUILD = ""
$TORCH_INDEX = "https://download.pytorch.org/whl/cpu"
$GPU_TYPE = "none"

$nvidiaSmi = $null
if (Test-Command "nvidia-smi") {
    $nvidiaSmi = "nvidia-smi"
} elseif (Test-Path "C:\Windows\System32\nvidia-smi.exe") {
    $nvidiaSmi = "C:\Windows\System32\nvidia-smi.exe"
}

if ($nvidiaSmi) {
    try {
        $gpuName = & $nvidiaSmi --query-gpu=name --format=csv,noheader 2>$null | Select-Object -First 1
        if ($gpuName) {
            $GPU_TYPE = "cuda"
            $GPU_BUILD = "-DGGML_CUDA=ON"
            $TORCH_INDEX = "https://download.pytorch.org/whl/cu124"
            Write-Ok "NVIDIA GPU: $gpuName (CUDA enabled)"

            if (Test-Command "nvcc") {
                $nvccOut = nvcc --version 2>&1
                if ($nvccOut -match "release (\d+\.\d+)") {
                    $cudaVer = $Matches[1]
                    if ($cudaVer -like "11.*") {
                        $TORCH_INDEX = "https://download.pytorch.org/whl/cu118"
                    }
                }
            }
        }
    } catch {}
} else {
    Write-Info "No NVIDIA GPU detected, using CPU mode"
}

# Determine what needs work
$needsVenv     = $false
$needsPip      = $false
$needsWhisper  = $false
$needsModel    = $false

# Venv
$venvMarker = Join-Path $STATE_DIR "venv"
$activateScript = Join-Path $VENV_DIR "Scripts\Activate.ps1"
if (-not (Test-Path $venvMarker) -or -not (Test-Path $activateScript)) {
    $needsVenv = $true
} elseif ((Get-Content $venvMarker -ErrorAction SilentlyContinue) -ne $PYTHON_VER) {
    $needsVenv = $true
}

# Pip deps (no PyGObject on Windows)
$depString = "numpy soundfile torch torchaudio pyannote.audio|$TORCH_INDEX"
$depHash = (Get-FileHash -InputStream ([System.IO.MemoryStream]::new([System.Text.Encoding]::UTF8.GetBytes($depString))) -Algorithm SHA256).Hash
$pipMarker = Join-Path $STATE_DIR "pip_deps"
if (-not (Test-Path $pipMarker) -or (Get-Content $pipMarker -ErrorAction SilentlyContinue) -ne $depHash) {
    $needsPip = $true
}

# whisper.cpp
$whisperCliPath = Join-Path $WHISPER_DIR "build\bin\Release\whisper-cli.exe"
if (-not (Test-Path $WHISPER_DIR)) {
    $needsWhisper = $true
} elseif (-not (Test-Path $whisperCliPath)) {
    $needsWhisper = $true
} elseif (Test-Path (Join-Path $WHISPER_DIR ".git")) {
    $whisperHead = git -C $WHISPER_DIR rev-parse HEAD 2>$null
    $buildMarker = Join-Path $STATE_DIR "whisper_build"
    if (-not (Test-Path $buildMarker) -or (Get-Content $buildMarker -ErrorAction SilentlyContinue) -ne $whisperHead) {
        $needsWhisper = $true
    }
}

# Model
$modelPath = Join-Path $WHISPER_DIR "models\ggml-$MODEL.bin"
if (-not (Test-Path $modelPath)) {
    $needsModel = $true
}

# ── Phase 3: Install ─────────────────────────────────────────
$anyWork = $needsVenv -or $needsPip -or $needsWhisper -or $needsModel
if ($anyWork) {
    Write-Header "Setting up project dependencies"
}

# 3a: Venv
if ($needsVenv) {
    Write-Info "Creating Python virtual environment..."
    if (Test-Path $VENV_DIR) { Remove-Item $VENV_DIR -Recurse -Force }
    & $PYTHON -m venv $VENV_DIR
    Set-Content -Path $venvMarker -Value $PYTHON_VER
    $needsPip = $true
    Write-Ok "Virtual environment created"
}

# 3b: Pip deps
if ($needsPip) {
    Write-Info "Installing Python packages (this may take a few minutes)..."
    & (Join-Path $VENV_DIR "Scripts\Activate.ps1")
    pip install --upgrade pip wheel setuptools -q
    pip install numpy soundfile -q
    pip install torch torchaudio --index-url $TORCH_INDEX -q
    pip install pyannote.audio -q
    Set-Content -Path $pipMarker -Value $depHash
    Write-Ok "Python packages installed"
}

# 3c: whisper.cpp
if ($needsWhisper) {
    if (-not (Test-Command "cmake")) {
        Write-Err "cmake is required to build whisper.cpp but was not found after install."
        Write-Err "Please restart your terminal and try again."
        Read-Host "Press Enter to exit"
        exit 1
    }

    if (Test-Path (Join-Path $WHISPER_DIR ".git")) {
        Write-Info "Updating whisper.cpp..."
        git -C $WHISPER_DIR pull -q 2>$null
    } else {
        Write-Info "Cloning whisper.cpp..."
        git clone https://github.com/ggerganov/whisper.cpp.git $WHISPER_DIR -q
    }

    Write-Info "Building whisper.cpp (this may take a few minutes)..."
    $cmakeArgs = @("-B", (Join-Path $WHISPER_DIR "build"), "-S", $WHISPER_DIR, "-DCMAKE_BUILD_TYPE=Release")
    if ($GPU_BUILD) { $cmakeArgs += $GPU_BUILD }
    cmake @cmakeArgs 2>&1 | Select-Object -Last 5
    cmake --build (Join-Path $WHISPER_DIR "build") --config Release --target whisper-cli 2>&1 | Select-Object -Last 5

    if (Test-Path $whisperCliPath) {
        $newHead = git -C $WHISPER_DIR rev-parse HEAD 2>$null
        Set-Content -Path (Join-Path $STATE_DIR "whisper_build") -Value $newHead
        Write-Ok "whisper.cpp built"
    } else {
        Write-Err "whisper.cpp build failed. The binary was not found at: $whisperCliPath"
        Write-Err "You may need Visual Studio Build Tools with C++ workload."
        Read-Host "Press Enter to exit"
        exit 1
    }
}

# 3d: Model
if ($needsModel) {
    $modelDir = Join-Path $WHISPER_DIR "models"
    New-Item -ItemType Directory -Path $modelDir -Force | Out-Null
    $modelUrl = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-$MODEL.bin"
    $modelDest = Join-Path $modelDir "ggml-$MODEL.bin"

    Write-Info "Downloading Whisper $MODEL model (~3GB)..."
    try {
        Start-BitsTransfer -Source $modelUrl -Destination $modelDest -ErrorAction Stop
    } catch {
        Write-Info "BITS transfer failed, trying direct download..."
        Invoke-WebRequest -Uri $modelUrl -OutFile $modelDest -UseBasicParsing
    }
    Set-Content -Path (Join-Path $STATE_DIR "whisper_model") -Value $MODEL
    Write-Ok "Model downloaded"
}

# 3e: VAD model (anti-hallucination)
$vadModelPath = Join-Path $WHISPER_DIR "models\ggml-silero-v6.2.0.bin"
if (-not (Test-Path $vadModelPath)) {
    $vadUrl = "https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v6.2.0.bin"
    Write-Info "Downloading VAD model (anti-hallucination)..."
    try {
        Invoke-WebRequest -Uri $vadUrl -OutFile $vadModelPath -UseBasicParsing
        Write-Ok "VAD model downloaded"
    } catch {
        Write-Warn "Could not download VAD model. Transcription will work but without hallucination protection."
    }
}

# Summary
if (-not $anyWork) {
    Write-Ok "All dependencies up to date"
}

# 3f: HuggingFace token (required for pyannote diarization models)
& (Join-Path $VENV_DIR "Scripts\Activate.ps1")
$hfToken = python -c "from huggingface_hub import get_token; t = get_token(); print(t or '')" 2>$null
if (-not $hfToken -or $hfToken -eq "") {
    Write-Header "HuggingFace Setup Required"
    Write-Host ""
    Write-Host "  Speaker diarization requires a free HuggingFace account."
    Write-Host ""
    Write-Host "  Step 1: Create an account at https://huggingface.co (if you don't have one)"
    Write-Host ""
    Write-Host "  Step 2: Accept the model licenses (click 'Agree' on each page):"
    Write-Host "    - https://huggingface.co/pyannote/speaker-diarization-3.1"
    Write-Host "    - https://huggingface.co/pyannote/segmentation-3.0"
    Write-Host ""
    Write-Host "  Step 3: Create an access token at https://huggingface.co/settings/tokens"
    Write-Host "    - Click 'New token', name it anything, role 'Read'"
    Write-Host ""
    $hfInput = Read-Host "  Paste your HuggingFace token here (starts with hf_)"
    if ($hfInput) {
        python -c "from huggingface_hub import login; login(token='$hfInput')" 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Ok "HuggingFace token saved"
        } else {
            Write-Warn "Token may be invalid, but continuing anyway"
        }
    } else {
        Write-Warn "No token entered. Diarization will fail until you set one."
    }
} else {
    $hfAccess = python -c @"
from huggingface_hub import model_info
try:
    model_info('pyannote/speaker-diarization-3.1')
    print('ok')
except Exception as e:
    print(str(e)[:80])
"@ 2>$null
    if ($hfAccess -eq "ok") {
        Write-Ok "HuggingFace: authenticated + model access confirmed"
    } elseif ($hfAccess -match "gated|403|restricted") {
        Write-Warn "HuggingFace token found but model access denied."
        Write-Host ""
        Write-Host "  You need to accept the license on these pages (click 'Agree'):"
        Write-Host "    - https://huggingface.co/pyannote/speaker-diarization-3.1"
        Write-Host "    - https://huggingface.co/pyannote/segmentation-3.0"
        Write-Host ""
        Read-Host "  Press Enter after accepting (or just continue)"
    }
}

# ── Phase 4: Launch ───────────────────────────────────────────
Write-Header "Launching Speech2Text"
pip install --upgrade pip -q 2>$null

# Choose GUI: gui_tk.py (tkinter, cross-platform) > gui.py (GTK4, Linux-only) > CLI
$guiTk  = Join-Path $REPO_DIR "gui_tk.py"
$guiGtk = Join-Path $REPO_DIR "gui.py"
$cli    = Join-Path $REPO_DIR "transcribe.py"

if (Test-Path $guiTk) {
    Write-Info "Starting GUI..."
    python $guiTk @args
} elseif (Test-Path $guiGtk) {
    try {
        python $guiGtk @args
    } catch {
        Write-Warn "GTK4 GUI not available on Windows. Falling back to CLI."
        Write-Info "Usage:  python $cli <audio_file> [options]"
        python $cli --help
    }
} else {
    Write-Info "Usage:  python $cli <audio_file> [options]"
    python $cli --help
}
