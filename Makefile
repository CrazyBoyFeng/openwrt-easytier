# SPDX-License-Identifier: Apache-2.0
#
# Copyright (C) 2025 CrazyBoyFeng

include $(TOPDIR)/rules.mk

PKG_NAME:=easytier
PKG_VERSION:=2.6.4
PKG_RELEASE:=1

PKG_SOURCE:=$(PKG_NAME)-$(PKG_VERSION).tar.gz
PKG_SOURCE_URL:=https://codeload.github.com/EasyTier/EasyTier/tar.gz/v$(PKG_VERSION)?
PKG_HASH:=352c0866da709415a837405a6ce4f51b8dfae27e5d5c1da1fb4d8f7338e46795

# codeload tarball top-level dir is EasyTier-x.y.z (uppercase)
# SDK 25.12.4 honors PKG_SOURCE_SUBDIR natively.
# NOTE (legacy, for 23.05.6): PKG_SOURCE_SUBDIR is not honored by SDK
# 23.05 build variants, so Build/Prepare had to use --strip-components=1.
# Retained for reference; can be removed once 23.05.6 support is dropped.
PKG_SOURCE_SUBDIR:=EasyTier-$(PKG_VERSION)

PKG_MAINTAINER:=CrazyBoyFeng
PKG_LICENSE:=Apache-2.0
PKG_LICENSE_FILES:=LICENSE

PKG_BUILD_DEPENDS:=rust/host protobuf/host
PKG_BUILD_PARALLEL:=1

include $(INCLUDE_DIR)/package.mk
# rust-package.mk uses RUST_PKG_LOCKED ?= 1 at include time to set
# CARGO_PKG_ARGS.  Must override BEFORE the include so CARGO_PKG_ARGS
# is empty (no --locked) instead of --locked.
RUST_PKG_LOCKED:=0

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
CARGO_PKG_VARS += CARGO_PROFILE_RELEASE_OPT_LEVEL=3
CARGO_PKG_VARS += CARGO_PROFILE_RELEASE_PANIC=abort
CARGO_PKG_VARS += CARGO_PROFILE_RELEASE_STRIP=true

# prost-build needs protoc on the host
CARGO_PKG_VARS += PROTOC=$(STAGING_DIR_HOSTPKG)/bin/protoc
# bindgen (used by kcp-sys) needs cross-compilation toolchain headers.
# -nostdinc prevents clang from searching host /usr/include (glibc
# conflicts with musl cross target).  $(TOOLCHAIN_DIR) is defined in
# rules.mk: staging_dir/toolchain-<arch>_gcc-<ver>_musl.
CARGO_PKG_VARS += BINDGEN_EXTRA_CLANG_ARGS="-nostdinc -I$(TOOLCHAIN_DIR)/include -I$(TOOLCHAIN_DIR)/usr/include"

# ============ Tier-3 target support (-Z build-std) ============
# NOTE (legacy, for 23.05.6 SDK standalone build): When CARGO_BUILD_STD_FLAGS
# is set in the environment (e.g. by CI for mipsel), redefine Build/Compile/Cargo
# to inject the flag between "cargo" and "install".  In the current CI, 25.12.4
# always compiles first and mipsel uses build-std; this ifdef is handled via
# CI sed override in build.yml.  Retained for reference; can be removed once
# 23.05.6 support is dropped.
# ifdef CARGO_BUILD_STD_FLAGS
# define Build/Compile/Cargo
#       +$(CARGO_PKG_VARS) \
#       cargo $(CARGO_BUILD_STD_FLAGS) install -v \
#               --profile $(CARGO_PKG_PROFILE) \
#               $(if $(strip $(RUST_PKG_FEATURES)),--features "$(strip $(RUST_PKG_FEATURES))") \
#               --root $(PKG_INSTALL_DIR) \
#               --path "$(PKG_BUILD_DIR)/$(if $(strip $(1)),$(strip $(1)))" \
#               $(if $(filter --jobserver%,$(PKG_JOBS)),,-j1) \
#               $(2)
# endef
# endif

# ============ common ============
define Package/easytier/Default
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=VPN
  TITLE:=EasyTier P2P Mesh VPN
  URL:=https://github.com/EasyTier/EasyTier
  DEPENDS:=+kmod-tun $(RUST_ARCH_DEPENDS)
endef

define Package/easytier/Default/description
  EasyTier is a simple, decentralized and secure mesh VPN
  with WireGuard support. It connects your devices into a
  single virtual LAN, even behind NAT.
endef

# ============ easytier-lite ============
define Package/easytier-lite
  $(call Package/easytier/Default)
  TITLE+= (lite build)
  VARIANT:=lite
  PROVIDES:=easytier
endef

define Package/easytier-lite/description
  $(call Package/easytier/Default/description)
  .
  This lite build removes wireguard, socks5 and smoltcp features.
  Suitable for routers with limited flash storage.
endef

# ============ easytier (full) ============
define Package/easytier
  $(call Package/easytier/Default)
  TITLE+= (full build)
  VARIANT:=full
  DEFAULT_VARIANT:=1
  CONFLICTS:=easytier-lite
endef

define Package/easytier/description
  $(call Package/easytier/Default/description)
  .
  This full build includes all features: wireguard, socks5, smoltcp.
endef

# ============ Build/Compile ============
ifeq ($(BUILD_VARIANT),lite)
  RUST_PKG_FEATURES:=tun,magic-dns,quic,kcp,websocket,faketcp,zstd,aes-gcm
endif

# Cargo profile optimizations for release builds.
# These are exported as environment variables read directly by cargo.
# Since CARGO_PKG_VARS above now contains matching values, command-prefix
# and exports are consistent — no silent override occurs.
export CARGO_PROFILE_RELEASE_LTO=fat
export CARGO_PROFILE_RELEASE_CODEGEN_UNITS=1
export CARGO_PROFILE_RELEASE_PANIC=abort
export CARGO_PROFILE_RELEASE_OPT_LEVEL=3
export CARGO_PROFILE_RELEASE_STRIP=true

# easytier is a workspace member, pass subdirectory path to cargo.
# Only build easytier-core (skip easytier-cli which is not packaged).
ifeq ($(BUILD_VARIANT),lite)
Build/Compile=$(call Build/Compile/Cargo,easytier,--bin easytier-core --no-default-features) && (command -v upx >/dev/null 2>&1 && upx --lzma --best $(PKG_INSTALL_DIR)/bin/easytier-core || true)
else
Build/Compile=$(call Build/Compile/Cargo,easytier,--bin easytier-core) && (command -v upx >/dev/null 2>&1 && upx --lzma --best $(PKG_INSTALL_DIR)/bin/easytier-core || true)
endif

# NOTE (legacy, for 23.05.6): Override prepare to handle case-sensitive
# directory name mismatch.  The codeload tarball top-level directory is
# EasyTier-x.y.z (uppercase E) but PKG_BUILD_DIR uses lowercase
# easytier-x.y.z (based on PKG_NAME).  SDK 25.12.4 honors PKG_SOURCE_SUBDIR
# so this workaround is unnecessary.  Retained for reference; can be
# removed once 23.05.6 support is dropped.
# define Build/Prepare
#       rm -rf $(PKG_BUILD_DIR)
#       mkdir -p $(PKG_BUILD_DIR)
#       gzip -dc $(DL_DIR)/$(PKG_SOURCE) | tar -C $(PKG_BUILD_DIR) --strip-components=1 -xf -
#       $(Build/Patch/Default)
# endef

# Define install for easytier (full).  easytier-lite shares the same
# install via a variable alias (jq-style).  RustBinPackage uses ifndef, so
# defining install here prevents it from generating a duplicate default rule.
define Package/easytier/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_INSTALL_DIR)/bin/easytier-core $(1)/usr/bin
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/etc/config/easytier $(1)/etc/config/easytier
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/etc/init.d/easytier $(1)/etc/init.d/easytier
endef

Package/easytier-lite/install = $(Package/easytier/install)

$(eval $(call RustBinPackage,easytier-lite))
$(eval $(call RustBinPackage,easytier))

$(eval $(call BuildPackage,easytier-lite))
$(eval $(call BuildPackage,easytier))
