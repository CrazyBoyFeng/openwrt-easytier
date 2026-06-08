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
#   - LTO=fat   : matches release build for realistic code sizes
#   - strip=false: keeps symbol table + debug sections (required by bloaty)
#   - debug=true : emits DWARF debug info (required by bloaty)
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
#   bloat-output/inclusive-size-report.txt — per-crate recursive VM size
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
echo "  LTO: fat (matches release)"
echo "  Strip: false (required by bloaty)"
echo "  Debug: true (required by bloaty)"
echo ""

export CARGO_PROFILE_RELEASE_LTO=fat
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

# ===================== Inclusive size + dependency chain analysis =====================
# Combine bloaty per-crate self sizes with Cargo.lock dependency tree
# to compute inclusive sizes and show dependency chains.
INCLUSIVE_REPORT="${OUTPUT_DIR}/inclusive-size-report.txt"
DEP_CHAINS_REPORT="${OUTPUT_DIR}/dependency-chains.txt"
LOCKFILE="${SRC_DIR}/Cargo.lock"

echo ""
echo "  Computing inclusive sizes and dependency chains..."

if [[ ! -f "$LOCKFILE" ]]; then
  echo "  WARNING: Cargo.lock not found at ${LOCKFILE}, skipping analysis"
  echo "(no Cargo.lock)" > "$INCLUSIVE_REPORT"
  echo "(no Cargo.lock)" > "$DEP_CHAINS_REPORT"
else
  # bloaty format per line: FILE_PCT FILE_SIZE VM_PCT VM_SIZE COMPILE_UNIT_PATH
  # Cargo.lock has [[package]] entries with name + dependencies.
  # We parse both with Python, compute recursive sizes, and output a
  # table sorted by inclusive VM size descending.
  # Write the Python analysis script to a temp file, then execute.
  # This avoids heredoc redirection issues in CI environments.
  PY_SCRIPT=$(mktemp /tmp/bloat-analysis-XXXXXX.py)
  trap "rm -f '$PY_SCRIPT'" EXIT

  cat > "$PY_SCRIPT" << 'PYEOF'
import re, os, sys, io

src_dir = os.environ.get('SRC_DIR', '.')
bloaty_raw = os.environ.get('BLOATY_RAW', '')
lockfile = os.path.join(src_dir, 'Cargo.lock')

try:
    import tomllib
except ImportError:
    import tomli as tomllib

def parse_size(s):
    s = s.strip()
    m = re.match(r'^([\d.]+)(Mi|Ki)$', s)
    if m:
        v, u = float(m.group(1)), m.group(2)
        return v * (1048576 if u == 'Mi' else 1024)
    m = re.match(r'^(\d+)$', s)
    return float(m.group(1)) if m else 0.0

def fmt(b):
    if abs(b) >= 1048576: return f"{b/1048576:.1f}Mi"
    if abs(b) >= 1024: return f"{b/1024:.1f}Ki"
    return f"{b:.0f}B"

def extract_crate_name(path):
    m = re.search(r'([^/]+-\d[^/]*?)/src/', path)
    if m:
        nv = m.group(1)
        parts = re.split(r'-(?=\d)', nv, 1)
        return parts[0] if parts else nv
    m = re.search(r'/([^/]+)/src/', path)
    return m.group(1) if m else path

# Parse Cargo.lock
with open(lockfile, 'rb') as f:
    data = tomllib.load(f)

# Build dependency graph: {crate_name: [direct_dep_names]}
graph = {}
for pkg in data.get('package', []):
    name = pkg['name']
    deps = []
    for d in pkg.get('dependencies', []):
        deps.append(re.split(r'[\s/?]', d)[0])
    graph[name] = deps

# Filter to only crates reachable from 'easytier' (the crate that produces
# easytier-core). Cargo.lock includes all workspace members (easytier-android-jni,
# easytier-ffi, easytier-gui, etc.) which are not part of our binary's dependency
# tree and should not appear in dependency chains.
def reachable_from(root):
    visited = set()
    stack = [root]
    while stack:
        c = stack.pop()
        if c in visited:
            continue
        visited.add(c)
        for dep in graph.get(c, []):
            if dep not in visited:
                stack.append(dep)
    return visited

reachable = reachable_from('easytier')
unreachable = [c for c in graph if c not in reachable]
if unreachable:
    # Remove unreachable crates from the graph
    for c in unreachable:
        del graph[c]
    print(f"  Filtered out {len(unreachable)} crates not reachable from easytier (e.g. {', '.join(sorted(unreachable)[:5])}{'...' if len(unreachable) > 5 else ''})")
print(f"  Dependency graph: {len(graph)} crates reachable from easytier")

# Parse bloaty raw output: {crate_name: vm_size_bytes}
self_sizes = {}
with open(bloaty_raw) as f:
    for line in f:
        line = line.strip()
        if not line or line.startswith('FILE') or line.startswith('VM'):
            continue
        if re.search(r'\[section |TOTAL|Others', line):
            continue
        parts = line.split()
        if len(parts) < 5:
            continue
        vm_bytes = parse_size(parts[3])
        path = parts[4]
        name = extract_crate_name(path)
        self_sizes[name] = self_sizes.get(name, 0) + vm_bytes

# Compute inclusive sizes (DFS with per-root visited set for diamond deps)
inclusive = {}
def dfs(crate, visited):
    if crate in visited:
        return 0.0
    visited.add(crate)
    total = self_sizes.get(crate, 0.0)
    for dep in graph.get(crate, []):
        total += dfs(dep, visited)
    return total

for crate in self_sizes:
    inclusive[crate] = dfs(crate, set())

# Sort by inclusive VM size descending
rows = []
for name, inc in inclusive.items():
    nd = len(graph.get(name, []))
    rows.append((name, inc, nd))
rows.sort(key=lambda x: -x[1])

# --- Output 1: Inclusive Size Report (VM size only) ---
output_dir = os.environ.get('OUTPUT_DIR', '.')
buf1 = io.StringIO()
buf1.write("Inclusive Size Analysis (VM Size)\n")
buf1.write(f"Per-crate self sizes total: {fmt(sum(self_sizes.values()))} ({len(self_sizes)} crates)\n")
buf1.write(f"Dependency graph: {len(graph)} crates from Cargo.lock (reachable from easytier)\n")
buf1.write("\n")
buf1.write(f"{'Crate':<35} {'Inclusive VM Size':>18} {'Direct Deps':>12}\n")
buf1.write('-' * 67)
for name, inc, nd in rows:
    buf1.write(f"\n{name:<35} {fmt(inc):>18} {nd:>12}")
buf1.write('\n')

with open(os.path.join(output_dir, 'inclusive-size-report.txt'), 'w') as f:
    f.write(buf1.getvalue())

# --- Output 2: Reverse Dependency Chains ---
# Show who depends on each bloaty-identified crate (branch/trunk view).
# Build a reverse graph from Cargo.lock and traverse upward.
# All dependents are shown; bloaty-identified ones are annotated with size.
buf2 = io.StringIO()
buf2.write("Reverse Dependency Chains (who depends on each crate)\n")
buf2.write(f"Showing {len(self_sizes)} crates visible to bloaty\n")
buf2.write(f"Reverse dependency graph built from Cargo.lock ({len(graph)} crates)\n")
buf2.write("\n")

# Build reverse graph: {crate: set(crates that depend on it)}
reverse_graph = {}
for crate, deps in graph.items():
    for dep in deps:
        reverse_graph.setdefault(dep, set()).add(crate)

def print_reverse_tree(buf, crate, visited, prefix=""):
    """Print reverse tree: who depends on this crate, going up."""
    visited.add(crate)
    parents = sorted(reverse_graph.get(crate, set()) - visited)
    for i, parent in enumerate(parents):
        is_last = (i == len(parents) - 1)
        connector = "\u2514\u2500\u2500 " if is_last else "\u251c\u2500\u2500 "
        marker = ""
        if parent in self_sizes:
            marker = f" [bloaty: {fmt(self_sizes[parent])}]"
        buf.write(f"{prefix}{connector}{parent}{marker}\n")
        extension = "    " if is_last else "\u2502   "
        print_reverse_tree(buf, parent, visited, prefix + extension)

for name, inc, nd in rows:
    total_parents = len(reverse_graph.get(name, set()))
    buf2.write(f"{name}  [self: {fmt(self_sizes[name])}, inclusive: {fmt(inc)}, "
               f"used by {total_parents} crates]\n")
    print_reverse_tree(buf2, name, set())
    buf2.write("\n")

with open(os.path.join(output_dir, 'dependency-chains.txt'), 'w') as f:
    f.write(buf2.getvalue())

print("  Analysis complete.")
PYEOF

  SRC_DIR="$SRC_DIR" BLOATY_RAW="$BLOATY_RAW" OUTPUT_DIR="$OUTPUT_DIR" \
    python3 "$PY_SCRIPT"

  echo "  inclusive-size-report.txt: $(wc -l < "$INCLUSIVE_REPORT" 2>/dev/null || echo '0') lines"
  echo "  dependency-chains.txt:    $(wc -l < "$DEP_CHAINS_REPORT" 2>/dev/null || echo '0') lines"
  echo "  First 5 lines (inclusive):"
  head -5 "$INCLUSIVE_REPORT" 2>/dev/null
  echo "  First 10 lines (dep chains):"
  head -10 "$DEP_CHAINS_REPORT" 2>/dev/null
fi

# ===================== Copy binary =====================
if [[ -f "$BINARY" ]]; then
  cp "$BINARY" "${OUTPUT_DIR}/easytier-core"
  echo "  Binary copied to ${OUTPUT_DIR}/easytier-core"
  echo "  Binary size: $(ls -lh "$BINARY" | awk '{print $5}')"
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
    echo "| File | Size |"
    echo "|------|------|"
    if [[ -f "$BINARY" ]]; then
      echo "| easytier-core | $(ls -lh "$BINARY" | awk '{print $5}') |"
    fi
    if [[ -f "$BLOATY_REPORT" ]]; then
      echo "| bloat-report.txt | $(wc -l < "$BLOATY_REPORT") lines |"
    fi
    echo ""
    echo "> **Note**: VM Size reflects actual memory footprint per crate and is"
    echo "> unaffected by debug info. File Size includes debug symbol overhead."
    echo ""
    echo "### Build Configuration"
    echo "- Version: ${VERSION}"
    echo "- Features: ${LITE_FEATURES}"
    echo "- LTO: fat (matches release build)"
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
    echo "### Inclusive Size Analysis"
    echo '```'
    cat "$INCLUSIVE_REPORT" 2>/dev/null || echo "(empty)"
    echo '```'
    echo ""
    echo "### Reverse Dependency Chains"
    echo '```'
    cat "$DEP_CHAINS_REPORT" 2>/dev/null || echo "(empty)"
    echo '```'
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
