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

PKG_MAINTAINER:=CrazyBoyFeng
PKG_LICENSE:=Apache-2.0
PKG_LICENSE_FILES:=LICENSE

PKG_BUILD_DEPENDS:=rust/host protobuf/host
PKG_BUILD_PARALLEL:=1

include $(INCLUDE_DIR)/package.mk
include $(TOPDIR)/feeds/packages/lang/rust/rust-package.mk

# prost-build needs protoc on the host
CARGO_PKG_VARS += PROTOC=$(STAGING_DIR_HOSTPKG)/bin/protoc

# Disable --locked: the codeload tarball may have a Cargo.lock that
# doesn't strictly match the resolved dependencies, causing
# cargo install to fail with exit code 2.
RUST_PKG_LOCKED:=0

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
  CONFLICTS:=easytier
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

# easytier is a workspace member, pass subdirectory path to cargo
Build/Compile=$(call Build/Compile/Cargo,easytier)

# Use RustBinPackage to auto-install all binaries from cargo install output.
# This must come BEFORE BuildPackage eval so the install rule is set first.
# Then we override install to add config + init script (RustBinPackage's install
# would only copy bin/* — our override replaces it entirely, so we include
# the bin copy manually).
$(eval $(call RustBinPackage,easytier-lite))
$(eval $(call RustBinPackage,easytier))

define Package/easytier-lite/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_INSTALL_DIR)/bin/easytier-core $(1)/usr/bin/
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/etc/config/easytier $(1)/etc/config/easytier
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/etc/init.d/easytier $(1)/etc/init.d/easytier
endef

define Package/easytier/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_INSTALL_DIR)/bin/easytier-core $(1)/usr/bin/
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/etc/config/easytier $(1)/etc/config/easytier
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/etc/init.d/easytier $(1)/etc/init.d/easytier
endef

$(eval $(call BuildPackage,easytier-lite))
$(eval $(call BuildPackage,easytier))
