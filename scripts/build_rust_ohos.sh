#!/usr/bin/env bash
# Builds the Rust native core (rust/ -> libfqapi_core.so) for OpenHarmony arm64
# and copies it into ohos/entry/libs/arm64-v8a.
#
# Why this script exists: flutter_rust_bridge loads the crate by bare name
# (`ExternalLibrary.open('libfqapi_core.so')`) on OHOS, so the library must sit
# in the module's libs directory before Hvigor assembles the HAP. `flutter build
# hap` does not cross-compile the crate, and `scripts/build_rust_backend.sh`
# only targets Android. Without this step the HAP ships libapp.so/libflutter.so
# and the app dies at startup with:
#
#   Invalid argument(s): Failed to load dynamic library 'libfqapi_core.so':
#   Error loading shared library libfqapi_core.so: No such file or directory
#
# This is the POSIX twin of scripts/build_rust_ohos.ps1, which stays the entry
# point on Windows (where rustc cannot execute the SDK's shell linker wrappers
# and the .bat equivalents are used instead). Both must produce the same
# library from the same inputs; keep them in step.
#
# The OHOS SDK is located through OHOS_NDK_HOME (the SDK's default/openharmony
# directory, as exported by ErBWs/setup-ohos in CI) or OHOS_SDK_HOME (the
# native directory, as used on Windows).
#
# Usage:
#   ./scripts/build_rust_ohos.sh
#   ./scripts/build_rust_ohos.sh --profile debug
#   ./scripts/build_rust_ohos.sh --skip-copy   # compile only, leave libs/ alone
#
# Unknown arguments are a hard error, never silently ignored: a typo such as
# --skip-cop would otherwise build something different from what was asked.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(dirname "$SCRIPT_DIR")"
MANIFEST="$APP_DIR/rust/Cargo.toml"
TARGET="aarch64-unknown-linux-ohos"

PROFILE=release
SKIP_COPY=0
usage() {
  echo "Usage: $0 [--skip-copy] [--profile <release|debug>|--profile=<release|debug>]" >&2
}
while [ "$#" -gt 0 ]; do
  case "$1" in
    --skip-copy) SKIP_COPY=1 ;;
    --profile)
      if [ "$#" -lt 2 ]; then
        echo "错误：--profile 需要一个取值（release|debug）。" >&2
        usage
        exit 2
      fi
      PROFILE="$2"
      shift
      ;;
    --profile=*) PROFILE="${1#*=}" ;;
    -h|--help) usage; exit 0 ;;
    *) echo "错误：未知参数 $1" >&2; usage; exit 2 ;;
  esac
  shift
done
case "$PROFILE" in
  release|debug) ;;
  *) echo "错误：--profile 只接受 release 或 debug（收到 $PROFILE）。" >&2; exit 2 ;;
esac

if ! command -v cargo >/dev/null 2>&1; then
  echo '错误：PATH 中找不到 cargo，请先安装 Rust 工具链。' >&2
  exit 1
fi
if [ ! -f "$MANIFEST" ]; then
  echo "错误：找不到 Rust 核心清单 $MANIFEST" >&2
  exit 1
fi
if ! rustup target list --installed 2>/dev/null | grep -qx "$TARGET"; then
  echo "错误：未安装 rustup target $TARGET，请执行 rustup target add $TARGET" >&2
  exit 1
fi

# Resolve the SDK. OHOS_NDK_HOME is the CI value (sdk/default/openharmony);
# OHOS_SDK_HOME is the Windows value (the native directory itself). Either may
# be set, and both may point at a layout whose `tools` directory is one or two
# levels up, so probe instead of pinning a single shape.
OHOS_NATIVE=""
for candidate in "${OHOS_NDK_HOME:-}/native" "${OHOS_SDK_HOME:-}"; do
  [ -n "$candidate" ] || continue
  if [ -d "$candidate/llvm" ]; then
    OHOS_NATIVE="$candidate"
    break
  fi
done
if [ -z "$OHOS_NATIVE" ]; then
  echo '错误：未定位到 OHOS SDK native 目录。请设置 OHOS_NDK_HOME（<sdk>/default/openharmony）或 OHOS_SDK_HOME（<sdk>/<version>/native）。' >&2
  exit 1
fi

# The wrapper named after the target is the SDK's own cross linker. It lives in
# <native>/llvm/bin on every platform; the sibling `tools` directory only holds
# Windows `.bat` shims (which is why the first CI attempt failed to find it).
# Probe both, in that order, so either layout works.
TOOLS_DIR=""
for candidate in "$OHOS_NATIVE/llvm/bin" "$OHOS_NATIVE/tools" \
                 "$(dirname "$OHOS_NATIVE")/tools" \
                 "$(dirname "$(dirname "$OHOS_NATIVE")")/tools"; do
  if [ -x "$candidate/$TARGET-clang" ]; then
    TOOLS_DIR="$candidate"
    break
  fi
done
if [ -z "$TOOLS_DIR" ]; then
  echo "错误：未找到 OHOS 链接器包装 $TARGET-clang（查找 $OHOS_NATIVE/llvm/bin 及其上级 tools）。" >&2
  exit 1
fi

CC_BIN="$TOOLS_DIR/$TARGET-clang"
CXX_BIN="$TOOLS_DIR/$TARGET-clang++"
AR_BIN="$OHOS_NATIVE/llvm/bin/llvm-ar"
if [ ! -x "$AR_BIN" ]; then
  echo "错误：未找到 $AR_BIN" >&2
  exit 1
fi

# Rust build scripts (cc-rs) look up CC/CXX/AR per target; without these the
# build fails with `failed to find tool "cc"`.
export CC_aarch64_unknown_linux_ohos="$CC_BIN"
export AR_aarch64_unknown_linux_ohos="$AR_BIN"
if [ -x "$CXX_BIN" ]; then
  export CXX_aarch64_unknown_linux_ohos="$CXX_BIN"
fi

# Cargo defaults the linker to plain `cc` for this target, which on the runner
# is the host gcc; linking arm64 objects with it fails with
# "Relocations in generic ELF (EM: 183)" / "file in wrong format". Point the
# target's linker at the SDK wrapper instead.
#
# Do not add `-C link-self-contained=no` here: the target rejects the option
# outright ("option `-C link-self-contained` is not supported on this
# target"), and it is unnecessary once the linker is the SDK's own.
export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_OHOS_LINKER="$CC_BIN"

echo "==> OHOS SDK: $OHOS_NATIVE"
echo "==> CC: $CC_BIN"

PROFILE_ARGS=()
if [ "$PROFILE" = release ]; then
  PROFILE_ARGS=(--release)
fi

echo "==> cargo build --target $TARGET ($PROFILE)..."
cd "$APP_DIR"
cargo build --manifest-path "$MANIFEST" --target "$TARGET" --locked "${PROFILE_ARGS[@]}"

BUILT_SO="$APP_DIR/rust/target/$TARGET/$PROFILE/libfqapi_core.so"
if [ ! -f "$BUILT_SO" ]; then
  echo "错误：构建未产出 $BUILT_SO" >&2
  exit 1
fi
# An empty or truncated .so would still be copied and still be named correctly,
# so check the ELF magic rather than only the path's existence.
if [ "$(head -c 4 "$BUILT_SO" | od -An -tx1 | tr -d ' \n')" != "7f454c46" ]; then
  echo "错误：$BUILT_SO 不是 ELF 文件" >&2
  exit 1
fi
echo "==> built: $BUILT_SO ($(stat -c %s "$BUILT_SO" 2>/dev/null || wc -c < "$BUILT_SO") bytes)"

if [ "$SKIP_COPY" -eq 1 ]; then
  echo '==> --skip-copy given; not copying into ohos/entry/libs'
  exit 0
fi

# flutter_rust_bridge resolves the bare library name from the HAP's
# libs/<arch> directory, which is where Hvigor packs this path.
DEST_DIR="$APP_DIR/ohos/entry/libs/arm64-v8a"
mkdir -p "$DEST_DIR"
install -m 0644 "$BUILT_SO" "$DEST_DIR/libfqapi_core.so"
echo "==> ohos libs: $DEST_DIR/libfqapi_core.so"
if command -v sha256sum >/dev/null 2>&1; then
  sha256sum "$DEST_DIR/libfqapi_core.so"
fi
