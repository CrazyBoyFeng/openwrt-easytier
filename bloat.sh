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
#   bloat-output/bloat-report.txt  — per-crate text breakdown
#   bloat-output/easytier-core     — the unstripped ELF binary

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
HOST_TARGET="$(rustc -vV 2>/dev/null | sed -n 's/^host: //p')"
: "${HOST_TARGET:=x86_64-unknown-linux-gnu}"
HOST_ARCH="${HOST_TARGET%%-*}"
SRC_DIR="${WORKSPACE}/.bloat-src"
OUTPUT_DIR="${WORKSPACE}/bloat-output"

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
# Patches use paths like "easytier/Cargo.toml" (with -p1).
# After --strip-components=1 the workspace root is $SRC_DIR/,
# so we must stand in $SRC_DIR/ for -p1 to resolve correctly.
cd "$SRC_DIR"
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

# ===================== Build =====================
banner "Building easytier-core (lite) for bloat analysis"
echo "  WORKSPACE:  ${WORKSPACE}"
echo "  SRC_DIR:    ${SRC_DIR}"
echo "  OUTPUT_DIR: ${OUTPUT_DIR}"
echo "  pwd:        $(pwd)"
echo "  Target:     ${HOST_TARGET}"
echo "  Features:   ${LITE_FEATURES}"
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

# Force target dir to a known absolute path (eliminates all guessing
# about where cargo puts build artifacts in a workspace).
export CARGO_TARGET_DIR="${SRC_DIR}/target"

# Set PROTOC explicitly (same as Makefile CARGO_PKG_VARS)
export PROTOC="${PROTOC:-$(which protoc 2>/dev/null || echo /usr/bin/protoc)}"

# Remap paths to keep output deterministic
export RUSTFLAGS="--remap-path-prefix=$(pwd)/="

# Build with --path pointing to easytier/ subdirectory, same as
# the Makefile's Build/Compile/Cargo (cargo install --path).  This treats
# easytier/ as a standalone crate outside the workspace, avoiding
# irrelevant workspace members and stale lockfile entries.
cargo build --release \
  --path "$SRC_DIR/easytier" \
  --bin easytier-core \
  --no-default-features \
  --features "$LITE_FEATURES" \
  --locked \
  || { echo "ERROR: cargo build failed (exit $?)" >&2; exit 1; }

BINARY="${CARGO_TARGET_DIR}/release/easytier-core"
echo ""
if [[ -f "$BINARY" ]]; then
  echo "  Binary: $(ls -lh "$BINARY" | awk '{print $5, $NF}')"
else
  echo "  WARNING: binary not found at ${BINARY}"
  echo "  find in ${CARGO_TARGET_DIR}:"
  find "${CARGO_TARGET_DIR}" -name 'easytier-core' -type f 2>/dev/null || echo "    (not found)"
fi

# ===================== Bloat analysis =====================
banner "Running cargo-bloat"

mkdir -p "$OUTPUT_DIR"

echo "  Running cargo bloat..."
cargo bloat --release \
  --package easytier \
  --bin easytier-core \
  --crates \
  > "${OUTPUT_DIR}/bloat-report.txt" 2>&1 \
  || true

echo "  bloat-report.txt: $(wc -l < "${OUTPUT_DIR}/bloat-report.txt" 2>/dev/null || echo '0') lines"
echo "  First 3 lines:"
head -3 "${OUTPUT_DIR}/bloat-report.txt" 2>/dev/null

# ===================== Copy binary =====================
if [[ -f "$BINARY" ]]; then
  cp "$BINARY" "${OUTPUT_DIR}/easytier-core"
  echo "  Binary copied to ${OUTPUT_DIR}/easytier-core"
else
  echo "  WARNING: skipping binary copy, file not found at ${BINARY}"
fi

echo ""
echo "  Contents of ${OUTPUT_DIR}/:"
ls -lh "$OUTPUT_DIR/"

# ===================== Write GitHub Step Summary =====================
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo "## Bloat Analysis Results"
    echo ""
    echo "| File | Size |"
    echo "|------|------|"
    if [[ -f "$BINARY" ]]; then
      echo "| easytier-core | $(ls -lh "$BINARY" | awk '{print $5}') |"
    fi
    if [[ -f "${OUTPUT_DIR}/bloat-report.txt" ]]; then
      echo "| bloat-report.txt | $(wc -l < "${OUTPUT_DIR}/bloat-report.txt") lines |"
    fi
    echo ""
    echo "### Paths"
    echo "- WORKSPACE: \${WORKSPACE}"
    echo "- SRC_DIR: \${SRC_DIR}"
    echo "- CARGO_TARGET_DIR: \${CARGO_TARGET_DIR}"
    echo "- OUTPUT_DIR: \${OUTPUT_DIR}"
    echo "- BINARY: \${BINARY}"
    echo ""
    echo "### File listing"
    echo '\`\`\`'
    ls -lhR "$OUTPUT_DIR/" 2>&1 || echo "(empty or missing)"
    echo '\`\`\`'
  } >> "$GITHUB_STEP_SUMMARY"
fi

# ===================== Done =====================
cd "$WORKSPACE"

# Final verification: ensure output dir exists in WORKSPACE
if [[ ! -d "$OUTPUT_DIR" ]]; then
  echo "ERROR: ${OUTPUT_DIR} does not exist after analysis" >&2
  exit 1
fi
FILE_COUNT=$(find "$OUTPUT_DIR" -type f | wc -l)
if [[ "$FILE_COUNT" -eq 0 ]]; then
  echo "ERROR: ${OUTPUT_DIR} exists but contains no files" >&2
  exit 1
fi
echo ""
echo "=== Bloat analysis complete (${FILE_COUNT} file(s) in ${OUTPUT_DIR}) ==="
