#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (C) 2025 CrazyBoyFeng
#
# build.sh - Build easytier OpenWrt packages (.apk + .ipk) for one target.
#
# This script handles the complete build pipeline:
#   1. Set up Rust toolchain for the target (download prebuilt std or
#      compile from source for tier-3 targets).
#   2. Download 25.12.4 SDK, compile Rust (via Makefile), produce .apk,
#      and save prebuilt binaries to .prebuilt/.
#   3. (Default) Download 23.05.6 SDK, copy prebuilt binaries (via
#      Makefile.legacy), produce .ipk.
#
# Usage:
#   ./build.sh <slug>               # Full: .apk + .ipk
#   ./build.sh <slug> --no-legacy   # Only: .apk (skip Makefile.legacy)
#
# Prerequisites:
#   - rustup (https://rustup.rs)
#   - protoc, clang, libclang-dev, zstd (system packages)
#
# Slugs: x86-64 | mediatek-filogic | ramips-mt7621

set -euo pipefail

# ===================== SDK versions =====================
SDK_NEW_VER="25.12.4"
SDK_NEW_FMT="apk"
SDK_NEW_EXT="zst"

SDK_LEGACY_VER="23.05.6"
SDK_LEGACY_FMT="ipk"
SDK_LEGACY_EXT="xz"

SDK_BASE_URL="https://downloads.openwrt.org/releases"

# ===================== Slug mappings =====================
slug_to_target() {
  case "$1" in
    x86-64)           echo "x86/64" ;;
    mediatek-filogic) echo "mediatek/filogic" ;;
    ramips-mt7621)    echo "ramips/mt7621" ;;
    *)
      echo "ERROR: unknown slug '$1'" >&2
      echo "Supported: x86-64, mediatek-filogic, ramips-mt7621" >&2
      exit 1 ;;
  esac
}

slug_to_rust_target() {
  case "$1" in
    x86-64)           echo "x86_64-unknown-linux-musl" ;;
    mediatek-filogic) echo "aarch64-unknown-linux-musl" ;;
    ramips-mt7621)    echo "mipsel-unknown-linux-musl" ;;
  esac
}

# ===================== Argument parsing =====================
usage() {
  cat <<'EOF'
Usage: ./build.sh <slug> [options]

Build easytier OpenWrt packages for a single target platform.

Arguments:
  slug              Target platform slug
                    (x86-64 | mediatek-filogic | ramips-mt7621)

Options:
  --no-legacy       Skip Step 2 (Makefile.legacy / .ipk)
  -h, --help        Show this help

Examples:
  ./build.sh x86-64              # Full build: .apk + .ipk
  ./build.sh ramips-mt7621 --no-legacy   # Only .apk

Prerequisites:
  rustup  — https://rustup.rs
  protoc, clang, libclang-dev, zstd — system packages
EOF
}

SLUG=""
NO_LEGACY=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-legacy) NO_LEGACY=true; shift ;;
    -h|--help)   usage; exit 0 ;;
    -*)          echo "ERROR: unknown option '$1'" >&2; usage; exit 1 ;;
    *)           SLUG="$1"; shift ;;
  esac
done

if [[ -z "$SLUG" ]]; then
  echo "ERROR: slug is required" >&2
  usage
  exit 1
fi

# ===================== Resolve paths =====================
WORKSPACE="$(cd "$(dirname "$0")" && pwd)"
TARGET="$(slug_to_target "$SLUG")"
RUST_TARGET="$(slug_to_rust_target "$SLUG")"
PREBUILT_DIR="$WORKSPACE/.prebuilt"
OUTPUT_DIR="$WORKSPACE/output"

echo "=== Build configuration ==="
echo "  Slug:        $SLUG"
echo "  Target:      $TARGET"
echo "  Rust target: $RUST_TARGET"
echo "  Legacy:      $(if $NO_LEGACY; then echo 'skip'; else echo 'yes'; fi)"
echo ""

# ===================== Helper functions =====================
banner() {
  echo ""
  echo "=========================================="
  echo "=== $1 ==="
  echo "=========================================="
  echo ""
}

# Download an OpenWrt SDK tarball and extract it.
# Prints the extracted directory name on stdout (captured by caller).
# All log output goes to stderr to avoid polluting the return value.
# Returns 1 if SDK not found.
download_and_extract_sdk() {
  local ver="$1" ext="$2"
  local index="$SDK_BASE_URL/$ver/targets/$TARGET/"

  echo "--- Downloading $ver SDK ---" >&2
  local file
  file=$(curl -sL "$index" \
    | grep -oE "openwrt-sdk-[0-9a-zA-Z._-]+-${SLUG}[0-9a-zA-Z._-]*\.tar\.${ext}" \
    | head -1) || true

  if [[ -z "$file" ]]; then
    echo "WARNING: SDK not found for $ver at $index" >&2
    return 1
  fi

  local dir="${file%.tar.*}"
  echo "  File: $file" >&2

  curl -L "${index}${file}" -o "$WORKSPACE/sdk.tar.${ext}"

  echo "--- Extracting ---" >&2
  cd "$WORKSPACE"
  if [[ "$ext" == "zst" ]]; then
    tar --zstd -xf "sdk.tar.${ext}"
  else
    tar xJf "sdk.tar.${ext}"
  fi
  rm -f "sdk.tar.${ext}"

  echo "$dir"
}

# ===================== Rust toolchain setup =====================
# For tier-1/2 targets (x86-64, mediatek-filogic): prebuilt std exists,
# download it via rustup target add (fast, seconds).
# For tier-3 targets (ramips-mt7621 / mipsel): no prebuilt std, need
# nightly + rust-src to compile std from source via -Zbuild-std.
setup_rust_toolchain() {
  banner "Setting up Rust toolchain"

  if ! command -v rustup &>/dev/null; then
    echo "ERROR: rustup not found. Install it from https://rustup.rs" >&2
    exit 1
  fi

  case "$SLUG" in
    ramips-mt7621)
      echo "Tier-3 target: no prebuilt std, will compile from source (-Zbuild-std)"
      rustup default nightly
      rustup component add rust-src
      ;;
    *)
      echo "Tier-1/2 target: downloading prebuilt std"
      rustup default stable
      rustup target add "$RUST_TARGET"
      ;;
  esac

  echo "  Rust: $(rustc --version)"
  echo "  Cargo: $(cargo --version)"
}

# ===================== Step 1: 25.12.4 SDK =====================
# Compile Rust via Makefile, produce .apk, save prebuilt binaries.
run_step1() {
  banner "Step 1: $SDK_NEW_VER SDK (compile Rust + $SDK_NEW_FMT)"

  local sdk_dir
  sdk_dir=$(download_and_extract_sdk "$SDK_NEW_VER" "$SDK_NEW_EXT") || {
    echo "ERROR: $SDK_NEW_VER SDK unavailable — cannot compile." >&2
    exit 1
  }

  cd "$WORKSPACE/$sdk_dir"

  # --- feeds ---
  echo "--- feeds update ---"
  ./scripts/feeds update -a
  # Do NOT use 'feeds install -a'.  That makes ALL feed packages
  # available, causing make defconfig to enable hundreds of unrelated
  # packages by default and build them — wasting CI time.

  # --- Copy package source ---
  echo "--- Copying package source ---"
  mkdir -p package/easytier
  cp -r "$WORKSPACE/Makefile" "$WORKSPACE/patches" "$WORKSPACE/files" \
    package/easytier/

  # --- Patch Makefile for pre-installed toolchain ---
  # The SDK would otherwise build rust/host and protobuf/host from source
  # (very slow).  Since we use rustup and system protoc, remove those
  # dependencies and point PROTOC to the system binary.
  echo "--- Patching Makefile ---"
  sed -i 's|rust/host protobuf/host||' package/easytier/Makefile
  sed -i 's|PROTOC=\$(STAGING_DIR_HOSTPKG)/bin/protoc|PROTOC=/usr/bin/protoc|' \
    package/easytier/Makefile

  # For tier-3 targets (mipsel), replace the Build/Compile lines with
  # -Zbuild-std variants.  Anchors on EASYTIER_COMPILE_* comment markers.
  if [[ "$SLUG" == "ramips-mt7621" ]]; then
    echo "--- Injecting -Z build-std for tier-3 target ---"
    sed -i '/^# EASYTIER_COMPILE_LITE/{n;s|.*|Build/Compile=$(CARGO_PKG_VARS) cargo $(CARGO_PKG_ARGS) -Z build-std=std,panic_abort install -v --profile $(CARGO_PKG_PROFILE) --features "$(strip $(RUST_PKG_FEATURES))" --root $(PKG_INSTALL_DIR) --path "$(PKG_BUILD_DIR)/easytier" --bin easytier-core --no-default-features \&\& $(TARGET_CROSS)strip --remove-section=.eh_frame --remove-section=.eh_frame_hdr $(PKG_INSTALL_DIR)/bin/easytier-core|}' package/easytier/Makefile
    sed -i '/^# EASYTIER_COMPILE_DEFAULT/{n;s|.*|Build/Compile=$(CARGO_PKG_VARS) cargo $(CARGO_PKG_ARGS) -Z build-std=std,panic_abort install -v --profile $(CARGO_PKG_PROFILE) --root $(PKG_INSTALL_DIR) --path "$(PKG_BUILD_DIR)/easytier" --bin easytier-core \&\& $(TARGET_CROSS)strip --remove-section=.eh_frame --remove-section=.eh_frame_hdr $(PKG_INSTALL_DIR)/bin/easytier-core|}' package/easytier/Makefile
  fi

  # --- Configure & build ---
  printf 'CONFIG_PACKAGE_easytier=y\nCONFIG_PACKAGE_easytier-lite=y\n' >> .config
  make defconfig

  echo "--- Building packages ($SDK_NEW_FMT) ---"
  make package/easytier/compile V=s || \
    make package/easytier/compile V=s

  # --- Collect .apk artifacts ---
  # apk filenames lack architecture info (e.g. easytier-2.6.4-r1.apk),
  # so insert PKGARCH before .apk to avoid overwrites.  Use '-' separator
  # (apk convention; ipk uses '_').
  echo "--- Collecting $SDK_NEW_FMT artifacts ---"
  local pkgarch
  pkgarch="$(find bin/packages -mindepth 1 -maxdepth 1 -type d \
    | head -1 | xargs basename)"
  echo "  PKGARCH: $pkgarch"

  mkdir -p "$OUTPUT_DIR/$SDK_NEW_VER"
  while IFS= read -r -d '' f; do
    local base="${f##*/}"
    local name="${base%.apk}"
    if [[ "$base" != "$name" ]]; then
      cp "$f" "$OUTPUT_DIR/$SDK_NEW_VER/${name}-${pkgarch}.apk"
    else
      cp "$f" "$OUTPUT_DIR/$SDK_NEW_VER/"
    fi
  done < <(find bin/packages -type f -name 'easytier*' -print0 2>/dev/null)

  # --- Save prebuilt binaries for Step 2 ---
  # Copy from .pkgdir (survives post-build autoremove) rather than
  # extracting from apk (Alpine format is fragile).
  echo "--- Saving prebuilt binaries ---"
  mkdir -p "$PREBUILT_DIR/default" "$PREBUILT_DIR/lite"
  for variant in default lite; do
    local pkgdir_name="easytier"
    [[ "$variant" == "lite" ]] && pkgdir_name="easytier-lite"
    local bin
    bin=$(find build_dir \
      -path "*/easytier-${variant}*/.pkgdir/${pkgdir_name}/usr/bin/easytier-core" \
      -type f 2>/dev/null | head -1) || true
    if [[ -n "$bin" ]]; then
      cp "$bin" "$PREBUILT_DIR/$variant/"
      echo "  $variant: $(ls -lh "$PREBUILT_DIR/$variant/easytier-core" \
        | awk '{print $5}')"
    else
      echo "  WARNING: easytier-core not found for variant '$variant'"
    fi
  done

  # Cleanup
  cd "$WORKSPACE"
  rm -rf "$sdk_dir"
  echo "=== $SDK_NEW_VER ($SDK_NEW_FMT) done ==="
}

# ===================== Step 2: 23.05.6 SDK =====================
# Copy prebuilt binaries via Makefile.legacy, produce .ipk.
run_step2() {
  banner "Step 2: $SDK_LEGACY_VER SDK (package $SDK_LEGACY_FMT)"

  # Verify prebuilt binaries exist (produced by Step 1)
  if [[ ! -f "$PREBUILT_DIR/default/easytier-core" \
     || ! -f "$PREBUILT_DIR/lite/easytier-core" ]]; then
    echo "ERROR: prebuilt binaries not found in $PREBUILT_DIR" >&2
    echo "  Expected: $PREBUILT_DIR/default/easytier-core" >&2
    echo "  Expected: $PREBUILT_DIR/lite/easytier-core" >&2
    exit 1
  fi

  local sdk_dir
  sdk_dir=$(download_and_extract_sdk "$SDK_LEGACY_VER" "$SDK_LEGACY_EXT") || {
    echo "WARNING: $SDK_LEGACY_VER SDK unavailable, skipping legacy build" >&2
    return 0
  }

  cd "$WORKSPACE/$sdk_dir"

  # --- feeds ---
  echo "--- feeds update ---"
  ./scripts/feeds update -a

  # --- Copy package source (Makefile.legacy) ---
  echo "--- Copying package source (Makefile.legacy) ---"
  mkdir -p package/easytier
  cp "$WORKSPACE/Makefile.legacy" package/easytier/Makefile
  cp -r "$WORKSPACE/files" package/easytier/

  # --- Configure & build ---
  printf 'CONFIG_PACKAGE_easytier=y\nCONFIG_PACKAGE_easytier-lite=y\n' >> .config
  make defconfig

  echo "--- Building packages ($SDK_LEGACY_FMT) — prebuilt only ---"
  make package/easytier/compile V=s PREBUILT_DIR="$PREBUILT_DIR" || \
    make package/easytier/compile V=s PREBUILT_DIR="$PREBUILT_DIR"

  # --- Collect .ipk artifacts ---
  echo "--- Collecting $SDK_LEGACY_FMT artifacts ---"
  mkdir -p "$OUTPUT_DIR/$SDK_LEGACY_VER"
  find bin/packages -type f -name 'easytier*' \
    -exec cp {} "$OUTPUT_DIR/$SDK_LEGACY_VER/" \; 2>/dev/null || true

  # Cleanup
  cd "$WORKSPACE"
  rm -rf "$sdk_dir"
  echo "=== $SDK_LEGACY_VER ($SDK_LEGACY_FMT) done ==="
}

# ===================== Print summary =====================
print_summary() {
  banner "Build complete — $SLUG ($TARGET)"
  echo "Output: $OUTPUT_DIR/"

  for ver in "$SDK_NEW_VER" "$SDK_LEGACY_VER"; do
    if [[ -d "$OUTPUT_DIR/$ver" ]]; then
      local count
      count=$(find "$OUTPUT_DIR/$ver" -maxdepth 1 -type f | wc -l)
      if [[ "$count" -gt 0 ]]; then
        echo ""
        echo "  $ver:"
        ls -lh "$OUTPUT_DIR/$ver/" 2>/dev/null \
          | awk 'NR>1{print "    "$NF, $5}'
      fi
    fi
  done
}

# ===================== Main =====================
mkdir -p "$OUTPUT_DIR"

setup_rust_toolchain
run_step1
$NO_LEGACY || run_step2

print_summary
