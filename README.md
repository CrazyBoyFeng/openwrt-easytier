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
uci set easytier.main.network_name='my-private-network'
uci set easytier.main.network_secret='my-secret-password'

# 3. Set your virtual IP or leave empty for DHCP auto-assign
uci set easytier.main.ipv4='10.144.144.1/24'

# 4. Add peer nodes
uci add_list easytier.main.peers='tcp://peer.example.com:11010'

# 5. Commit and start
uci commit easytier
/etc/init.d/easytier enable
/etc/init.d/easytier start
```

## UCI Configuration

All options are in `/etc/config/easytier`:

### Main (`config easytier`)

| Option | Type | Default | CLI Equivalent | Description |
|--------|------|---------|---------------|-------------|
| `network_name` | string | `easytier` | `--network-name` | Network identity (required) |
| `network_secret` | string | (empty) | `--network-secret` | Network secret for authentication |
| `ipv4` | string | (empty/DHCP) | `-i` | Virtual IPv4 (CIDR) |
| `ipv6` | string | (empty) | `--ipv6` | Virtual IPv6 |
| `hostname` | string | (system) | `--hostname` | Hostname for Magic DNS |
| `instance_name` | string | (empty) | `-m` | Instance name |
| `peers` | list | - | `-p` | Peer node URLs |
| `listeners` | list | (default) | `-l` | Listener addresses |
| `external_node` | string | (empty) | `-e` | Public discovery node |
| `proxy_networks` | list | - | `-n` | Export local subnets (supports mapping) |
| `mapped_listeners` | list | - | `--mapped-listeners` | Public mapped addresses |
| `default_protocol` | string | `tcp` | `--default-protocol` | Default protocol for peers |
| `no_listener` | bool | `0` | `--no-listener` | Don't listen on any port |

### Advanced (`config advanced`)

| Option | Type | Default | CLI Equivalent | Description |
|--------|------|---------|---------------|-------------|
| `encryption_algorithm` | string | (built-in) | `--encryption-algorithm` | `aes-gcm`, `aes-256-gcm`, `xor` |
| `disable_encryption` | bool | `0` | `-u` | Disable encryption |
| `console_log_level` | string | `info` | `--console-log-level` | Console log level |
| `file_log_level` | string | (empty) | `--file-log-level` | File log level |
| `file_log_dir` | string | (empty) | `--file-log-dir` | Log file directory |
| `file_log_size` | uint | `100` | `--file-log-size` | Per-file log size (MB) |
| `file_log_count` | uint | `10` | `--file-log-count` | Max log file count |
| `accept_dns` | bool | `0` | `--accept-dns` | Enable Magic DNS |
| `tld_dns_zone` | string | `et.net.` | `--tld-dns-zone` | DNS zone for Magic DNS |
| `mtu` | uint | (auto) | `--mtu` | TUN device MTU |
| `dev_name` | string | (auto) | `--dev-name` | TUN device name |
| `compression` | string | (none) | `--compression` | `none` or `zstd` |
| `enable_kcp_proxy` | bool | `0` | `--enable-kcp-proxy` | KCP proxy for TCP streams |
| `enable_quic_proxy` | bool | `0` | `--enable-quic-proxy` | QUIC proxy for TCP streams |

### P2P (`config p2p`)

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `disable_p2p` | bool | `0` | Disable P2P |
| `p2p_only` | bool | `0` | Only use established P2P |
| `lazy_p2p` | bool | `0` | Establish P2P on demand |
| `need_p2p` | bool | `0` | Ask peers to proactively P2P |
| `disable_udp_hole_punching` | bool | `0` | Disable UDP hole punching |
| `disable_tcp_hole_punching` | bool | `0` | Disable TCP hole punching |
| `disable_sym_hole_punching` | bool | `0` | Disable symmetric NAT punching |

### RPC (`config rpc`)

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `rpc_portal` | string | `0` | RPC portal address |
| `rpc_portal_whitelist` | string | (empty) | RPC whitelist (CIDR) |

### Network (`config network`) - OpenWrt specific

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `iface_name` | string | `et0` | OpenWrt interface name (netifd) |
| `auto_firewall` | bool | `1` | Auto-configure firewall |
| `firewall_zone` | string | `lan` | Firewall zone to attach |
| `auto_dnsmasq` | bool | `1` | Auto-configure dnsmasq for Magic DNS |

## What the init.d Script Does

The procd init script automatically handles:

1. **Process management** - Start/stop/restart easytier-core via procd, auto-respawn on crash
2. **Network interface** - Detect TUN interface, register with netifd
3. **Firewall** - Create `easytier` zone, add forwarding rules between easytier and LAN zone
4. **DNS (Magic DNS)** - Add dnsmasq server directive `server=/et.net/100.100.100.101` to forward DNS queries to Magic DNS resolver
5. **Cleanup** - Remove all firewall rules, dnsmasq config, netifd interface on stop
6. **Hot reload** - UCI changes trigger automatic restart via `procd_add_reload_trigger`

### Magic DNS on OpenWrt

When `accept_dns` is enabled, the init script adds a dnsmasq forwarding rule:
```
server=/et.net/100.100.100.101
```

This forwards all `*.et.net` DNS queries to `100.100.100.101`, which is the Magic DNS resolver address hardcoded in easytier-core (`MAGIC_DNS_FAKE_IP`). The resolver intercepts DNS packets on the TUN interface and resolves peer hostnames.

LAN devices can then access EasyTier peers via `hostname.et.net`.

## Build from Source

### Using OpenWrt SDK

```sh
# Clone into your SDK's package directory
git clone https://github.com/CrazyBoyFeng/openwrt-easytier.git \
    feeds/packages/net/easytier

# Update feeds
./scripts/feeds update -a
./scripts/feeds install -a

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
uci set easytier.advanced.file_log_dir='/var/log/easytier'
uci set easytier.advanced.file_log_level='debug'
uci commit easytier
/etc/init.d/easytier restart
```

## Upstream Project

- [EasyTier GitHub](https://github.com/EasyTier/EasyTier)
- [EasyTier Documentation](https://easytier.cn)

## License

Apache-2.0 (same as upstream EasyTier)
