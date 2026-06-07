#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (C) 2025 CrazyBoyFeng
#
# bloat.sh - Build easytier-core (lite) with DWARF debug info and run
# bloaty for per-crate size analysis.
#
# This is a standalone analysis tool — it does NOT use the OpenWrt SDK or
# produce any packages.  It builds directly with cargo on the host.
#
# Key differences from the production build:
#   - LTO=off   : preserves DWARF compile-unit -> crate attribution
#   - strip=false: keeps symbol table + debug sections
#   - debug=true : emits DWARF debug info
#
# Analysis uses bloaty (Google's binary size profiler) which reads DWARF
# debug info directly from the ELF binary — no cargo project context needed.
# This completely avoids workspace feature unification issues that plagued
# cargo-bloat (which internally runs cargo build).
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

banner "Installing bloaty"
BLOATY_VERSION="v1.1"
BLOATY_DIR="${WORKSPACE}/.bloaty"
BLOATY_SRC="$BLOATY_DIR/src"
BLOATY_INSTALL_PREFIX="$BLOATY_DIR/prefix"
BLOATY_BIN="$BLOATY_INSTALL_PREFIX/bin/bloaty"
if [[ ! -x "$BLOATY_BIN" ]]; then
  echo "  Building bloaty ${BLOATY_VERSION} from source..."
  rm -rf "$BLOATY_DIR"
  mkdir -p "$BLOATY_SRC" "$BLOATY_INSTALL_PREFIX"
  # Install build dependencies
  sudo apt-get update -qq
  sudo apt-get install -y --no-install-recommends cmake ninja-build
  # Clone bloaty source and build
  git clone https://github.com/google/bloaty.git "$BLOATY_SRC"
  git -C "$BLOATY_SRC" checkout "tags/${BLOATY_VERSION}"
  git -C "$BLOATY_SRC" submodule update --init --recursive
  cmake -B "$BLOATY_SRC/build" -G Ninja -S "$BLOATY_SRC" \
    -DCMAKE_INSTALL_PREFIX="$BLOATY_INSTALL_PREFIX" \
    -DBUILD_TESTING=OFF
  cmake --build "$BLOATY_SRC/build"
  cmake --build "$BLOATY_SRC/build" --target install
  if [[ ! -x "$BLOATY_BIN" ]]; then
    echo "ERROR: bloaty binary not found after build" >&2
    exit 1
  fi
  echo "  bloaty installed: ${BLOATY_BIN}"
else
  echo "  bloaty already installed: ${BLOATY_BIN}"
fi

banner "Setting up Rust toolchain"
if ! command -v rustup &>/dev/null; then
  echo "ERROR: rustup not found. Install it from https://rustup.rs" >&2
  exit 1
fi
rustup default stable

echo "  Rust:    $(rustc --version)"
echo "  Cargo:   $(cargo --version)"
echo "  bloaty:  $($BLOATY_BIN --version 2>/dev/null | head -1 || echo 'unknown')"

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

# Keep Cargo.lock and use --locked, same as the Makefile.
# Without --locked, cargo resolves the latest versions from crates.io,
# which can break and produces non-deterministic results.

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

# Remap paths to keep output deterministic and readable.
# cargo install --path remaps $(pwd) -> =, but the cargo registry
# sources and rustc stdlib are at absolute paths outside $(pwd).
# Remap them all so bloaty output shows clean, portable crate names.
# Order matters: longest/most-specific prefixes first.
export RUSTFLAGS="--remap-path-prefix=$(pwd)/= \
  --remap-path-prefix=${HOME}/.cargo/=.cargo/ \
  --remap-path-prefix=${HOME}/.rustup/=.rustup/ \
  --remap-path-prefix=/rustc/=rustc/"

# Use cargo install --path, identical to the Makefile's Build/Compile.
# cargo install --path treats the crate as standalone (no workspace
# feature unification), unlike cargo build which always discovers
# the workspace root and unifies features across all members.
cargo install --path "$SRC_DIR/easytier" \
  --locked \
  --bin easytier-core \
  --no-default-features \
  --features "$LITE_FEATURES" \
  --root "$SRC_DIR/install" \
  || { echo "ERROR: cargo install failed (exit $?)" >&2; exit 1; }

BINARY="$SRC_DIR/install/bin/easytier-core"
echo ""
if [[ -f "$BINARY" ]]; then
  echo "  Binary: $(ls -lh "$BINARY" | awk '{print $5, $NF}')"
else
  echo "  WARNING: binary not found at ${BINARY}"
  echo "  find in ${CARGO_TARGET_DIR}:"
  find "${CARGO_TARGET_DIR}" -name 'easytier-core' -type f 2>/dev/null || echo "    (not found)"
fi

# ===================== Bloat analysis =====================
mkdir -p "$OUTPUT_DIR"
banner "Running bloaty"

echo "  Analyzing: ${BINARY}"
echo "  Method: bloaty reads DWARF debug info directly from binary"
echo "  (no cargo project context — no workspace feature unification possible)"
echo ""

# bloaty with the compileunits data source reads DWARF .debug_info
# to break down binary size per compile unit.  With CODEGEN_UNITS=1,
# each Rust crate = exactly one compile unit.  bloaty needs no cargo
# project — it parses the ELF binary's embedded DWARF sections directly.
BLOATY_RAW="${OUTPUT_DIR}/bloaty-raw.txt"
BLOATY_REPORT="${OUTPUT_DIR}/bloat-report.txt"

"$BLOATY_BIN" -d compileunits "$BINARY" \
  > "$BLOATY_RAW" 2>&1 \
  || { echo "ERROR: bloaty failed (exit $?)" >&2; exit 1; }

# Post-process: replace DWARF compile unit file paths with clean crate names.
# Also filter out debug section lines ([section .debug_*]) which have
# 0 VM size and are not real code — they are DWARF metadata sections.
#
# After --remap-path-prefix, paths look like:
#   =.cargo/registry/src/<hash>/ring-0.17.0/src/lib.rs
#   =.bloat-src/easytier/src/lib.rs
#   rustc/<hash>/library/std/src/lib.rs
# We extract the crate name (e.g. "ring", "easytier", "std") from these.
python3 -c '
import re, sys

def extract_crate_name(path):
    # Pattern: .../<crate>-<version>/src/...
    # e.g. .../ring-0.17.0/src/lib.rs -> ring
    #       .../serde_json-1.0.0/src/... -> serde_json
    m = re.search(r"/([^/]+-\d[^/]*?)/src/", path)
    if m:
        name_ver = m.group(1)
        parts = re.split(r"-(?=\d)", name_ver, 1)
        return parts[0] if parts else name_ver
    # Pattern: .../<name>/src/...  (no version)
    # e.g. =.cargo/registry/src/<hash>/easytier/src/lib.rs
    #       rustc/<hash>/library/std/src/lib.rs
    m = re.search(r"/([^/]+)/src/", path)
    if m:
        return m.group(1)
    return path

for line in sys.stdin:
    stripped = line.rstrip("\n")
    # Skip debug section lines (DWARF metadata, not code)
    if re.search(r"\[section \.debug_", stripped):
        continue
    # Replace file paths with clean crate names
    m = re.search(r"(\S+/src/\S+)", stripped)
    if m:
        path = m.group(1)
        crate_name = extract_crate_name(path)
        stripped = stripped[:m.start()] + crate_name + stripped[m.end():]
    print(stripped)
' < "$BLOATY_RAW" > "$BLOATY_REPORT"

echo "  bloat-report.txt: $(wc -l < "$BLOATY_REPORT" 2>/dev/null || echo '0') lines"
echo "  First 5 lines:"
head -5 "$BLOATY_REPORT" 2>/dev/null

# ===================== Dependency audit =====================
# Extract all compile unit names from DWARF and check for unexpected deps.
# This catches anything hiding in bloaty's "[N Others]" aggregation.
BLOAT_AUDIT="${OUTPUT_DIR}/dependency-audit.txt"
echo ""
echo "  Running dependency audit..."

# readelf --debug-dump=info lists all DW_TAG_compile_unit entries.
# DW_AT_producer lines contain the crate name, e.g.:
#   "rustc 1.95.0 --crate-name ring ..."
# We extract the crate names and produce a sorted list with counts.
readelf --debug-dump=info "$BINARY" 2>/dev/null \
  | rg 'DW_AT_producer.*rustc.*--crate-name (\S+)' -o --no-line-number \
  | rg -o '(?<=--crate-name )\S+' \
  | sort | uniq -c | sort -rn \
  > "$BLOAT_AUDIT" 2>/dev/null \
  || { echo "  WARNING: readelf audit failed, skipping"; touch "$BLOAT_AUDIT"; }

# Check for dependencies that should NOT be present in the lite build.
# These come from workspace features (quic, websocket, wireguard) that
# are intentionally excluded from the lite variant.
UNWANTED="quinn|rustls|boringtun|rcgen|tokio-rustls|tokio-websockets"
UNWANTED_MATCHES=$(rg -c "$UNWANTED" "$BLOAT_AUDIT" 2>/dev/null || echo "0")
TOTAL_CRATES=$(wc -l < "$BLOAT_AUDIT" 2>/dev/null || echo "0")
echo "  Total compile units: ${TOTAL_CRATES}"
if [[ "$UNWANTED_MATCHES" -gt 0 ]]; then
  echo "  WARNING: found unwanted dependencies in binary!"
  rg "$UNWANTED" "$BLOAT_AUDIT" 2>/dev/null
  rg "$UNWANTED" "$BLOAT_AUDIT" 2>/dev/null >> "$GITHUB_STEP_SUMMARY" 2>/dev/null || true
else
  echo "  No unwanted dependencies (quinn/rustls/boringtun/rcgen) found"
fi
echo "  dependency-audit.txt: ${TOTAL_CRATES} compile units"

# ===================== Copy binary + strip for release size =====================
if [[ -f "$BINARY" ]]; then
  cp "$BINARY" "${OUTPUT_DIR}/easytier-core"
  echo "  Binary copied to ${OUTPUT_DIR}/easytier-core"

  # Strip a copy to show the actual release (non-debug) disk size.
  # strip removes: .symtab, .strtab, .debug_* — all non-load metadata.
  # The remaining LOAD segments (.text, .rodata, .data, .bss) are what
  # ends up in the real release binary.
  STRIPPED="${OUTPUT_DIR}/easytier-core-stripped"
  cp "$BINARY" "$STRIPPED"
  strip "$STRIPPED"
  UNSTRIPPED_SIZE=$(stat --format=%s "$BINARY")
  STRIPPED_SIZE=$(stat --format=%s "$STRIPPED")
  DEBUG_OVERHEAD=$((UNSTRIPPED_SIZE - STRIPPED_SIZE))
  echo ""
  echo "  Release size estimate:"
  echo "    Unstripped: $(numfmt --to=iec $UNSTRIPPED_SIZE) (${UNSTRIPPED_SIZE} bytes)"
  echo "    Stripped:   $(numfmt --to=iec $STRIPPED_SIZE) (${STRIPPED_SIZE} bytes)"
  echo "    Overhead:   $(numfmt --to=iec $DEBUG_OVERHEAD) (debug + symbol tables)"
else
  echo "  WARNING: skipping binary copy, file not found at ${BINARY}"
fi

echo ""
echo "  Contents of ${OUTPUT_DIR}:"
ls -lh "$OUTPUT_DIR/"

# ===================== Write GitHub Step Summary =====================
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo "## Bloat Analysis Results"
    echo ""
    echo "| Build | Size |"
    echo "|-------|------|"
    if [[ -f "$BINARY" ]]; then
      UNSTRIPPED_SIZE=$(stat --format=%s "$BINARY")
      echo "| Unstripped (debug) | $(numfmt --to=iec $UNSTRIPPED_SIZE) |"
    fi
    if [[ -f "${OUTPUT_DIR}/easytier-core-stripped" ]]; then
      STRIPPED_SIZE=$(stat --format=%s "${OUTPUT_DIR}/easytier-core-stripped")
      echo "| **Stripped (release)** | **$(numfmt --to=iec $STRIPPED_SIZE)** |"
    fi
    if [[ -f "$BLOATY_REPORT" ]]; then
      echo "| bloat-report.txt | $(wc -l < "$BLOATY_REPORT") lines |"
    fi
    echo ""
    echo "> **Note**: The bloat report below uses **VM Size** (virtual memory footprint),"
    echo "> which is unaffected by debug info. The File Size column includes debug"
    echo "> symbol overhead; use the Stripped row above for the actual release disk size."
    echo ""
    echo "### Build Configuration"
    echo "- Version: ${VERSION}"
    echo "- Features: ${LITE_FEATURES}"
    echo "- LTO: off (preserves per-crate attribution)"
    echo "- Strip: false (debug build for bloaty analysis)"
    echo "- Opt level: z"
    echo ""
    echo "### Paths"
    echo "- WORKSPACE: ${WORKSPACE}"
    echo "- SRC_DIR: ${SRC_DIR}"
    echo "- CARGO_TARGET_DIR: ${CARGO_TARGET_DIR}"
    echo "- OUTPUT_DIR: ${OUTPUT_DIR}"
    echo "- BINARY: ${BINARY}"
    echo "- BLOATY_BIN: ${BLOATY_BIN}"
    echo ""
    echo "### Bloat Report"
    echo '```'
    cat "$BLOATY_REPORT" 2>/dev/null || echo "(empty)"
    echo '```'
    echo ""
    echo "### Dependency Audit"
    echo "Total compile units: ${TOTAL_CRATES}"
    if [[ "$UNWANTED_MATCHES" -gt 0 ]]; then
      echo "**WARNING: found unwanted dependencies!**"
    else
      echo "No unwanted dependencies (quinn/rustls/boringtun/rcgen) found"
    fi
    echo ""
    echo "<details><summary>Full compile unit list</summary>"
    echo ""
    echo '```'
    cat "$BLOAT_AUDIT" 2>/dev/null || echo "(empty)"
    echo '```'
    echo ""
    echo "</details>"
    echo ""
    echo "### File listing"
    echo '```'
    ls -lhR "$OUTPUT_DIR/" 2>&1 || echo "(empty or missing)"
    echo '```'
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
