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

# ===================== Generate dependency tree (early) =====================
# Cargo tree is needed before post-processing bloaty output so we can
# build a C-library-prefix -> -sys-crate mapping for paths like
#   zstd/lib/compress/zstd_lazy.c  ->  zstd-sys
# where the C compiler records only a relative path in DWARF.
CARGO_TREE="${OUTPUT_DIR}/cargo-tree.txt"
echo ""
echo "  Generating dependency tree (cargo tree -p easytier, lite features)..."
if cargo tree -p easytier \
    --manifest-path "${SRC_DIR}/Cargo.toml" \
    --no-default-features --features "$LITE_FEATURES" \
    --charset utf8 \
    > "$CARGO_TREE" 2>&1; then
  echo "  cargo-tree.txt: $(wc -l < "$CARGO_TREE") lines"
else
  echo "  WARNING: cargo tree failed (exit $?), dependency chains will be skipped"
  echo "  cargo tree error output:"
  cat "$CARGO_TREE"
  rm -f "$CARGO_TREE"
fi

# Generate cargo metadata for feature-to-dependency mapping.
# cargo tree --edges features shows the dependency's features, not the
# parent's features.  cargo metadata packages[].features gives us the
# correct (parent, dep) -> parent_feature mapping via dep:crate specs.
# e.g. easytier's "kcp" feature = ["dep:kcp-sys"] means easytier's
# "kcp" feature gates kcp-sys.
# Note: cargo metadata does not support --no-default-features/--features.
# It resolves the full workspace, but we only use packages[].features
# (the feature definitions from Cargo.toml) which is unaffected.
CARGO_METADATA="${OUTPUT_DIR}/cargo-metadata.json"
if [[ -f "$CARGO_TREE" ]]; then
  echo "  Generating cargo metadata for feature mapping..."
  if cargo metadata --format-version 1 \
      --manifest-path "${SRC_DIR}/Cargo.toml" \
      > "$CARGO_METADATA" 2>/dev/null; then
    echo "  cargo-metadata.json: $(wc -c < "$CARGO_METADATA") bytes"
  else
    echo "  WARNING: cargo metadata failed, feature annotations will be skipped"
    rm -f "$CARGO_METADATA"
  fi
fi

# Build C-library-prefix -> -sys-crate mapping from cargo tree.
# e.g. zstd -> zstd-sys,  kcp -> kcp-sys
# This handles C source paths recorded by cc/gcc in DWARF as relative
# paths (e.g. zstd/lib/compress/zstd_lazy.c) without registry prefix.
C_PREFIX_MAP=""
if [[ -f "$CARGO_TREE" ]]; then
  C_PREFIX_MAP=$(python3 -c '
import re, sys
crates = set()
with open(sys.argv[1]) as f:
    for line in f:
        m = re.match(r"\s*(?:[\u251c\u2514\u2502\u2500 ]+)?(\S+)", line)
        if m:
            crates.add(m.group(1))
mapping = {}
for c in crates:
    idx = c.find("-sys")
    if idx > 0:
        prefix = c[:idx]
        mapping[prefix] = c
import json
print(json.dumps(mapping))
' "$CARGO_TREE")
fi

# Post-process: replace DWARF compile unit file paths with clean crate names.
# Also filter out debug section lines ([section .debug_*]) which have
# 0 VM size and are not real code — they are DWARF metadata sections.
#
# After --remap-path-prefix, paths look like:
#   =.cargo/registry/src/<hash>/ring-0.17.0/src/lib.rs
#   =.bloat-src/easytier/src/lib.rs
#   =.cargo/registry/src/<hash>/zstd-sys-2.0.13+zstd.1.5.6/zstd/lib/compress/zstd_lazy.c
#   easytier/src/easytier-core.rs/@/easytier_core.95fd1469c661508c-cgu.0
#   rustc/<hash>/library/std/src/lib.rs
#   zstd/lib/compress/zstd_lazy.c  (C source, relative path from cc crate)
# We extract the crate name (e.g. "ring", "easytier", "zstd-sys") from these.
python3 -c '
import re, sys, json

# Load C library prefix -> -sys crate name mapping from cargo tree
c_prefix_map = {}
try:
    c_prefix_map = json.loads(sys.argv[1]) if sys.argv[1] else {}
except (json.JSONDecodeError, IndexError):
    pass

def extract_crate_name(path):
    # Pattern 1: .../<crate>-<version>/src/... (Rust registry crate)
    # e.g. .../ring-0.17.0/src/lib.rs -> ring
    #       .../serde_json-1.0.0/src/... -> serde_json
    m = re.search(r"/([^/]+-\d[^/]*?)/src/", path)
    if m:
        name_ver = m.group(1)
        parts = re.split(r"-(?=\d)", name_ver, 1)
        return parts[0] if parts else name_ver
    # Pattern 2: .../<name>/src/... (git dep, rustc std, workspace member)
    # e.g. .cargo/git/checkouts/kcp-sys-xxx/9496479/src/lib.rs -> kcp-sys
    #       rustc/<hash>/library/std/src/lib.rs -> std
    m = re.search(r"/([^/]+)/src/", path)
    if m:
        candidate = m.group(1)
        # Skip git checkout revision hash (pure hex, 7-40 chars)
        # and extract crate name from the checkouts directory instead
        if re.match(r"^[0-9a-f]{7,40}$", candidate):
            m2 = re.search(r"/checkouts/([a-z][a-z0-9_-]*?)-[0-9a-f]{6,}/", path)
            if m2:
                return m2.group(1)
        else:
            return candidate
    # Pattern 3: Rust LTO symbol remapping @/ separator
    # e.g. easytier/src/easytier-core.rs/@/easytier_core.95fd1469c661508c-cgu.0 -> easytier_core
    m = re.search(r"/@/([^.]+)", path)
    if m:
        return m.group(1)
    # Pattern 4: C/C++ source in -sys crate directory (has crate-version in path)
    # e.g. .../zstd-sys-2.0.13+zstd.1.5.6/zstd/lib/compress/zstd_lazy.c -> zstd-sys
    #       .../libz-sys-1.1.20/libz/... -> libz-sys
    for seg in path.split("/"):
        if re.match(r"^[a-z][a-z0-9_]+-\d", seg):
            parts = re.split(r"-(?=\d)", seg, 1)
            return parts[0] if parts else seg
    # Pattern 5: C source with relative path (no registry prefix)
    # e.g. zstd/lib/compress/zstd_lazy.c -> zstd-sys
    #       kcp/src/... -> kcp-sys
    # The C compiler (via cc crate) records relative paths in DWARF.
    # Match first path segment against the C prefix map from cargo tree.
    first_seg = path.split("/")[0] if path else ""
    if first_seg in c_prefix_map:
        return c_prefix_map[first_seg]
    # Fallback: strip -cgu.N and .hash suffix from last path segment
    # e.g. easytier_core.95fd1469c661508c-cgu.0 -> easytier_core
    last = path.rstrip("/").rsplit("/", 1)[-1]
    last = re.sub(r"-cgu\.\d+$", "", last)
    last = re.sub(r"\.[0-9a-f]{16,}$", "", last)
    if last:
        return last
    return path

for line in sys.stdin:
    stripped = line.rstrip("\n")
    # Skip debug section lines (DWARF metadata, not code)
    if re.search(r"\[section \.debug_", stripped):
        continue
    # Replace file paths with clean crate names
    # Match paths ending with .ext (covers /src/ paths and C source paths)
    m = re.search(r"(\S+\.\w+)$", stripped)
    if m:
        path = m.group(1)
        crate_name = extract_crate_name(path)
        if crate_name != path:
            stripped = stripped[:m.start()] + crate_name + stripped[m.end():]
    print(stripped)
' "$C_PREFIX_MAP" < "$BLOATY_RAW" > "$BLOATY_REPORT"

echo "  bloat-report.txt: $(wc -l < "$BLOATY_REPORT" 2>/dev/null || echo '0') lines"
echo "  First 5 lines:"
head -5 "$BLOATY_REPORT" 2>/dev/null

# ===================== Inclusive size + dependency chain analysis =====================
# Cargo tree was already generated above (needed for C prefix mapping).
# Use it here to compute inclusive sizes and reverse dependency chains.
INCLUSIVE_REPORT="${OUTPUT_DIR}/inclusive-size-report.txt"
DEP_CHAINS_REPORT="${OUTPUT_DIR}/dependency-chains.txt"

echo ""
echo "  Computing inclusive sizes and dependency chains..."

if [[ ! -f "$CARGO_TREE" ]]; then
  echo "  WARNING: cargo tree not available, skipping analysis"
  echo "(no cargo tree)" > "$INCLUSIVE_REPORT"
  echo "(no cargo tree)" > "$DEP_CHAINS_REPORT"
else
  # bloaty format per line: FILE_PCT FILE_SIZE VM_PCT VM_SIZE COMPILE_UNIT_PATH
  # cargo tree output is a tree of package names scoped to easytier's
  # dependency graph with the exact lite features.  We parse both with
  # Python, compute recursive sizes, and output a table sorted by
  # inclusive VM size descending.
  # Write the Python analysis script to a temp file, then execute.
  # This avoids heredoc redirection issues in CI environments.
  PY_SCRIPT=$(mktemp /tmp/bloat-analysis-XXXXXX.py)
  trap "rm -f '$PY_SCRIPT'" EXIT

  cat > "$PY_SCRIPT" << 'PYEOF'
import re, os, sys, io

src_dir = os.environ.get('SRC_DIR', '.')
bloaty_raw = os.environ.get('BLOATY_RAW', '')
cargo_tree_file = os.environ.get('CARGO_TREE', '')

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
    # Pattern 1: .../<crate>-<version>/src/...
    m = re.search(r'([^/]+-\d[^/]*?)/src/', path)
    if m:
        nv = m.group(1)
        parts = re.split(r'-(?=\d)', nv, 1)
        return parts[0] if parts else nv
    # Pattern 2: .../<name>/src/...
    m = re.search(r'/([^/]+)/src/', path)
    if m:
        candidate = m.group(1)
        # Skip git checkout revision hash (pure hex, 7-40 chars)
        if re.match(r'^[0-9a-f]{7,40}$', candidate):
            m2 = re.search(r'/checkouts/([a-z][a-z0-9_-]*?)-[0-9a-f]{6,}/', path)
            if m2:
                return m2.group(1)
        else:
            return candidate
    # Pattern 3: Rust LTO @/ symbol remapping
    m = re.search(r'/@/([^.]+)', path)
    if m:
        return m.group(1)
    # Pattern 4: C/C++ source in -sys crate directory (has crate-version in path)
    for seg in path.split('/'):
        if re.match(r'^[a-z][a-z0-9_]+-\d', seg):
            parts = re.split(r'-(?=\d)', seg, 1)
            return parts[0] if parts else seg
    # Pattern 5: C source with relative path (no registry prefix)
    # e.g. zstd/lib/compress/zstd_lazy.c -> zstd-sys
    # The C compiler (via cc crate) records relative paths in DWARF.
    # Match first path segment against the C prefix map from cargo tree.
    first_seg = path.split('/')[0] if path else ''
    if first_seg in c_prefix_map:
        return c_prefix_map[first_seg]
    # Fallback: strip -cgu.N and .hash suffix
    last = path.rstrip('/').rsplit('/', 1)[-1]
    last = re.sub(r'-cgu\.\d+$', '', last)
    last = re.sub(r'\.[0-9a-f]{16,}$', '', last)
    return last if last else path

# Build dependency graph from cargo tree output
# cargo tree output format (UTF-8):
#   easytier v0.1.0 (path+...)
#   ├── dep_a v1.0.0
#   │   ├── dep_c v1.0.0
#   │   └── dep_d v1.0.0
#   └── dep_b v1.0.0
# Parse by counting │ characters for depth, finding ├/└ as connector.
# This is feature-aware and scoped to easytier — no other workspace members.
graph = {}
with open(cargo_tree_file) as f:
    lines = f.read().strip().split('\n')

stack = []  # [(depth, crate_name)]
for line in lines:
    line = line.rstrip()
    if not line:
        continue
    # Find tree connector (├ or └)
    idx = -1
    for i, ch in enumerate(line):
        if ch in ('\u251c', '\u2514'):
            idx = i
            break
    if idx == -1:
        # Root line (no tree connector) — must look like a crate name
        # e.g. "easytier v2.6.4 (path+...)"
        # Skip cargo download/status messages that lack tree connectors
        m = re.match(r'([a-zA-Z][\w-]*)\s+v', line)
        if not m:
            continue
        name = m.group(1)
        graph[name] = []
        stack = [(0, name)]
        continue
    # Depth = number of │ characters before the connector + 1
    depth = line[:idx].count('\u2502') + 1
    rest = line[idx + 3:]
    m = re.match(r'\s*(\S+)', rest)
    if not m:
        continue
    name = m.group(1)
    # Skip metadata lines like [build-dependencies]
    if name.startswith('['):
        continue
    while len(stack) > 1 and stack[-1][0] >= depth:
        stack.pop()
    parent = stack[-1][1]
    graph.setdefault(parent, []).append(name)
    graph.setdefault(name, [])
    stack.append((depth, name))

print(f"  Dependency graph: {len(graph)} crates (from cargo tree, easytier with lite features)")

# Build C library prefix -> -sys crate name mapping
# e.g. zstd -> zstd-sys,  kcp -> kcp-sys
# Used by Pattern 5 in extract_crate_name for C source relative paths.
c_prefix_map = {}
for c in graph:
    idx = c.find('-sys')
    if idx > 0:
        prefix = c[:idx]
        c_prefix_map[prefix] = c
print(f"  C prefix map: {c_prefix_map}")

# Parse cargo metadata to build (parent_crate, dep_crate) -> parent_feature mapping.
# cargo tree --edges features shows the dependency's own features (wrong).
# cargo metadata packages[].features has "dep:crate_name" specs that tell us
# which feature of the parent gates each dependency.
# e.g. easytier features: {"kcp": ["dep:kcp-sys"]} means easytier's
# "kcp" feature gates kcp-sys -> feature_map[("easytier", "kcp-sys")] = {"kcp"}
import json
feature_map = {}
cargo_metadata_file = os.environ.get('CARGO_METADATA', '')
if cargo_metadata_file and os.path.exists(cargo_metadata_file):
    with open(cargo_metadata_file) as f:
        raw = f.read().strip()
    meta = json.loads(raw)
    for pkg in meta.get('packages', []):
        pkg_name = pkg['name']
        for feat_name, feat_values in pkg.get('features', {}).items():
            for value in feat_values:
                # dep:crate_name means this feature gates the crate as optional dep
                if value.startswith('dep:'):
                    dep_name = value[4:]
                    feature_map.setdefault((pkg_name, dep_name), set()).add(feat_name)
    print(f"  Feature map: {len(feature_map)} feature edges from cargo metadata")
else:
    print(f"  No cargo metadata, feature annotations disabled")

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
# Compute all deps count (recursive) for each crate
def count_all_deps(crate, visited):
    visited.add(crate)
    total = 0
    for dep in graph.get(crate, []):
        if dep not in visited:
            total += 1 + count_all_deps(dep, visited)
    return total

for name, inc in inclusive.items():
    na = count_all_deps(name, set())
    rows.append((name, inc, na))
rows.sort(key=lambda x: -x[1])

# --- Output 1: Inclusive Size Report (VM size only) ---
output_dir = os.environ.get('OUTPUT_DIR', '.')
buf1 = io.StringIO()
buf1.write(f"{'Inclusive VM Size':>18} {'All Deps':>12} {'Crate':<35}\n")
buf1.write('-' * 67)
for name, inc, nd in rows:
    buf1.write(f"\n{fmt(inc):>18} {nd:>12} {name:<35}")
buf1.write(f"\n{fmt(sum(self_sizes.values())):>18} {len(graph):>12} {'total':<35}\n")

with open(os.path.join(output_dir, 'inclusive-size-report.txt'), 'w') as f:
    f.write(buf1.getvalue())

# --- Output 2: Reverse Dependency Chains ---
buf2 = io.StringIO()
buf2.write("Reverse Dependency Chains (who depends on each crate)\n")
buf2.write(f"Showing {len(self_sizes)} crates visible to bloaty\n")
buf2.write(f"Reverse dependency graph from cargo tree ({len(graph)} crates)\n")
buf2.write("\n")

reverse_graph = {}
for crate, deps in graph.items():
    for dep in deps:
        reverse_graph.setdefault(dep, set()).add(crate)

def print_reverse_tree(buf, crate, visited, prefix=""):
    visited.add(crate)
    parents = sorted(reverse_graph.get(crate, set()) - visited)
    for i, parent in enumerate(parents):
        is_last = (i == len(parents) - 1)
        connector = "\u2514\u2500\u2500 " if is_last else "\u251c\u2500\u2500 "
        marker = ""
        if parent in self_sizes:
            marker = f" [bloaty: {fmt(self_sizes[parent])}]"
        # Annotate with feature(s) that caused this dependency
        features = feature_map.get((parent, crate))
        if features:
            feature_str = ",".join(sorted(features))
            buf.write(f"{prefix}{connector}{parent}[{feature_str}]{marker}\n")
        else:
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
    CARGO_TREE="${CARGO_TREE:-}" \
    CARGO_METADATA="${CARGO_METADATA:-}" \
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
