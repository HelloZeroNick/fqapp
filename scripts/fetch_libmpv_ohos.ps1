<#
Fetches the prebuilt libmpv (OpenHarmony arm64-v8a) and installs it into
ohos/entry/libs/arm64-v8a.

Why this script exists: the OHOS playback backend decodes through libmpv, which
media_kit loads by bare name (`DynamicLibrary.open('libmpv.so')`). The HAP must
therefore carry the library in the entry module's libs directory. media_kit
upstream fetches the same artifact from a CMake `file(DOWNLOAD ...)` step, which
is not available here because we deliberately do not depend on
media_kit_libs_ohos (its Android module conflicts with the project's AGP 9
toolchain). This script performs the equivalent download, verifies both the
archive and the extracted library against pinned digests, and installs the .so.

The artifact is pinned to one release: 20261013-hdr of p1nbored/libmpv-ohos-build
(the build used by media_kit's own OHOS support). 24MB, arm64-v8a only.

Why `gh` first: on Windows, curl to github.com fails with
`schannel: CRYPT_E_NO_REVOCATION_CHECK (0x80092012)`. `gh release download`
sidesteps schannel entirely; the curl fallback passes --ssl-no-revoke.

Usage:
  .\scripts\fetch_libmpv_ohos.ps1
  .\scripts\fetch_libmpv_ohos.ps1 -Force    # re-download even if present

Comments are kept in ASCII on purpose so the file parses cleanly on
Windows PowerShell 5.1 without a UTF-8 BOM.
#>

param(
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

$AppDir = Split-Path -Parent $PSScriptRoot
$Repo = 'p1nbored/libmpv-ohos-build'
$Tag = '20261013-hdr'
$Asset = 'libmpv_aarch64.zip'

# Pinned digests. The archive digest guards the download; the library digest is
# the one that actually ends up in the HAP, so it is verified separately (the
# archive could unpack to a different member on a silently retagged release).
$ArchiveSha256 = '140e2c5a6d38572a1f8418cc2463c330077837a38609504c4d532825060e8617'
$LibrarySha256 = '6add9a06c5c9f4993895a9aa7ef6f541c499d3d8461d949ce0ace2377acbf940'
$LibrarySize = 24539592

$CacheDir = Join-Path $AppDir '.tmp-libmpv'
$DestDir = Join-Path $AppDir 'ohos\entry\libs\arm64-v8a'
$DestSo = Join-Path $DestDir 'libmpv.so'

if (-not (Test-Path -LiteralPath $DestDir)) {
    New-Item -ItemType Directory -Force -Path $DestDir | Out-Null
}

function Get-Sha256 {
    param([Parameter(Mandatory = $true)][string]$Path)
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

# Already installed and still the pinned build? Skip the download below, but
# still fall through to the libc++_shared.so section (it must run even when
# libmpv itself is already in place).
$NeedLibmpv = $true
if (-not $Force -and (Test-Path -LiteralPath $DestSo)) {
    $existing = Get-Sha256 -Path $DestSo
    if ($existing -eq $LibrarySha256) {
        Write-Host "==> libmpv already installed and verified: $DestSo"
        Write-Host "    sha256 $existing"
        $NeedLibmpv = $false
    }
    else {
        Write-Warning "existing libmpv.so has sha256 $existing; expected $LibrarySha256. Refetching."
    }
}

if ($NeedLibmpv) {
New-Item -ItemType Directory -Force -Path $CacheDir | Out-Null
$ArchivePath = Join-Path $CacheDir $Asset

$ArchiveOk = $false
if (-not $Force -and (Test-Path -LiteralPath $ArchivePath)) {
    $ArchiveOk = (Get-Sha256 -Path $ArchivePath) -eq $ArchiveSha256
    if (-not $ArchiveOk) {
        Write-Warning 'cached archive digest mismatch; removing and re-downloading.'
        Remove-Item -LiteralPath $ArchivePath -Force
    }
}

if (-not $ArchiveOk) {
    # `gh release download --output` overwrites unconditionally with -Force? No:
    # gh fails if the file exists, so clear it first.
    if (Test-Path -LiteralPath $ArchivePath) {
        Remove-Item -LiteralPath $ArchivePath -Force
    }

    $downloaded = $false
    if (Get-Command gh -ErrorAction SilentlyContinue) {
        Write-Host "==> gh release download $Tag -R $Repo -p $Asset"
        $previous = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            & gh release download $Tag -R $Repo -p $Asset --output $ArchivePath
        }
        finally {
            $ErrorActionPreference = $previous
        }
        $downloaded = ($LASTEXITCODE -eq 0) -and (Test-Path -LiteralPath $ArchivePath)
        if (-not $downloaded) {
            Write-Warning "gh release download failed (exit $LASTEXITCODE); falling back to curl."
        }
    }

    if (-not $downloaded) {
        if (-not (Get-Command curl -ErrorAction SilentlyContinue)) {
            Write-Error 'Neither gh nor curl is available to download libmpv. Install GitHub CLI (gh).'
            exit 1
        }
        $Url = "https://github.com/$Repo/releases/download/$Tag/$Asset"
        Write-Host "==> curl (--ssl-no-revoke) $Url"
        # --ssl-no-revoke: this machine's schannel cannot reach the CRL/OCSP
        # responder and otherwise aborts with CRYPT_E_NO_REVOCATION_CHECK.
        $previous = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            & curl.exe -L --ssl-no-revoke --fail --output $ArchivePath $Url
        }
        finally {
            $ErrorActionPreference = $previous
        }
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $ArchivePath)) {
            Write-Error "downloading $Asset failed (curl exit $LASTEXITCODE)"
            exit 1
        }
    }

    $archiveDigest = Get-Sha256 -Path $ArchivePath
    if ($archiveDigest -ne $ArchiveSha256) {
        Remove-Item -LiteralPath $ArchivePath -Force
        Write-Error "archive digest mismatch: got $archiveDigest, expected $ArchiveSha256. The artifact may have been replaced upstream; re-pin deliberately."
        exit 1
    }
}

Write-Host "==> archive verified: $ArchivePath"

# Extract only the single member we expect
# (the archive contains exactly one entry, libmpv.so, at the root).
$ExtractDir = Join-Path $CacheDir 'extract'
if (Test-Path -LiteralPath $ExtractDir) {
    Remove-Item -LiteralPath $ExtractDir -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $ExtractDir | Out-Null
Expand-Archive -LiteralPath $ArchivePath -DestinationPath $ExtractDir -Force

$Extracted = Get-ChildItem -LiteralPath $ExtractDir -Recurse -File -Filter 'libmpv.so' |
    Select-Object -First 1
if (-not $Extracted) {
    Write-Error "the archive contains no libmpv.so (looked under $ExtractDir)"
    exit 1
}

$extractedSize = $Extracted.Length
$extractedDigest = Get-Sha256 -Path $Extracted.FullName
if ($extractedDigest -ne $LibrarySha256) {
    Write-Error "extracted libmpv.so digest mismatch: got $extractedDigest, expected $LibrarySha256"
    exit 1
}
if ($extractedSize -ne $LibrarySize) {
    Write-Error "extracted libmpv.so size mismatch: got $extractedSize, expected $LibrarySize"
    exit 1
}

Copy-Item -LiteralPath $Extracted.FullName -Destination $DestSo -Force
Write-Host "==> installed: $DestSo"
Write-Host "    size   $extractedSize"
Write-Host "    sha256 $extractedDigest"
} # end if ($NeedLibmpv)

# --- libc++_shared.so -------------------------------------------------------
# libmpv.so has DT_NEEDED libc++_shared.so, and HarmonyOS devices do not ship
# one system-wide (verified on PLR-AL00: dlopen fails with
# "Error loading shared library libc++_shared.so"). The OHOS NDK (LLVM
# toolchain in the DevEco SDK) carries the matching runtime; copy it next to
# libmpv.so so the HAP carries the dependency. The HAP packager strips nothing
# here and the file is ~1.2MB.
$CppSharedName = 'libc++_shared.so'
$CppSharedDest = Join-Path $DestDir $CppSharedName

$devEcoSdks = @(
    (Join-Path ${env:ProgramFiles} 'Huawei\DevEco Studio\sdk'),
    (Join-Path $env:LOCALAPPDATA 'Huawei\Sdk')
)
$CppSharedSource = $null
foreach ($sdkRoot in $devEcoSdks) {
    if (-not (Test-Path -LiteralPath $sdkRoot)) { continue }
    # The NDK runtime lives under native/llvm/lib/<triple>/; prefer the plain
    # (non-sanitizer, non-arm64e) aarch64 build. Fall back to a recursive scan
    # in case the SDK layout shifts between DevEco versions.
    $candidate = Join-Path $sdkRoot 'default\openharmony\native\llvm\lib\aarch64-linux-ohos\libc++_shared.so'
    if (Test-Path -LiteralPath $candidate) {
        $CppSharedSource = $candidate
        break
    }
    $scanned = Get-ChildItem -LiteralPath $sdkRoot -Recurse -Filter $CppSharedName -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch 'hwasan|arm64e|BiSheng|arm-linux|x86_64' } |
        Select-Object -First 1
    if ($scanned) {
        $CppSharedSource = $scanned.FullName
        break
    }
}

if (-not $CppSharedSource) {
    Write-Error "could not find $CppSharedName in any known DevEco SDK location; install DevEco Studio or copy it manually next to $DestSo"
    exit 1
}

$existingCpp = $null
if (Test-Path -LiteralPath $CppSharedDest) {
    $existingCpp = Get-Sha256 -Path $CppSharedDest
}
$sourceCppDigest = Get-Sha256 -Path $CppSharedSource
if ($existingCpp -ne $sourceCppDigest) {
    Copy-Item -LiteralPath $CppSharedSource -Destination $CppSharedDest -Force
    Write-Host "==> installed: $CppSharedDest"
    Write-Host "    copied from $CppSharedSource"
}
else {
    Write-Host "==> $CppSharedName already installed and verified: $CppSharedDest"
}
