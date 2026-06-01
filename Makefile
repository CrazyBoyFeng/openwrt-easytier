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
# NOTE: PKG_SOURCE_SUBDIR is not honored by SDK 23.05 build variants,
# so Build/Prepare is overridden to use --strip-components=1.
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

# ============ Build environment for cargo ============
# Cross-compilation environment variables for cargo build.
# Derived from rust-values.mk (included via rust-package.mk) which
# provides: RUSTC_TARGET_ARCH, CARGO_HOME, CARGO_RUSTFLAGS,
# RUSTC_LDFLAGS, TARGET_CC_NOCACHE, HOSTCC_NOCACHE, PKG_JOBS.
#
# Intentionally NOT using $(CARGO_PKG_VARS) as command prefix.
# CARGO_PKG_VARS includes CARGO_PKG_CONFIG_VARS from rust-values.mk
# which sets cargo profile variables (LTO=true, OPT_LEVEL=z,
# PANIC=unwind).  Command-prefix variables override exported
# environment variables, so those values would silently override our
# profile exports below.  By building our own var list we keep only
# the cross-compilation settings and let our profile exports take effect.
CARGO_BUILD_ENV := \
	CARGO_BUILD_TARGET=$(RUSTC_TARGET_ARCH) \
	CARGO_TARGET_$(subst -,_,$(call toupper,$(RUSTC_TARGET_ARCH)))_LINKER=$(TARGET_CC_NOCACHE) \
	CARGO_HOME=$(CARGO_HOME) \
	RUSTFLAGS="-Ctarget-feature=-crt-static $(RUSTC_LDFLAGS)" \
	TARGET_CC=$(TARGET_CC_NOCACHE) \
	TARGET_CFLAGS="$(TARGET_CFLAGS)" \
	CC=$(HOSTCC_NOCACHE) \
	MAKEFLAGS="$(PKG_JOBS)"

# prost-build needs protoc on the host
CARGO_BUILD_ENV += PROTOC=$(STAGING_DIR_HOSTPKG)/bin/protoc
# bindgen (used by kcp-sys) needs cross-compilation toolchain headers.
# -nostdinc prevents clang from searching host /usr/include (glibc
# conflicts with musl cross target).  $(TOOLCHAIN_DIR) is defined in
# rules.mk: staging_dir/toolchain-<arch>_gcc-<ver>_musl.
CARGO_BUILD_ENV += BINDGEN_EXTRA_CLANG_ARGS="-nostdinc -I$(TOOLCHAIN_DIR)/include -I$(TOOLCHAIN_DIR)/usr/include"

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
# Since Build/Compile uses CARGO_BUILD_ENV (not CARGO_PKG_VARS) as
# command prefix, these exports are NOT overridden by conflicting
# profile settings from rust-values.mk's CARGO_PKG_CONFIG_VARS.
export CARGO_PROFILE_RELEASE_LTO=fat
export CARGO_PROFILE_RELEASE_CODEGEN_UNITS=1
export CARGO_PROFILE_RELEASE_PANIC=abort
export CARGO_PROFILE_RELEASE_OPT_LEVEL=3
export CARGO_PROFILE_RELEASE_STRIP=true

# CARGO_BUILD_STD_FLAGS: override from environment (e.g. CI sets
# "-Z build-std" for tier-3 targets like mipsel where no prebuilt
# std exists).  Empty by default for targets with prebuilt std.
CARGO_BUILD_STD_FLAGS ?=

# easytier is a workspace member, pass subdirectory path to cargo.
# Only build easytier-core (skip easytier-cli which is not packaged).
# Uses cargo build (not cargo install) to avoid requiring rust/host.
# Build/Compile/Cargo from rust-package.mk uses cargo install which
# needs rust/host (~14 GB, ~1 h); cargo build only needs cargo in PATH.
#
# --target-dir separates build artifacts per variant (target-full/ or
# target-lite/) to avoid feature flag conflicts between variants.
#
# UPX compresses the binary (~60-70% size reduction).
ifeq ($(BUILD_VARIANT),lite)
Build/Compile=$(CARGO_BUILD_ENV) cargo $(CARGO_BUILD_STD_FLAGS) build -v --manifest-path $(PKG_BUILD_DIR)/easytier/Cargo.toml -p easytier --bin easytier-core --no-default-features --features "$(strip $(RUST_PKG_FEATURES))" --profile $(CARGO_PKG_PROFILE) --target-dir $(PKG_BUILD_DIR)/target-$(or $(BUILD_VARIANT),full) && (command -v upx >/dev/null 2>&1 && upx --lzma --best $(PKG_BUILD_DIR)/target-$(or $(BUILD_VARIANT),full)/$(RUSTC_TARGET_ARCH)/$(CARGO_PKG_PROFILE)/easytier-core || true) && mkdir -p $(PKG_INSTALL_DIR)/bin && cp $(PKG_BUILD_DIR)/target-$(or $(BUILD_VARIANT),full)/$(RUSTC_TARGET_ARCH)/$(CARGO_PKG_PROFILE)/easytier-core $(PKG_INSTALL_DIR)/bin/
else
Build/Compile=$(CARGO_BUILD_ENV) cargo $(CARGO_BUILD_STD_FLAGS) build -v --manifest-path $(PKG_BUILD_DIR)/easytier/Cargo.toml -p easytier --bin easytier-core --profile $(CARGO_PKG_PROFILE) --target-dir $(PKG_BUILD_DIR)/target-$(or $(BUILD_VARIANT),full) && (command -v upx >/dev/null 2>&1 && upx --lzma --best $(PKG_BUILD_DIR)/target-$(or $(BUILD_VARIANT),full)/$(RUSTC_TARGET_ARCH)/$(CARGO_PKG_PROFILE)/easytier-core || true) && mkdir -p $(PKG_INSTALL_DIR)/bin && cp $(PKG_BUILD_DIR)/target-$(or $(BUILD_VARIANT),full)/$(RUSTC_TARGET_ARCH)/$(CARGO_PKG_PROFILE)/easytier-core $(PKG_INSTALL_DIR)/bin/
endif

# Override prepare to handle case-sensitive directory name mismatch.
# The codeload tarball top-level directory is EasyTier-x.y.z (uppercase E)
# but PKG_BUILD_DIR uses lowercase easytier-x.y.z (based on PKG_NAME).
# SDK 24.10+ honors PKG_SOURCE_SUBDIR, but SDK 23.05 build variants don't.
# Use --strip-components=1 to strip the uppercase prefix and extract
# directly into PKG_BUILD_DIR, so patches can find files.
define Build/Prepare
	rm -rf $(PKG_BUILD_DIR)
	mkdir -p $(PKG_BUILD_DIR)
	gzip -dc $(DL_DIR)/$(PKG_SOURCE) | tar -C $(PKG_BUILD_DIR) --strip-components=1 -xf -
	$(Build/Patch/Default)
endef

# Define install for easytier (full).  easytier-lite shares the same
# install via a variable alias (jq-style).  RustBinPackage uses ifndef, so
# defining install here prevents it from generating a duplicate default rule.
define Package/easytier/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_INSTALL_DIR)/bin/easytier-core $(1)/usr/bin/
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
