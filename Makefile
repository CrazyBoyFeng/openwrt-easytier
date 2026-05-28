include $(TOPDIR)/rules.mk

PKG_NAME:=easytier
PKG_VERSION:=2.6.4
PKG_RELEASE:=1

PKG_SOURCE_PROTO:=git
PKG_SOURCE_URL:=https://github.com/EasyTier/EasyTier.git
PKG_SOURCE_VERSION:=v$(PKG_VERSION)
PKG_MIRROR_HASH:=skip

PKG_MAINTAINER:=CrazyBoyFeng
PKG_LICENSE:=Apache-2.0
PKG_LICENSE_FILES:=LICENSE

PKG_BUILD_DEPENDS:=rust/host
PKG_BUILD_PARALLEL:=1

include $(INCLUDE_DIR)/package.mk

# ============ common ============
define Package/easytier/Default
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=VPN
  TITLE:=EasyTier P2P Mesh VPN
  URL:=https://github.com/EasyTier/EasyTier
  DEPENDS:=+kmod-tun
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
  Suitable for routers with limited flash storage (e.g. MT7621, 32MB).
endef

# ============ easytier (full) ============
define Package/easytier
  $(call Package/easytier/Default)
  TITLE+= (full build)
  VARIANT:=full
endef

define Package/easytier/description
  $(call Package/easytier/Default/description)
  .
  This full build includes all features: wireguard, socks5, smoltcp.
endef

# ============ Build/Compile ============
ifeq ($(BUILD_VARIANT),lite)
  EASYTIER_FEATURES:=tun,magic-dns,quic,kcp,websocket,faketcp,zstd,aes-gcm
  CARGO_FEATURES:=--no-default-features --features "$(EASYTIER_FEATURES)"
endif

ifeq ($(BUILD_VARIANT),full)
  CARGO_FEATURES:=
endif

# Derive the Rust/cargo target triple from OpenWrt's TARGET_CC.
# Converts the OpenWrt toolchain triplet to the Rust equivalent:
#   {arch}-openwrt-linux-{abi}-gcc  →  {arch}-unknown-linux-{abi}
# This works for any architecture / ABI that OpenWrt supports.
CARGO_TARGET:=$(shell echo $(TARGET_CC) | sed 's/-openwrt-/-unknown-/;s/-gcc$$//')

define Build/Compile
        $(MAKE_VARS) \
        CC="$(TARGET_CC)" \
        CXX="$(TARGET_CXX)" \
        cargo build --release \
                --manifest-path $(PKG_BUILD_DIR)/Cargo.toml \
                -p easytier \
                --target $(CARGO_TARGET) \
                $(CARGO_FEATURES)
endef

# ============ Install ============
define Package/easytier-lite/install
        $(INSTALL_DIR) $(1)/usr/bin
        $(INSTALL_BIN) $(PKG_BUILD_DIR)/target/$(CARGO_TARGET)/release/easytier-core $(1)/usr/bin/
        $(INSTALL_DIR) $(1)/etc/config
        $(INSTALL_CONF) ./files/etc/config/easytier $(1)/etc/config/easytier
        $(INSTALL_DIR) $(1)/etc/init.d
        $(INSTALL_BIN) ./files/etc/init.d/easytier $(1)/etc/init.d/easytier
endef

define Package/easytier/install
        $(INSTALL_DIR) $(1)/usr/bin
        $(INSTALL_BIN) $(PKG_BUILD_DIR)/target/$(CARGO_TARGET)/release/easytier-core $(1)/usr/bin/
        $(INSTALL_DIR) $(1)/etc/config
        $(INSTALL_CONF) ./files/etc/config/easytier $(1)/etc/config/easytier
        $(INSTALL_DIR) $(1)/etc/init.d
        $(INSTALL_BIN) ./files/etc/init.d/easytier $(1)/etc/init.d/easytier
endef

$(eval $(call BuildPackage,easytier-lite))
$(eval $(call BuildPackage,easytier))
