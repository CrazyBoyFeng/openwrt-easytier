# SPDX-License-Identifier: Apache-2.0
#
# Copyright (C) 2025 CrazyBoyFeng

include $(TOPDIR)/rules.mk

PKG_NAME:=easytier
PKG_VERSION:=2.6.4
PKG_RELEASE:=2

PKG_SOURCE:=$(PKG_NAME)-$(PKG_VERSION).tar.gz
PKG_SOURCE_URL:=https://codeload.github.com/EasyTier/EasyTier/tar.gz/v$(PKG_VERSION)?
PKG_HASH:=352c0866da709415a837405a6ce4f51b8dfae27e5d5c1da1fb4d8f7338e46795

# codeload tarball top-level dir is EasyTier-x.y.z (uppercase E)
# but PKG_BUILD_DIR uses lowercase easytier-x.y.z (based on PKG_NAME).
# PKG_SOURCE_SUBDIR only affects download cache naming, not the actual
# extraction into PKG_BUILD_DIR, so Build/Prepare must use
# --strip-components=1 to flatten the tarball into PKG_BUILD_DIR.
PKG_SOURCE_SUBDIR:=EasyTier-$(PKG_VERSION)

PKG_MAINTAINER:=CrazyBoyFeng
PKG_LICENSE:=Apache-2.0
PKG_LICENSE_FILES:=LICENSE

PKG_BUILD_DEPENDS:=rust/host protobuf/host
PKG_BUILD_PARALLEL:=1

include $(INCLUDE_DIR)/package.mk
# Lock Cargo dependencies to the versions in Cargo.lock.
# Without --locked, cargo resolves the latest versions from crates.io,
# which can break tier-3 targets (e.g. mipsel).  Specifically,
# fastbloom v0.14.1 introduced AtomicU64 which is unavailable on
# 32-bit MIPS; Cargo.lock pins it to v0.9.0 which works on all archs.
RUST_PKG_LOCKED:=1

include $(TOPDIR)/feeds/packages/lang/rust/rust-package.mk

# ============ Override CARGO_PKG_VARS ============
# CARGO_PKG_VARS (from rust-package.mk) includes CARGO_PKG_CONFIG_VARS
# (from rust-values.mk) which sets cargo profile variables as command-prefix
# variables: LTO=true, OPT_LEVEL=z, PANIC=unwind.  Command-prefix variables
# override exported environment variables with the same name, so those
# values silently override our profile exports below.
#
# Fix: filter out the conflicting profile keys, then append our preferred
# values so that CARGO_PKG_VARS and our exports are consistent.
CARGO_PKG_VARS := $(filter-out \
	CARGO_PROFILE_RELEASE_LTO=% \
	CARGO_PROFILE_RELEASE_OPT_LEVEL=% \
	CARGO_PROFILE_RELEASE_PANIC=%, \
	$(CARGO_PKG_VARS))

CARGO_PKG_VARS += CARGO_PROFILE_RELEASE_LTO=fat
CARGO_PKG_VARS += CARGO_PROFILE_RELEASE_OPT_LEVEL=z
CARGO_PKG_VARS += CARGO_PROFILE_RELEASE_PANIC=abort
CARGO_PKG_VARS += CARGO_PROFILE_RELEASE_STRIP=true

# prost-build needs protoc on the host
CARGO_PKG_VARS += PROTOC=$(STAGING_DIR_HOSTPKG)/bin/protoc
# bindgen (used by kcp-sys) needs cross-compilation toolchain headers.
# -nostdinc prevents clang from searching host /usr/include (glibc
# conflicts with musl cross target).  $(TOOLCHAIN_DIR) is defined in
# rules.mk: staging_dir/toolchain-<arch>_gcc-<ver>_musl.
CARGO_PKG_VARS += BINDGEN_EXTRA_CLANG_ARGS="-nostdinc -I$(TOOLCHAIN_DIR)/include -I$(TOOLCHAIN_DIR)/usr/include"

# ============ easytier-core ============
define Package/easytier-core
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=VPN
  TITLE:=EasyTier P2P Mesh VPN (core daemon)
  URL:=https://github.com/EasyTier/EasyTier
  DEPENDS:=+kmod-tun $(RUST_ARCH_DEPENDS)
  VARIANT:=core
  DEFAULT_VARIANT:=1
endef

define Package/easytier-core/description
  EasyTier is a simple, decentralized and secure mesh VPN
  with WireGuard support. It connects your devices into a
  single virtual LAN, even behind NAT.
  .
  This package contains the easytier-core daemon binary,
  init script and UCI configuration.
endef

# ============ easytier-cli ============
define Package/easytier-cli
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=VPN
  TITLE:=EasyTier CLI management tool
  URL:=https://github.com/EasyTier/EasyTier
  DEPENDS:=+easytier-core $(RUST_ARCH_DEPENDS)
  VARIANT:=cli
endef

define Package/easytier-cli/description
  Command-line management tool for EasyTier.
  Connects to easytier-core via RPC to view status and
  manage the running daemon. Can connect to a remote
  easytier-core instance.
endef

# ============ easytier (meta) ============
define Package/easytier
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=VPN
  TITLE:=EasyTier P2P Mesh VPN (meta package)
  URL:=https://github.com/EasyTier/EasyTier
  DEPENDS:=+easytier-core +easytier-cli
endef

define Package/easytier/description
  EasyTier is a simple, decentralized and secure mesh VPN
  with WireGuard support. It connects your devices into a
  single virtual LAN, even behind NAT.
  .
  This meta package installs both easytier-core and easytier-cli.
endef

# ============ Build/Compile ============
# Cargo profile optimizations for release builds.
# These are exported as environment variables read directly by cargo.
# Since CARGO_PKG_VARS above now contains matching values, command-prefix
# and exports are consistent — no silent override occurs.
export CARGO_PROFILE_RELEASE_LTO=fat
export CARGO_PROFILE_RELEASE_CODEGEN_UNITS=1
export CARGO_PROFILE_RELEASE_PANIC=abort
export CARGO_PROFILE_RELEASE_OPT_LEVEL=z
export CARGO_PROFILE_RELEASE_STRIP=true

# Remap absolute build paths to short relative paths so they don't
# leak into .rodata (panic messages, file!() macros, type names, etc.).
# CURDIR = package directory (Makefile, patches, files/)
# PKG_BUILD_DIR = extracted source directory (Cargo.toml, src/)
# Approximate savings: ~200-300 KB per binary.
export RUSTFLAGS := --remap-path-prefix="$(CURDIR)/=" --remap-path-prefix="$(PKG_BUILD_DIR)/="

# easytier is a workspace member, pass subdirectory path to cargo.
# Each variant builds its respective binary.
# Each Build/Compile is a single line (no backslash continuation)
# so that CI sed can target it via the EASYTIER_COMPILE_* markers.
# EASYTIER_COMPILE_CORE

# EASYTIER_COMPILE_CLI

# Override Build/Prepare to handle case-sensitive directory name
# mismatch.  The codeload tarball top-level directory is EasyTier-x.y.z
# (uppercase E) but PKG_BUILD_DIR uses lowercase easytier-x.y.z
# (based on PKG_NAME).  --strip-components=1 flattens the tarball so
# source files land directly in PKG_BUILD_DIR.
define Build/Prepare
	rm -rf $(PKG_BUILD_DIR)
	mkdir -p $(PKG_BUILD_DIR)
	gzip -dc $(DL_DIR)/$(PKG_SOURCE) | tar -C $(PKG_BUILD_DIR) --strip-components=1 -xf -
	$(Build/Patch/Default)
endef

define Package/easytier-core/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_INSTALL_DIR)/bin/easytier-core $(1)/usr/bin
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/etc/config/easytier $(1)/etc/config/easytier
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/etc/init.d/easytier $(1)/etc/init.d/easytier
endef

define Package/easytier-cli/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_INSTALL_DIR)/bin/easytier-cli $(1)/usr/bin
endef

define Package/easytier/install
	# meta package: no files to install
endef

$(eval $(call RustBinPackage,easytier-core))
$(eval $(call RustBinPackage,easytier-cli))
$(eval $(call BuildPackage,easytier))

# Override Build/Compile: EasyTier is a Cargo workspace,
# so we must point cargo to the workspace member subdirectory.
# BUILD_VARIANT is a target-specific variable set by RustBinPackage.
# For the meta package (no BUILD_VARIANT), Build/Compile is empty.
# EASYTIER_COMPILE_OVERRIDE
Build/Compile=$(if $(BUILD_VARIANT),+$(CARGO_PKG_VARS) cargo install -v \
	--profile $(CARGO_PKG_PROFILE) \
	--root $(PKG_INSTALL_DIR) \
	--path "$(PKG_BUILD_DIR)/easytier" \
	--bin easytier-$(BUILD_VARIANT) \
	$(if $(filter --jobserver%,$(PKG_JOBS)),,-j1) \
	$(CARGO_PKG_ARGS) && \
	$(TARGET_CROSS)strip --remove-section=.eh_frame --remove-section=.eh_frame_hdr \
	$(PKG_INSTALL_DIR)/bin/easytier-$(BUILD_VARIANT),)
# EASYTIER_COMPILE_OVERRIDE_END
