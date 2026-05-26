# openwrt-easytier

[EasyTier](https://github.com/EasyTier/EasyTier) OpenWrt package (lite & full builds).

EasyTier is a simple, decentralized and secure mesh VPN with WireGuard support, connecting your devices into a single virtual LAN, even behind NAT.

## Build Variants

| Variant | Package | Features | Target |
|---------|---------|----------|--------|
| lite | `easytier-lite` | tun, magic-dns, quic, kcp, websocket, faketcp, zstd, aes-gcm | Routers with limited flash (MT7621, 32MB) |
| full | `easytier` | all default features | x86 soft routers, aarch64 devices |

Removed from lite: `wireguard`, `socks5`, `smoltcp`. Users can install standalone OS packages (`wireguard-tools`, `microsocks`) if needed.

Both variants install `easytier-core` binary only. No `easytier-cli` is included.

## Quick Start

```sh
# 1. Edit configuration
vi /etc/config/easytier

# 2. Set network name and secret (REQUIRED)
uci set easytier.easytier.network_name='my-private-network'
uci set easytier.easytier.network_secret='my-secret-password'

# 3. Set your virtual IP or leave empty for DHCP auto-assign
uci set easytier.easytier.ipv4='10.144.144.1/24'

# 4. Add peer nodes
uci add_list easytier.easytier.peers='tcp://peer.example.com:11010'

# 5. Commit and start
uci commit easytier
/etc/init.d/easytier enable
/etc/init.d/easytier start
```

## UCI Configuration

All options are defined in a single `config easytier` section in `/etc/config/easytier`.

Multiple `config easytier` sections can be defined for multi-instance (each section starts an independent `easytier-core` process with its own TUN device and firewall zone). The **section name** is used as the default value for `--instance-name` and `--dev-name` (`et_{section_name}`).

### Network Settings

| Option | Type | Default | CLI Equivalent | Description |
|--------|------|---------|---------------|-------------|
| `network_name` | string | `easytier` | `--network-name` | Network identity (required, nodes with the same name form a virtual LAN) |
| `network_secret` | string | (empty) | `--network-secret` | Network secret for authentication |
| `ipv4` | string | (empty/DHCP) | `--ipv4` | Virtual IPv4 address (CIDR notation) |
| `ipv6` | string | (empty) | `--ipv6` | Virtual IPv6 address |
| `dhcp` | bool | `0` | `--dhcp` | Auto-assign IP via DHCP |
| `hostname` | string | (system) | `--hostname` | Device hostname, used by Magic DNS as `<hostname>.<tld_dns_zone>` |
| `instance_name` | string | (section name) | `--instance-name` | Instance name for identifying this VPN instance |
| `peers` | list | - | `--peers` | Initial peer node addresses to connect to |
| `external_node` | list | - | `--external-node` | Public shared node addresses for peer discovery |
| `proxy_networks` | list | - | `--proxy-networks` | Export local subnets (supports mapping: `10.0.0.0/24->192.168.0.0/24`) |

### Listener Settings

| Option | Type | Default | CLI Equivalent | Description |
|--------|------|---------|---------------|-------------|
| `listeners` | list | (built-in defaults) | `--listeners` | Listener URLs (tcp, udp, ws, wss, quic, faketcp) |
| `mapped_listeners` | list | - | `--mapped-listeners` | Public address mapping for listeners (behind NAT) |
| `default_protocol` | string | `tcp` | `--default-protocol` | Default protocol for connecting to peers |
| `no_listener` | bool | `0` | `--no-listener` | Don't listen on any port, only connect to peers |

### RPC Settings

| Option | Type | Default | CLI Equivalent | Description |
|--------|------|---------|---------------|-------------|
| `rpc_portal` | string | (empty) | `--rpc-portal` | RPC management portal address (`0` = random port) |
| `rpc_portal_whitelist` | string | (empty) | `--rpc-portal-whitelist` | RPC access whitelist (CIDR, comma-separated) |

### Encryption & Security

| Option | Type | Default | CLI Equivalent | Description |
|--------|------|---------|---------------|-------------|
| `disable_encryption` | bool | `0` | `--disable-encryption` | Disable encryption for peer communication |
| `encryption_algorithm` | string | (built-in) | `--encryption-algorithm` | `xor`, `aes-gcm`, `aes-256-gcm`, `chacha20` |

### Other Settings

| Option | Type | Default | CLI Equivalent | Description |
|--------|------|---------|---------------|-------------|
| `dev_name` | string | `et_{section_name}` | `--dev-name` | TUN device name |
| `mtu` | uint | (auto) | `--mtu` | MTU for the TUN device |
| `accept_dns` | bool | `0` | `--accept-dns` | Enable Magic DNS |
| `tld_dns_zone` | string | `et.net` | `--tld-dns-zone` | TLD DNS zone for Magic DNS |
| `latency_first` | bool | `0` | `--latency-first` | Use latency-priority routing |
| `compression` | string | (none) | `--compression` | Compression algorithm: `none`, `zstd` |
| `proxy_forward_by_system` | bool | `0` | `--proxy-forward-by-system` | Forward proxy traffic via system routing table |

### P2P Settings

| Option | Type | Default | CLI Equivalent | Description |
|--------|------|---------|---------------|-------------|
| `disable_p2p` | bool | `0` | `--disable-p2p` | Disable P2P |
| `p2p_only` | bool | `0` | `--p2p-only` | Only communicate with established P2P peers |
| `lazy_p2p` | bool | `0` | `--lazy-p2p` | Establish P2P only when traffic needs it |
| `need_p2p` | bool | `0` | `--need-p2p` | Ask peers to proactively establish P2P |
| `disable_udp_hole_punching` | bool | `0` | `--disable-udp-hole-punching` | Disable UDP hole punching |
| `disable_tcp_hole_punching` | bool | `0` | `--disable-tcp-hole-punching` | Disable TCP hole punching |
| `disable_sym_hole_punching` | bool | `0` | `--disable-sym-hole-punching` | Disable symmetric NAT hole punching |

### Logging Settings

| Option | Type | Default | CLI Equivalent | Description |
|--------|------|---------|---------------|-------------|
| `console_log_level` | string | `info` | `--console-log-level` | Console log level: `off`, `error`, `warn`, `info`, `debug`, `trace` |
| `file_log_level` | string | (empty) | `--file-log-level` | File log level |
| `file_log_dir` | string | (empty) | `--file-log-dir` | Log file directory (empty = disabled) |
| `file_log_size` | uint | `100` | `--file-log-size` | Per-file log size (MB) |
| `file_log_count` | uint | `10` | `--file-log-count` | Max log file count |

### OpenWrt Integration

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `auto_firewall` | bool | `1` | Automatically create a firewall zone (named after the section) with `masq` and `mtu_fix`, plus bidirectional forwarding to `firewall_zone` |
| `firewall_zone` | string | `lan` | Firewall zone to forward traffic to/from |
| `auto_dnsmasq` | bool | `1` | Automatically configure dnsmasq to forward `tld_dns_zone` queries to `100.100.100.101` |

## What the init.d Script Does

The procd init script automatically handles:

1. **IP forwarding** - Enable `net.ipv4.ip_forward` on start (required for VPN routing)
2. **Process management** - Start/stop/restart `easytier-core` via procd, auto-respawn on crash
3. **TUN device** - Wait for the TUN device to appear and bring it up
4. **Firewall** - Create a firewall zone (named after the section) with `masq` and `mtu_fix`, and bidirectional forwarding rules between the EasyTier zone and `firewall_zone`
5. **DNS (Magic DNS)** - Add a dnsmasq server directive to forward `tld_dns_zone` queries to the Magic DNS resolver (`100.100.100.101`)
6. **Cleanup** - Remove all firewall rules, dnsmasq config on stop
7. **Hot reload** - UCI changes trigger automatic restart via `procd_add_reload_trigger`

### Magic DNS on OpenWrt

When `accept_dns` is enabled, the init script adds a dnsmasq forwarding rule:
```
server=/et.net/100.100.100.101
```

This forwards all `*.et.net` DNS queries to `100.100.100.101`, which is the Magic DNS resolver address hardcoded in easytier-core. The resolver intercepts DNS packets on the TUN interface and resolves peer hostnames.

LAN devices can then access EasyTier peers via `hostname.et.net`.

## Multi-Instance Example

```uci
config easytier 'office'
    option enabled '1'
    option network_name 'office-net'
    option network_secret 'secret1'
    option ipv4 '10.144.144.1/24'
    list peers 'tcp://office.example.com:11010'

config easytier 'home'
    option enabled '1'
    option network_name 'home-net'
    option network_secret 'secret2'
    option ipv4 '10.192.192.1/24'
    list peers 'tcp://home.example.com:11010'
```

This creates two independent VPN instances:
- `office`: TUN device `et_office`, firewall zone `office`
- `home`: TUN device `et_home`, firewall zone `home`

## Build from Source

### Using OpenWrt SDK

```sh
# Clone into your SDK's package directory
git clone https://github.com/CrazyBoyFeng/openwrt-easytier.git \
    package/easytier

# Configure (select Network -> VPN -> easytier-lite or easytier)
make menuconfig

# Build lite
make package/easytier-lite/compile V=s

# Build full
make package/easytier/compile V=s
```

## Log Viewing

```sh
# View real-time logs (procd captures stdout/stderr to logd)
logread -f | grep easytier

# View all easytier logs
logread -e easytier

# Enable file logging (persistent)
uci set easytier.easytier.file_log_dir='/var/log/easytier'
uci set easytier.easytier.file_log_level='debug'
uci commit easytier
/etc/init.d/easytier restart
```

## Upstream Project

- [EasyTier GitHub](https://github.com/EasyTier/EasyTier)
- [EasyTier Documentation](https://easytier.cn)

## License

Apache-2.0 (same as upstream EasyTier)
