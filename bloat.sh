#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (C) 2025 CrazyBoyFeng
#
# bloat.sh - Build easytier-core (lite) with DWARF debug info and run
# cargo-bloat for per-crate size analysis.
#
# This is a standalone analysis tool — it does NOT use the OpenWrt SDK or
# produce any packages.  It builds directly with cargo on the host.
#
# Key differences from the production build:
#   - LTO=off   : preserves DWARF compile-unit → crate attribution
#   - strip=false: keeps symbol table for cargo-bloat
#   - debug=true : emits DWARF debug info
#
# Usage:
#   ./bloat.sh              # Build + analyze + save
#
# Output:
#   output/bloat-report.txt  — per-crate text breakdown
#   output/easytier-core     — the unstripped ELF binary

set -euo pipefail

# ===================== Read config from Makefile =====================
WORKSPACE="$(cd "$(dirname "$0")" && pwd)"

# Extract PKG_VERSION from Makefile (e.g. "2.6.4")
VERSION=$(sed -n 's/^PKG_VERSION:=\(.*\)$/\1/p' "${WORKSPACE}/Makefile")
if [[ -z "$VERSION" ]]; then
  echo "ERROR: cannot read PKG_VERSION from Makefile" >&2
  exit 1
fi

# Extract RUST_PKG_FEATURES for the lite variant
LITE_FEATURES=$(sed -n '/ifeq.*BUILD_VARIANT.*lite/,/endif/s/^  RUST_PKG_FEATURES:=\(.*\)$/\1/p' "${WORKSPACE}/Makefile")
if [[ -z "$LITE_FEATURES" ]]; then
  echo "ERROR: cannot read RUST_PKG_FEATURES (lite) from Makefile" >&2
  exit 1
fi

SOURCE_URL="https://codeload.github.com/EasyTier/EasyTier/tar.gz/v${VERSION}"
RUST_TARGET="x86_64-unknown-linux-musl"

SRC_DIR="${WORKSPACE}/.bloat-src"
OUTPUT_DIR="${WORKSPACE}/.bloat-output"

# ===================== Setup =====================
banner() {
  echo ""
  echo "=========================================="
  echo "=== $1 ==="
  echo "=========================================="
  echo ""
}

banner "Installing cargo-bloat"
if ! command -v cargo-bloat &>/dev/null; then
  cargo install cargo-bloat --locked
fi

banner "Setting up Rust toolchain"
if ! command -v rustup &>/dev/null; then
  echo "ERROR: rustup not found. Install it from https://rustup.rs" >&2
  exit 1
fi
rustup default stable
rustup target add "$RUST_TARGET"
rustup component add rust-src

echo "  Rust: $(rustc --version)"
echo "  Cargo: $(cargo --version)"
echo "  cargo-bloat: $(cargo bloat --version 2>/dev/null | head -1 || echo 'unknown')"

# ===================== Prepare source =====================
banner "Preparing EasyTier source (v${VERSION})"

if [[ -d "$SRC_DIR/easytier" && -f "$SRC_DIR/easytier/Cargo.toml" ]]; then
  echo "  Source already extracted, reusing"
else
  rm -rf "$SRC_DIR"
  mkdir -p "$SRC_DIR"
  echo "  Downloading ${SOURCE_URL}..."
  curl -sL "$SOURCE_URL" | tar -C "$SRC_DIR" --strip-components=1 -xzf -
  echo "  Source extracted"
fi

# ===================== Apply patches =====================
cd "$SRC_DIR/easytier"
PATCHES_DIR="${WORKSPACE}/patches"
if [[ -d "$PATCHES_DIR" ]]; then
  echo "  Applying patches from ${PATCHES_DIR}/"
  for patch in "${PATCHES_DIR}"/*.patch; do
    if [[ -f "$patch" ]]; then
      echo "    $(basename "$patch")"
      patch -p1 < "$patch"
    fi
  done
fi

cd "$SRC_DIR/easytier"

# ===================== Build =====================
banner "Building easytier-core (lite) for bloat analysis"
echo "  Target:  ${RUST_TARGET}"
echo "  Features: ${LITE_FEATURES}"
echo "  LTO: off"
echo "  Strip: false"
echo "  Debug: true"
echo ""

export CARGO_PROFILE_RELEASE_LTO=off
export CARGO_PROFILE_RELEASE_STRIP=false
export CARGO_PROFILE_RELEASE_DEBUG=true
export CARGO_PROFILE_RELEASE_OPT_LEVEL=z
export CARGO_PROFILE_RELEASE_PANIC=abort
export CARGO_PROFILE_RELEASE_CODEGEN_UNITS=1

# Remap paths to keep output deterministic
export RUSTFLAGS="--remap-path-prefix=$(pwd)/="

cargo build --release --target "$RUST_TARGET" \
  --bin easytier-core \
  --no-default-features \
  --features "$LITE_FEATURES" \
  --locked

BINARY="target/${RUST_TARGET}/release/easytier-core"
echo ""
echo "  Binary: $(ls -lh "$BINARY" | awk '{print $5, $NF}')"

# ===================== Bloat analysis =====================
banner "Running cargo-bloat"

mkdir -p "$OUTPUT_DIR"

cargo bloat --release --target "$RUST_TARGET" \
  --bin easytier-core \
  --crates \
  --target-dir target \
  > "${OUTPUT_DIR}/bloat-report.txt"

echo "  Report: ${OUTPUT_DIR}/bloat-report.txt"

# ===================== Copy binary =====================
cp "$BINARY" "${OUTPUT_DIR}/easytier-core"
echo "  Binary: ${OUTPUT_DIR}/easytier-core ($(ls -lh "${OUTPUT_DIR}/easytier-core" | awk '{print $5}'))"

# ===================== Cleanup source =====================
cd "$WORKSPACE"
rm -rf "$SRC_DIR"
echo ""
echo "=== Bloat analysis complete ==="
