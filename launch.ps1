#Requires -Version 5.1
<#
.SYNOPSIS
    Speech2Text — One-Click Launcher (Windows)
    https://github.com/routine88/Speech2Text

.DESCRIPTION
    Place this file anywhere. Double-click launch.bat (or run this script).
    First run:  clones repo + installs everything (~10-15 min)
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

# ── Phase 1: Repo Sync ───────────────────────────────────────
Write-Header "Syncing code"

if (-not (Test-Command "git")) {
    Write-Err "Git is required but not found."
    Write-Err "Install with:  winget install Git.Git"
    Write-Err "Then restart this script."
    Read-Host "Press Enter to exit"
    exit 1
}

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

# Find Python
$PYTHON = $null
foreach ($candidate in @("python3", "python", "py")) {
    if (Test-Command $candidate) {
        $tryCmd = $candidate
        # py launcher needs -3 flag
        if ($candidate -eq "py") { $tryCmd = "py -3" }

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
    Write-Err "Python 3.10+ is required."
    Write-Err "Install with:  winget install Python.Python.3.12"
    Read-Host "Press Enter to exit"
    exit 1
}
$PYTHON_VER = & $PYTHON --version 2>&1

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
            # Default to cu124 on Windows
            $TORCH_INDEX = "https://download.pytorch.org/whl/cu124"
            Write-Info "NVIDIA GPU detected: $gpuName"

            if (Test-Command "nvcc") {
                $nvccOut = nvcc --version 2>&1
                if ($nvccOut -match "release (\d+\.\d+)") {
                    $cudaVer = $Matches[1]
                    if ($cudaVer -like "11.*") {
                        $TORCH_INDEX = "https://download.pytorch.org/whl/cu118"
                    }
                    Write-Info "CUDA toolkit: $cudaVer"
                }
            }
        }
    } catch {}
}

# Determine what needs work
$needsVenv     = $false
$needsPip      = $false
$needsWhisper  = $false
$needsModel    = $false
$needsSyscheck = $false

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

# System deps
$sysMarker = Join-Path $STATE_DIR "system_deps"
if (-not (Test-Path $sysMarker)) {
    $needsSyscheck = $true
}

# ── Phase 3: Install ─────────────────────────────────────────
$anyWork = $needsSyscheck -or $needsVenv -or $needsPip -or $needsWhisper -or $needsModel
if ($anyWork) {
    Write-Header "Setting up dependencies"
}

# 3a: System deps
if ($needsSyscheck) {
    $missing = @()
    if (-not (Test-Command "cmake"))  { $missing += "cmake (winget install Kitware.CMake)" }
    if (-not (Test-Command "ffmpeg")) { $missing += "ffmpeg (winget install Gyan.FFmpeg)" }

    # Check for C++ compiler
    $hasCL = $false
    if (Test-Command "cl") { $hasCL = $true }
    if (-not $hasCL) {
        # Try vswhere
        $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
        if (Test-Path $vswhere) {
            $vsPath = & $vswhere -latest -property installationPath 2>$null
            if ($vsPath) { $hasCL = $true }
        }
    }
    if (-not $hasCL) {
        $missing += "Visual Studio Build Tools with C++ (winget install Microsoft.VisualStudio.2022.BuildTools)"
    }

    if ($missing.Count -gt 0) {
        Write-Err "Missing required tools:"
        foreach ($m in $missing) { Write-Err "  - $m" }
        Write-Err ""
        Write-Err "Install them and run this script again."
        Read-Host "Press Enter to exit"
        exit 1
    }
    Set-Content -Path $sysMarker -Value "ok"
    Write-Ok "System dependencies verified"
}

# 3b: Venv
if ($needsVenv) {
    Write-Info "Creating Python virtual environment..."
    if (Test-Path $VENV_DIR) { Remove-Item $VENV_DIR -Recurse -Force }
    & $PYTHON -m venv $VENV_DIR
    Set-Content -Path $venvMarker -Value $PYTHON_VER
    $needsPip = $true
    Write-Ok "Virtual environment created"
}

# 3c: Pip deps
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

# 3d: whisper.cpp
if ($needsWhisper) {
    if (-not (Test-Command "cmake")) {
        Write-Err "cmake is required to build whisper.cpp"
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
    cmake @cmakeArgs 2>&1 | Select-Object -Last 3
    cmake --build (Join-Path $WHISPER_DIR "build") --config Release --target whisper-cli 2>&1 | Select-Object -Last 3

    $newHead = git -C $WHISPER_DIR rev-parse HEAD 2>$null
    Set-Content -Path (Join-Path $STATE_DIR "whisper_build") -Value $newHead
    Write-Ok "whisper.cpp built"
}

# 3e: Model
if ($needsModel) {
    $modelDir = Join-Path $WHISPER_DIR "models"
    New-Item -ItemType Directory -Path $modelDir -Force | Out-Null
    $modelUrl = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-$MODEL.bin"
    $modelDest = Join-Path $modelDir "ggml-$MODEL.bin"

    Write-Info "Downloading Whisper $MODEL model (~3GB)..."
    # Use BITS for better large-file handling, fall back to Invoke-WebRequest
    try {
        Start-BitsTransfer -Source $modelUrl -Destination $modelDest -ErrorAction Stop
    } catch {
        Invoke-WebRequest -Uri $modelUrl -OutFile $modelDest -UseBasicParsing
    }
    Set-Content -Path (Join-Path $STATE_DIR "whisper_model") -Value $MODEL
    Write-Ok "Model downloaded"
}

# Summary
if (-not $anyWork) {
    Write-Ok "All dependencies up to date"
}

# ── Phase 4: Launch ───────────────────────────────────────────
Write-Header "Launching Speech2Text"
& (Join-Path $VENV_DIR "Scripts\Activate.ps1")

# Choose GUI: gui_tk.py (tkinter, cross-platform) > gui.py (GTK4, Linux-only) > CLI
$guiTk  = Join-Path $REPO_DIR "gui_tk.py"
$guiGtk = Join-Path $REPO_DIR "gui.py"
$cli    = Join-Path $REPO_DIR "transcribe.py"

if (Test-Path $guiTk) {
    Write-Info "Starting GUI..."
    python $guiTk @args
} elseif (Test-Path $guiGtk) {
    # Try GTK4 — will fail on Windows but worth trying if user installed it
    try {
        python $guiGtk @args
    } catch {
        Write-Warn "GTK4 GUI not available on Windows. Falling back to CLI."
        Write-Info "Usage:  python $cli <audio_file> [options]"
        Write-Info "Run 'python $cli --help' for all options."
        python $cli --help
    }
} else {
    Write-Info "Usage:  python $cli <audio_file> [options]"
    python $cli --help
}
