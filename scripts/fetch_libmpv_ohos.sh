#!/usr/bin/env bash
# Fetches the prebuilt libmpv (OpenHarmony arm64-v8a) and installs it, together
# with libc++_shared.so, into ohos/entry/libs/arm64-v8a.
#
# Why this script exists: the OHOS playback backend decodes through libmpv, which
# media_kit loads by bare name (`DynamicLibrary.open('libmpv.so')`). The HAP must
# therefore carry the library in the entry module's libs directory. media_kit
# upstream fetches the same artifact from a CMake `file(DOWNLOAD ...)` step, which
# is not available here because we deliberately do not depend on
# media_kit_libs_ohos (its Android module conflicts with the project's AGP 9
# toolchain). This script performs the equivalent download, verifies both the
# archive and the extracted library against pinned digests, and installs the .so.
#
# This is the POSIX twin of scripts/fetch_libmpv_ohos.ps1, which stays the entry
# point on Windows (curl there needs --ssl-no-revoke for schannel's missing
# revocation responder). Both pin the same digests; keep them in step.
#
# The artifact is pinned to one release: 20261013-hdr of
# p1nbored/libmpv-ohos-build (the build used by media_kit's own OHOS support).
# 24MB, arm64-v8a only.
#
# Usage:
#   ./scripts/fetch_libmpv_ohos.sh
#   ./scripts/fetch_libmpv_ohos.sh --force    # re-download even if present
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(dirname "$SCRIPT_DIR")"
REPO="p1nbored/libmpv-ohos-build"
TAG="20261013-hdr"
ASSET="libmpv_aarch64.zip"

# Pinned digests. The archive digest guards the download; the library digest is
# the one that actually ends up in the HAP, so it is verified separately (the
# archive could unpack to a different member on a silently retagged release).
ARCHIVE_SHA256="140e2c5a6d38572a1f8418cc2463c330077837a38609504c4d532825060e8617"
LIBRARY_SHA256="6add9a06c5c9f4993895a9aa7ef6f541c499d3d8461d949ce0ace2377acbf940"
LIBRARY_SIZE=24539592

CACHE_DIR="$APP_DIR/.tmp-libmpv"
DEST_DIR="$APP_DIR/ohos/entry/libs/arm64-v8a"
DEST_SO="$DEST_DIR/libmpv.so"

FORCE=0
case "${1:-}" in
  "") ;;
  --force) FORCE=1 ;;
  -h|--help) sed -n '1,40p' "$0"; exit 0 ;;
  *) echo "错误：未知参数 $1" >&2; exit 2 ;;
esac

mkdir -p "$DEST_DIR"

sha256_of() {
  sha256sum "$1" | cut -d ' ' -f 1
}

NEED_LIBMPV=1
if [ "$FORCE" -eq 0 ] && [ -f "$DEST_SO" ]; then
  existing="$(sha256_of "$DEST_SO")"
  if [ "$existing" = "$LIBRARY_SHA256" ]; then
    echo "==> libmpv already installed and verified: $DEST_SO"
    echo "    sha256 $existing"
    NEED_LIBMPV=0
  else
    echo "警告：现有 libmpv.so 的 sha256 为 $existing，期望 $LIBRARY_SHA256，重新获取。" >&2
  fi
fi

if [ "$NEED_LIBMPV" -eq 1 ]; then
  mkdir -p "$CACHE_DIR"
  ARCHIVE_PATH="$CACHE_DIR/$ASSET"

  ARCHIVE_OK=0
  if [ "$FORCE" -eq 0 ] && [ -f "$ARCHIVE_PATH" ]; then
    if [ "$(sha256_of "$ARCHIVE_PATH")" = "$ARCHIVE_SHA256" ]; then
      ARCHIVE_OK=1
    else
      echo '警告：缓存压缩包摘要不符，删除后重新下载。' >&2
      rm -f "$ARCHIVE_PATH"
    fi
  fi

  if [ "$ARCHIVE_OK" -eq 0 ]; then
    rm -f "$ARCHIVE_PATH"
    URL="https://github.com/$REPO/releases/download/$TAG/$ASSET"
    downloaded=0
    if command -v gh >/dev/null 2>&1; then
      echo "==> gh release download $TAG -R $REPO -p $ASSET"
      if gh release download "$TAG" -R "$REPO" -p "$ASSET" --output "$ARCHIVE_PATH"; then
        downloaded=1
      else
        echo '警告：gh release download 失败，回退到 curl。' >&2
      fi
    fi
    if [ "$downloaded" -eq 0 ]; then
      if ! command -v curl >/dev/null 2>&1; then
        echo '错误：既没有 gh 也没有 curl，无法下载 libmpv。' >&2
        exit 1
      fi
      echo "==> curl $URL"
      curl -L --fail --output "$ARCHIVE_PATH" "$URL"
    fi

    archive_digest="$(sha256_of "$ARCHIVE_PATH")"
    if [ "$archive_digest" != "$ARCHIVE_SHA256" ]; then
      rm -f "$ARCHIVE_PATH"
      echo "错误：压缩包摘要不符：得到 $archive_digest，期望 $ARCHIVE_SHA256。上游产物可能被替换，需重新固化后再更新。" >&2
      exit 1
    fi
  fi
  echo "==> 压缩包已校验：$ARCHIVE_PATH"

  # The archive contains exactly one entry, libmpv.so, at the root.
  EXTRACT_DIR="$CACHE_DIR/extract"
  rm -rf "$EXTRACT_DIR"
  mkdir -p "$EXTRACT_DIR"
  if command -v unzip >/dev/null 2>&1; then
    unzip -q -o "$ARCHIVE_PATH" -d "$EXTRACT_DIR"
  else
    python3 -c 'import sys,zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])' \
      "$ARCHIVE_PATH" "$EXTRACT_DIR"
  fi

  EXTRACTED="$(find "$EXTRACT_DIR" -type f -name 'libmpv.so' | head -n1)"
  if [ -z "$EXTRACTED" ]; then
    echo "错误：压缩包内没有 libmpv.so（查找于 $EXTRACT_DIR）" >&2
    exit 1
  fi
  extracted_size="$(wc -c < "$EXTRACTED" | tr -d ' ')"
  extracted_digest="$(sha256_of "$EXTRACTED")"
  if [ "$extracted_digest" != "$LIBRARY_SHA256" ]; then
    echo "错误：解出的 libmpv.so 摘要不符：得到 $extracted_digest，期望 $LIBRARY_SHA256" >&2
    exit 1
  fi
  if [ "$extracted_size" != "$LIBRARY_SIZE" ]; then
    echo "错误：解出的 libmpv.so 大小不符：得到 $extracted_size，期望 $LIBRARY_SIZE" >&2
    exit 1
  fi
  install -m 0644 "$EXTRACTED" "$DEST_SO"
  echo "==> 已安装：$DEST_SO"
  echo "    size   $extracted_size"
  echo "    sha256 $extracted_digest"
fi

# --- libc++_shared.so -------------------------------------------------------
# libmpv.so has DT_NEEDED libc++_shared.so, and HarmonyOS devices do not ship
# one system-wide (verified on PLR-AL00: dlopen fails with
# "Error loading shared library libc++_shared.so"). The OHOS NDK (LLVM
# toolchain in the DevEco SDK) carries the matching runtime; copy it next to
# libmpv.so so the HAP carries the dependency. In CI the NDK is exported as
# OHOS_NDK_HOME by ErBWs/setup-ohos, so the runtime is on disk already -- no
# download and no version skew against the toolchain that builds the HAP.
CPP_SHARED_NAME='libc++_shared.so'
CPP_SHARED_DEST="$DEST_DIR/$CPP_SHARED_NAME"
CPP_SHARED_SOURCE=""

for candidate_root in "${OHOS_NDK_HOME:-}" "${OHOS_SDK_HOME:-}"; do
  [ -n "$candidate_root" ] || continue
  candidate="$candidate_root/native/llvm/lib/aarch64-linux-ohos/$CPP_SHARED_NAME"
  if [ -f "$candidate" ]; then
    CPP_SHARED_SOURCE="$candidate"
    break
  fi
done
if [ -z "$CPP_SHARED_SOURCE" ]; then
  # Fall back to a scan: the SDK layout has shifted between DevEco versions.
  for scan_root in "${OHOS_NDK_HOME:-}" "${OHOS_SDK_HOME:-}"; do
    [ -n "$scan_root" ] || continue
    candidate="$(find "$scan_root" -name "$CPP_SHARED_NAME" -type f 2>/dev/null \
      | grep -vE 'hwasan|arm64e|BiSheng|arm-linux|x86_64' | head -n1)"
    if [ -n "$candidate" ]; then
      CPP_SHARED_SOURCE="$candidate"
      break
    fi
  done
fi

if [ -z "$CPP_SHARED_SOURCE" ]; then
  echo "错误：在已知的 OHOS SDK 位置找不到 $CPP_SHARED_NAME。请设置 OHOS_NDK_HOME，或手动把它放到 $DEST_SO 旁边。" >&2
  exit 1
fi

source_digest="$(sha256_of "$CPP_SHARED_SOURCE")"
existing_cpp=""
if [ -f "$CPP_SHARED_DEST" ]; then
  existing_cpp="$(sha256_of "$CPP_SHARED_DEST")"
fi
if [ "$existing_cpp" != "$source_digest" ]; then
  install -m 0644 "$CPP_SHARED_SOURCE" "$CPP_SHARED_DEST"
  echo "==> 已安装：$CPP_SHARED_DEST"
  echo "    来自 $CPP_SHARED_SOURCE"
else
  echo "==> $CPP_SHARED_NAME 已安装且一致：$CPP_SHARED_DEST"
fi
