<#
Builds the Rust native core (rust/ -> libfqapi_core.so) for OpenHarmony arm64 and
copies it into ohos/entry/libs/arm64-v8a.

Why this script exists: flutter_rust_bridge loads the crate by bare name
(`ExternalLibrary.open('libfqapi_core.so')`) on OHOS, so the library must sit in
the module's libs directory before Hvigor assembles the HAP. `flutter build hap`
does not cross-compile the crate, and `scripts/build_rust_backend.ps1` only
targets Android. Without this step the HAP ships libapp.so/libflutter.so and the
app dies at startup with:

  Invalid argument(s): Failed to load dynamic library 'libfqapi_core.so':
  Error loading shared library libfqapi_core.so: No such file or directory

The OHOS SDK is located through OHOS_SDK_HOME (points at the SDK's `native`
directory). The linker wrappers under `<sdk root>\tools` are the Windows batch
equivalents of the POSIX scripts in the rustc book; the SDK ships only the shell
versions, which rustc cannot execute on Windows.

Usage:
  .\scripts\build_rust_ohos.ps1
  .\scripts\build_rust_ohos.ps1 -Profile debug
  .\scripts\build_rust_ohos.ps1 -SkipCopy   # compile only, leave libs/ alone

Comments are kept in ASCII on purpose so the file parses cleanly on
Windows PowerShell 5.1 without a UTF-8 BOM.
#>

param(
    [ValidateSet('release', 'debug')][string]$Profile = 'release',
    [switch]$SkipCopy
)

$ErrorActionPreference = 'Stop'

$AppDir = Split-Path -Parent $PSScriptRoot
$Manifest = Join-Path $AppDir 'rust\Cargo.toml'
$Target = 'aarch64-unknown-linux-ohos'

if (-not (Get-Command cargo -ErrorAction SilentlyContinue)) {
    Write-Error 'cargo not found in PATH. Install the Rust toolchain first.'
    exit 1
}
if (-not (Test-Path -LiteralPath $Manifest)) {
    Write-Error "rust core manifest not found at $Manifest"
    exit 1
}

# Same rationale as scripts/build_rust_backend.ps1: cargo writes progress to
# stderr and $ErrorActionPreference = 'Stop' would abort before the copy step
# (CRIT-012). The real verdict is $LASTEXITCODE.
function Invoke-NativeCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Exe,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$FailureMessage
    )
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $Exe @Arguments
    }
    finally {
        $ErrorActionPreference = $previous
    }
    if ($LASTEXITCODE -ne 0) { throw "$FailureMessage (exit code $LASTEXITCODE)" }
}

# OHOS_SDK_HOME points at the SDK's native directory, whose sibling `tools`
# directory holds the linker wrappers.
$OhosNative = $env:OHOS_SDK_HOME
if (-not $OhosNative -or -not (Test-Path -LiteralPath $OhosNative)) {
    Write-Error 'OHOS_SDK_HOME is not set or does not exist. Point it at the OpenHarmony SDK native directory (e.g. <sdk>\26\native).'
    exit 1
}
$OhosNative = $OhosNative.TrimEnd('\', '/')

# The wrappers live next to the versioned SDK directory (<sdk>\<version>\native,
# so <sdk>\tools) but some layouts keep them inside the version directory.
# Probe both instead of pinning one.
$OhosRoot = Split-Path -Parent $OhosNative
$ToolsCandidates = @((Join-Path $OhosRoot 'tools'), (Join-Path (Split-Path -Parent $OhosRoot) 'tools'))
$ToolsDir = $ToolsCandidates | Where-Object {
    Test-Path -LiteralPath (Join-Path $_ "$Target-clang.bat")
} | Select-Object -First 1
if (-not $ToolsDir) {
    Write-Error "OHOS linker wrapper directory not found. Looked in: $($ToolsCandidates -join ', '). Expected $Target-clang.bat there."
    exit 1
}
$Cc = Join-Path $ToolsDir "$Target-clang.bat"
$Cxx = Join-Path $ToolsDir "$Target-clangxx.bat"
$Ar = Join-Path $OhosNative 'llvm\bin\llvm-ar.exe'

if (-not (Test-Path -LiteralPath $Cc)) {
    Write-Error "OHOS clang wrapper not found at $Cc. The wrapper is required because rustc cannot execute the POSIX script the SDK ships."
    exit 1
}
if (-not (Test-Path -LiteralPath $Ar)) {
    Write-Error "llvm-ar not found at $Ar"
    exit 1
}

# Rust's build scripts (cc-rs) look up CC/CXX/AR per target; without these the
# build fails with `failed to find tool "cc"`.
$EnvSuffix = $Target.Replace('-', '_')
$env:CC_aarch64_unknown_linux_ohos = $Cc
if (Test-Path -LiteralPath $Cxx) { $env:CXX_aarch64_unknown_linux_ohos = $Cxx }
$env:AR_aarch64_unknown_linux_ohos = $Ar

Write-Host "==> OHOS SDK: $OhosNative"
Write-Host "==> CC: $Cc"

if (-not (rustup target list --installed | Select-String -SimpleMatch $Target -Quiet)) {
    Write-Error "rustup target $Target is not installed. Run: rustup target add $Target"
    exit 1
}

$ProfileArgs = @()
if ($Profile -eq 'release') { $ProfileArgs = @('--release') }

Write-Host "==> cargo build --target $Target ($Profile)..."
Push-Location -LiteralPath $AppDir
try {
    Invoke-NativeCommand -Exe 'cargo' `
        -Arguments (@('build', '--manifest-path', $Manifest, '--target', $Target, '--locked') + $ProfileArgs) `
        -FailureMessage 'rust OHOS cross build failed'
}
finally { Pop-Location }

$ProfileDir = if ($Profile -eq 'release') { 'release' } else { 'debug' }
$BuiltSo = Join-Path $AppDir "rust\target\$Target\$ProfileDir\libfqapi_core.so"
if (-not (Test-Path -LiteralPath $BuiltSo)) {
    Write-Error "rust build produced no $BuiltSo"
    exit 1
}
Write-Host "==> built: $BuiltSo"

if ($SkipCopy) {
    Write-Host '==> -SkipCopy given; not copying into ohos/entry/libs'
    exit 0
}

# The module name comes from ohos/build-profile.json5; `entry` is the main
# module this project ships. flutter_rust_bridge resolves the bare library name
# from the HAP's libs/<arch> directory, which is where Hvigor packs this path.
$DestDir = Join-Path $AppDir 'ohos\entry\libs\arm64-v8a'
New-Item -ItemType Directory -Force -Path $DestDir | Out-Null
$DestSo = Join-Path $DestDir 'libfqapi_core.so'
Copy-Item -LiteralPath $BuiltSo -Destination $DestSo -Force
Write-Host "==> ohos libs: $DestSo"
Get-FileHash -Algorithm SHA256 -LiteralPath $DestSo | Format-List
