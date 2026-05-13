#Requires -Version 5.1
<#
.SYNOPSIS
    Speech2Text -- One-Click Launcher (Windows)
    https://github.com/routine88/Speech2Text

.DESCRIPTION
    Place this file anywhere. Double-click launch.bat (or run this script).
    First run:  installs everything automatically (~10-15 min)
    After that: pulls latest code + launches (~2 sec)
#>

$ErrorActionPreference = "Continue"

# Force UTF-8 I/O so winget's progress bars (which use box-drawing chars like
# U+2588 / U+2592) don't render as mojibake ("GUuOuOuO") through the OEM codepage.
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    [Console]::InputEncoding  = [System.Text.Encoding]::UTF8
    $OutputEncoding           = [System.Text.Encoding]::UTF8
} catch {}

$REPO_URL    = "https://github.com/routine88/Speech2Text.git"
$RAW_URL     = "https://raw.githubusercontent.com/routine88/Speech2Text/main/launch.ps1"
$REPO_DIR    = if ($env:S2T_REPO_DIR)       { $env:S2T_REPO_DIR }       else { Join-Path $HOME "Speech2Text" }
$WHISPER_DIR = if ($env:WHISPER_DIR)         { $env:WHISPER_DIR }         else { Join-Path $HOME "whisper.cpp" }
$MODEL       = if ($env:WHISPER_MODEL_NAME)  { $env:WHISPER_MODEL_NAME }  else { "large-v3" }
$SELF        = $MyInvocation.MyCommand.Path

# -- Crash diagnostics ----------------------------------------
# Prevent the "double-click -> red text -> window vanishes" failure mode by
# (1) logging everything to a transcript on disk, and (2) trapping any
# uncaught error to pause before exit. launch.bat sets S2T_LAUNCHED_FROM_BAT,
# which gives that wrapper a chance to `pause` on its own; if the env var is
# absent, the .ps1 was run directly (e.g. right-click -> Run with PowerShell)
# and we must hold the window open ourselves.
$script:LaunchedFromBat = ($env:S2T_LAUNCHED_FROM_BAT -eq "1")
$script:TranscriptPath  = $null
try {
    # Use %TEMP% rather than $REPO_DIR -- on first run the repo doesn't exist
    # yet and pre-creating subdirs would make the upcoming `git clone` fail.
    $logDir = Join-Path $env:TEMP "Speech2Text-launcher"
    New-Item -ItemType Directory -Path $logDir -Force -ErrorAction SilentlyContinue | Out-Null
    $script:TranscriptPath = Join-Path $logDir ("launcher-" + (Get-Date -Format "yyyyMMdd-HHmmss") + ".log")
    Start-Transcript -Path $script:TranscriptPath -Append -ErrorAction SilentlyContinue | Out-Null
} catch { $script:TranscriptPath = $null }

function Wait-OnExit {
    param([string] $Reason = "")
    if (-not $script:LaunchedFromBat) {
        if ($Reason) { Write-Host "" ; Write-Host $Reason -ForegroundColor Yellow }
        if ($script:TranscriptPath) { Write-Host "Full log: $script:TranscriptPath" -ForegroundColor DarkGray }
        try { Read-Host "Press Enter to close this window" | Out-Null } catch {}
    }
}

trap {
    Write-Host ""
    Write-Host "[X]  Unexpected error: $($_.Exception.Message)" -ForegroundColor Red
    if ($_.ScriptStackTrace) {
        Write-Host $_.ScriptStackTrace -ForegroundColor DarkRed
    }
    try { Stop-Transcript -ErrorAction SilentlyContinue | Out-Null } catch {}
    Wait-OnExit "The launcher crashed. The log above has been saved."
    exit 1
}

# -- Helpers ---------------------------------------------------
function Write-Info  ($msg) { Write-Host "[.]  $msg" -ForegroundColor Cyan }
function Write-Ok    ($msg) { Write-Host "[OK] $msg" -ForegroundColor Green }
function Write-Warn  ($msg) { Write-Host "[!]  $msg" -ForegroundColor Yellow }
function Write-Err   ($msg) { Write-Host "[X]  $msg" -ForegroundColor Red }
function Write-Header($msg) { Write-Host "`n-- $msg --" -ForegroundColor White }

function Test-Command($cmd) { $null -ne (Get-Command $cmd -ErrorAction SilentlyContinue) }

# Path to the venv's python.exe (set later, used by Invoke-Pip)
$script:VenvPython = $null

# Run pip via `python -m pip` using the venv interpreter directly. Modern pip
# (>=22) refuses self-upgrade via `pip install --upgrade pip` and returns
# non-zero, which silently broke setup. Going through `python -m pip` avoids
# both that and any reliance on Activate.ps1 having mutated PATH correctly.
function Invoke-Pip {
    param([Parameter(ValueFromRemainingArguments = $true)] [string[]] $PipArgs)
    if (-not $script:VenvPython -or -not (Test-Path $script:VenvPython)) {
        throw "Venv python not found at '$script:VenvPython'. Create the venv first."
    }
    & $script:VenvPython -m pip @PipArgs
    # Do not `return $LASTEXITCODE` -- that would write the int to the pipeline.
    # Caller should check $LASTEXITCODE directly after this call.
}

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

# -- Phase 0: Self-Update -------------------------------------
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

# -- Prerequisite: winget --------------------------------------
$hasWinget = Test-Command "winget"
if (-not $hasWinget) {
    Write-Warn "winget not found. Will try to install dependencies manually."
    Write-Warn "For best experience, install App Installer from the Microsoft Store."
}

# -- Prerequisite: Git -----------------------------------------
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

# -- Phase 1: Repo Sync ---------------------------------------
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

# -- Phase 2: State Check -------------------------------------
$STATE_DIR = Join-Path $REPO_DIR ".s2t_state"
$VENV_DIR  = Join-Path $REPO_DIR "venv"
New-Item -ItemType Directory -Path $STATE_DIR -Force | Out-Null

# -- Auto-install system dependencies -------------------------

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

# C++ Build Tools detection.
# Previous check (Test-Command cl + bare vswhere) was wrong on both ends:
# cl.exe is only on PATH inside a VS Developer Prompt (never in a normal
# shell), and `vswhere -latest -property installationPath` matches ANY VS
# install -- including ones with no C++ workload, which can't build whisper.cpp.
# We now use `vswhere -requires` to demand the VC.Tools.x86.x64 component,
# which is what we'd be installing anyway, and store the install metadata so
# the CMake step can pass `-G "Visual Studio NN YYYY"` instead of relying on
# cl.exe being on PATH (it isn't, and adding it there would also need the
# Windows SDK paths -- much simpler to let CMake locate MSVC via vswhere).
function Find-VSInstall {
    $vswhereLocations = @(
        (Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"),
        (Join-Path $env:ProgramFiles         "Microsoft Visual Studio\Installer\vswhere.exe")
    )
    foreach ($vswhere in $vswhereLocations) {
        if (-not $vswhere -or -not (Test-Path $vswhere)) { continue }
        $json = & $vswhere -latest -products * `
            -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
            -format json 2>$null | Out-String
        if (-not $json) { continue }
        try {
            $parsed = $json | ConvertFrom-Json
            if ($parsed -and $parsed.Count -gt 0) {
                return [PSCustomObject]@{
                    InstallationPath    = $parsed[0].installationPath
                    InstallationVersion = $parsed[0].installationVersion
                }
            }
        } catch {}
    }
    return $null
}

function Get-VSGenerator {
    param([string] $InstallationVersion)
    if (-not $InstallationVersion) { return $null }
    $major = 0
    [void][int]::TryParse(($InstallationVersion -split '\.')[0], [ref] $major)
    switch ($major) {
        17 { return "Visual Studio 17 2022" }
        16 { return "Visual Studio 16 2019" }
        15 { return "Visual Studio 15 2017" }
        default { return $null }
    }
}

$script:VSInstall   = Find-VSInstall
$script:VSGenerator = if ($script:VSInstall) { Get-VSGenerator $script:VSInstall.InstallationVersion } else { $null }

if (-not $script:VSInstall) {
    Write-Header "Installing Visual Studio Build Tools"
    if ($hasWinget) {
        Write-Info "Installing C++ build tools (this may take several minutes)..."
        winget install --id Microsoft.VisualStudio.2022.BuildTools `
            --accept-source-agreements --accept-package-agreements `
            --override "--quiet --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended" 2>&1 | Out-Host
        # winget often returns non-zero even on success (installer service runs
        # async, "needs reboot" pseudo-errors, etc.), so trust detection rather
        # than $LASTEXITCODE. Re-probe with vswhere.
        $script:VSInstall   = Find-VSInstall
        $script:VSGenerator = if ($script:VSInstall) { Get-VSGenerator $script:VSInstall.InstallationVersion } else { $null }
        if ($script:VSInstall) {
            Write-Ok "Visual Studio Build Tools detected at $($script:VSInstall.InstallationPath)"
        } else {
            Write-Warn ""
            Write-Warn "Build Tools install did not complete in this session."
            Write-Warn "This is usually because the installer service needs a reboot."
            Write-Warn "Reboot and re-run launch.bat -- you should not see this prompt again."
            Read-Host "Press Enter to continue anyway (build will likely fail)"
        }
    } else {
        Write-Err "C++ Build Tools are required to compile whisper.cpp."
        Write-Err "Download: https://visualstudio.microsoft.com/visual-cpp-build-tools/"
        Write-Err "Select 'Desktop development with C++' workload."
        Read-Host "Press Enter to exit"
        exit 1
    }
} else {
    Write-Ok "Visual Studio Build Tools: $($script:VSInstall.InstallationVersion) at $($script:VSInstall.InstallationPath)"
}

# GPU detection (CUDA only on Windows)
# Note: PyTorch CUDA wheels work on the driver alone -- no CUDA Toolkit needed.
# But building whisper.cpp with -DGGML_CUDA=ON requires the CUDA Toolkit (nvcc).
# So GPU torch wheels and GPU whisper build are gated independently.
$GPU_BUILD = ""
$TORCH_INDEX = "https://download.pytorch.org/whl/cpu"
$GPU_TYPE = "none"

$nvidiaSmi = $null
if (Test-Command "nvidia-smi") {
    $nvidiaSmi = "nvidia-smi"
} elseif (Test-Path "C:\Windows\System32\nvidia-smi.exe") {
    $nvidiaSmi = "C:\Windows\System32\nvidia-smi.exe"
}

# Locate nvcc -- winget-installed CUDA isn't always on PATH, so probe common paths.
function Find-Nvcc {
    if (Test-Command "nvcc") { return (Get-Command "nvcc").Source }
    $candidates = @()
    if ($env:CUDA_PATH) { $candidates += (Join-Path $env:CUDA_PATH "bin\nvcc.exe") }
    $cudaRoot = "${env:ProgramFiles}\NVIDIA GPU Computing Toolkit\CUDA"
    if (Test-Path $cudaRoot) {
        Get-ChildItem $cudaRoot -Directory -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending |
            ForEach-Object { $candidates += (Join-Path $_.FullName "bin\nvcc.exe") }
    }
    foreach ($c in $candidates) {
        if ($c -and (Test-Path $c)) {
            $env:Path = (Split-Path $c) + ";" + $env:Path
            return $c
        }
    }
    return $null
}

if ($nvidiaSmi) {
    try {
        $gpuName = & $nvidiaSmi --query-gpu=name --format=csv,noheader 2>$null | Select-Object -First 1
        if ($gpuName) {
            $GPU_TYPE = "cuda"
            $TORCH_INDEX = "https://download.pytorch.org/whl/cu124"
            Write-Ok "NVIDIA GPU: $gpuName"

            $nvccPath = Find-Nvcc
            if (-not $nvccPath) {
                # PyTorch CUDA wheels work on the driver alone, but whisper.cpp's
                # GGML_CUDA backend requires the toolkit (nvcc) at build time.
                # If we skip this and just build CPU-only, transcription is slow
                # and the user thinks the GPU isn't being used at all -- because
                # transcription dominates total time.
                Write-Warn "CUDA Toolkit (nvcc) not found -- needed to GPU-accelerate transcription."
                if ($hasWinget) {
                    Write-Host ""
                    Write-Host "  Install CUDA Toolkit now? Downloads ~2.5 GB, takes 5-15 min." -ForegroundColor Yellow
                    Write-Host "  Without it, Whisper transcription runs on CPU (much slower)." -ForegroundColor Yellow
                    $reply = Read-Host "  Install? [Y/n]"
                    if ($reply -eq '' -or $reply -match '^[Yy]') {
                        Write-Info "Installing CUDA Toolkit via winget (this may take a while)..."
                        winget install --id Nvidia.CUDA `
                            --accept-source-agreements --accept-package-agreements -e 2>&1 | Out-Host
                        # winget often doesn't propagate PATH to the current session,
                        # but Find-Nvcc probes the standard install root directly.
                        $nvccPath = Find-Nvcc
                        if ($nvccPath) {
                            Write-Ok "CUDA Toolkit installed."
                        } else {
                            Write-Warn "CUDA Toolkit install did not register in this session."
                            Write-Warn "Reboot and rerun launch.bat to enable GPU transcription."
                        }
                    } else {
                        Write-Warn "Skipping. Whisper will build CPU-only."
                        Write-Warn "To enable later: winget install Nvidia.CUDA  (then rerun launch.bat)"
                    }
                } else {
                    # No winget -- can't auto-install. Point at the manual download.
                    Write-Warn "winget is not available, so we can't install it automatically."
                    Write-Warn "To enable GPU transcription, install the CUDA Toolkit manually:"
                    Write-Warn "  https://developer.nvidia.com/cuda-downloads"
                    Write-Warn "  (Pick Windows / x86_64 / 11 / exe (local)). Then rerun launch.bat."
                }
            }

            if ($nvccPath) {
                $nvccOut = & $nvccPath --version 2>&1
                $cudaVer = ""
                if ($nvccOut -match "release (\d+\.\d+)") {
                    $cudaVer = $Matches[1]
                    if ($cudaVer -like "11.*") {
                        $TORCH_INDEX = "https://download.pytorch.org/whl/cu118"
                    }
                }
                $GPU_BUILD = "-DGGML_CUDA=ON"
                Write-Ok "CUDA Toolkit: $cudaVer (GPU build enabled)"
            } else {
                Write-Warn "Building whisper.cpp for CPU. PyTorch will still use the GPU."
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
    # Composite key: git HEAD + GPU build flags. If the user installed the CUDA
    # Toolkit since the last run, we must rebuild even though the source hash
    # is unchanged -- otherwise they keep using the CPU-only binary.
    $buildKey = "$whisperHead|$GPU_BUILD"
    $existingMarker = Get-Content $buildMarker -ErrorAction SilentlyContinue
    # Migrate legacy marker format (just "<HEAD>") to "<HEAD>|" so an existing
    # CPU-only build doesn't trigger a spurious rebuild on first run after upgrade.
    if ($existingMarker -and $existingMarker -notmatch '\|') {
        $existingMarker = "$existingMarker|"
    }
    if (-not $existingMarker -or $existingMarker -ne $buildKey) {
        $needsWhisper = $true
    }
}

# Model
$modelPath = Join-Path $WHISPER_DIR "models\ggml-$MODEL.bin"
if (-not (Test-Path $modelPath)) {
    $needsModel = $true
}

# -- Phase 3: Install -----------------------------------------
$anyWork = $needsVenv -or $needsPip -or $needsWhisper -or $needsModel
if ($anyWork) {
    Write-Header "Setting up project dependencies"
}

# 3a: Venv
if ($needsVenv) {
    Write-Info "Creating Python virtual environment..."
    if (Test-Path $VENV_DIR) { Remove-Item $VENV_DIR -Recurse -Force }
    & $PYTHON -m venv $VENV_DIR
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path (Join-Path $VENV_DIR "Scripts\python.exe"))) {
        Write-Err "Failed to create virtual environment at $VENV_DIR"
        Read-Host "Press Enter to exit"
        exit 1
    }
    Set-Content -Path $venvMarker -Value $PYTHON_VER
    $needsPip = $true
    Write-Ok "Virtual environment created"
}

# Bind pip to the venv's python -- must happen after venv exists, before any Invoke-Pip.
$script:VenvPython = Join-Path $VENV_DIR "Scripts\python.exe"
if (-not (Test-Path $script:VenvPython)) {
    Write-Err "Venv python missing at $script:VenvPython -- delete the venv folder and rerun."
    Read-Host "Press Enter to exit"
    exit 1
}

# 3b: Pip deps
if ($needsPip) {
    Write-Info "Installing Python packages (this may take a few minutes)..."
    # Upgrade pip via `python -m pip` -- `pip install --upgrade pip` is rejected
    # by modern pip with "To modify pip, please run the following command".
    Invoke-Pip install --upgrade pip wheel setuptools
    if ($LASTEXITCODE -ne 0) { Write-Warn "pip self-upgrade failed; continuing with existing pip" }

    Invoke-Pip install numpy soundfile
    if ($LASTEXITCODE -ne 0) {
        Write-Err "Failed to install numpy/soundfile"
        Read-Host "Press Enter to exit"; exit 1
    }
    Invoke-Pip install torch torchaudio --index-url $TORCH_INDEX
    if ($LASTEXITCODE -ne 0) {
        Write-Err "Failed to install torch/torchaudio from $TORCH_INDEX"
        Read-Host "Press Enter to exit"; exit 1
    }
    Invoke-Pip install pyannote.audio
    if ($LASTEXITCODE -ne 0) {
        Write-Err "Failed to install pyannote.audio"
        Read-Host "Press Enter to exit"; exit 1
    }
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

    $buildDir = Join-Path $WHISPER_DIR "build"
    $logDir   = Join-Path $STATE_DIR "logs"
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    $cfgLog   = Join-Path $logDir "cmake-configure.log"
    $bldLog   = Join-Path $logDir "cmake-build.log"

    # Returns $true on success. On failure, prints tail of log and returns $false.
    # cmake config can fail (e.g. "CUDA Toolkit not found") and then `cmake --build`
    # produces a misleading MSB1009 -- so we MUST check exit code after configure.
    function Invoke-WhisperBuild {
        param([bool] $UseGpu)
        # Fresh configure each attempt -- CMakeCache.txt caches the previous failure.
        if (Test-Path $buildDir) { Remove-Item $buildDir -Recurse -Force -ErrorAction SilentlyContinue }

        $cmakeArgs = @("-B", $buildDir, "-S", $WHISPER_DIR, "-DCMAKE_BUILD_TYPE=Release")
        # Pick the matching VS generator so CMake locates MSVC via vswhere itself,
        # without needing cl.exe on PATH (which it never is outside a Dev Prompt).
        if ($script:VSGenerator) { $cmakeArgs += @("-G", $script:VSGenerator, "-A", "x64") }
        if ($UseGpu -and $GPU_BUILD) { $cmakeArgs += $GPU_BUILD }

        Write-Info ("Configuring whisper.cpp (" + $(if ($UseGpu -and $GPU_BUILD) { "GPU" } else { "CPU" }) + ")...")
        & cmake @cmakeArgs *>&1 | Tee-Object -FilePath $cfgLog | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Err "CMake configure failed (exit $LASTEXITCODE). Last lines:"
            Get-Content $cfgLog -Tail 15 | ForEach-Object { Write-Host "    $_" }
            Write-Info "Full log: $cfgLog"
            return $false
        }

        Write-Info "Building whisper.cpp (this may take a few minutes)..."
        & cmake --build $buildDir --config Release --target whisper-cli *>&1 |
            Tee-Object -FilePath $bldLog | Out-Null
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path $whisperCliPath)) {
            Write-Err "CMake build failed (exit $LASTEXITCODE). Last lines:"
            Get-Content $bldLog -Tail 20 | ForEach-Object { Write-Host "    $_" }
            Write-Info "Full log: $bldLog"
            return $false
        }
        return $true
    }

    $built = $false
    if ($GPU_BUILD) {
        $built = Invoke-WhisperBuild -UseGpu $true
        if (-not $built) {
            Write-Warn "GPU build failed -- retrying with CPU build."
            $GPU_BUILD = ""
            $built = Invoke-WhisperBuild -UseGpu $false
        }
    } else {
        $built = Invoke-WhisperBuild -UseGpu $false
    }

    if ($built) {
        $newHead = git -C $WHISPER_DIR rev-parse HEAD 2>$null
        # Keep marker format in sync with the comparison above.
        Set-Content -Path (Join-Path $STATE_DIR "whisper_build") -Value "$newHead|$GPU_BUILD"
        Write-Ok "whisper.cpp built ($(if ($GPU_BUILD) { 'GPU' } else { 'CPU' }))"
    } else {
        Write-Err "whisper.cpp build failed even with CPU fallback."
        Write-Err "You may need Visual Studio Build Tools with the C++ workload."
        Write-Err "Logs:  $cfgLog  /  $bldLog"
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
$hfToken = & $script:VenvPython -c "from huggingface_hub import get_token; t = get_token(); print(t or '')" 2>$null
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
        # Pass token via env var rather than string interpolation -- avoids quoting bugs
        # if the token ever contains characters PowerShell would mangle.
        $env:S2T_HF_TOKEN = $hfInput
        & $script:VenvPython -c "import os; from huggingface_hub import login; login(token=os.environ['S2T_HF_TOKEN'])" 2>&1
        $loginExit = $LASTEXITCODE
        Remove-Item Env:\S2T_HF_TOKEN -ErrorAction SilentlyContinue
        if ($loginExit -eq 0) {
            Write-Ok "HuggingFace token saved"
        } else {
            Write-Warn "Token may be invalid, but continuing anyway"
        }
    } else {
        Write-Warn "No token entered. Diarization will fail until you set one."
    }
} else {
    $hfAccess = & $script:VenvPython -c @"
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

# -- Phase 4: Launch -------------------------------------------
Write-Header "Launching Speech2Text"

# gui_tk.py = tkinter-based, cross-platform (preferred when available).
# gui.py    = GTK4/PyGObject, Linux-only -- DO NOT attempt on Windows. The
# Windows pip install list intentionally omits PyGObject, so importing it
# would raise ModuleNotFoundError. That's a non-zero subprocess exit, which
# does NOT raise a PowerShell terminating error, so a surrounding try/catch
# would not catch it -- the script would fall through, exit cleanly with
# code 0, and launch.bat's "pause on non-zero" would never fire. The user
# would see the error scroll by and the window close. (That was the bug.)
$cli   = Join-Path $REPO_DIR "transcribe.py"
$guiTk = Join-Path $REPO_DIR "gui_tk.py"

function Wait-OnExitAlways {
    param([string] $Reason = "")
    if ($Reason) { Write-Host "" ; Write-Host $Reason -ForegroundColor Yellow }
    if ($script:TranscriptPath) { Write-Host "Full log: $script:TranscriptPath" -ForegroundColor DarkGray }
    try { Read-Host "Press Enter to close this window" | Out-Null } catch {}
}

if (Test-Path $guiTk) {
    Write-Info "Starting GUI..."
    & $script:VenvPython $guiTk @args
    $rc = $LASTEXITCODE
    if ($rc -ne 0) {
        Wait-OnExitAlways "GUI exited with code $rc"
        exit $rc
    }
} else {
    Write-Info "No Windows GUI yet -- showing CLI help."
    Write-Info ""
    Write-Info "  Transcribe a file:"
    Write-Info "    python `"$cli`" `"path\to\audio.wav`""
    Write-Info ""
    & $script:VenvPython $cli --help
    Wait-OnExitAlways "Setup complete. Use the command above to transcribe."
}
