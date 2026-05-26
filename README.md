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

## Config-Server Mode

Set `config_server` to connect to a remote config server. In this mode, all network parameters (peers, encryption, routes, etc.) are managed remotely by the server. The init script only passes `--config-server` to `easytier-core` — **network interface and firewall are NOT auto-configured**, similar to how [ZeroTier](https://openwrt.org/docs/guide-user/services/vpn/zerotier) and [Tailscale](https://openwrt.org/docs/guide-user/services/vpn/tailscale) work on OpenWrt. Users must manually configure `/etc/config/network` and `/etc/config/firewall`.

```uci
config easytier 'easytier'
    option enabled '1'
    option config_server 'admin'          # official server (short form)
    # option config_server 'udp://127.0.0.1:22020/admin'  # or full URL
    # option machine_id ''               # optional, auto-detected if empty
```

## UCI Configuration

All options are defined in a single `config easytier` section in `/etc/config/easytier`.

Multiple `config easytier` sections can be defined for multi-instance (each section starts an independent `easytier-core` process with its own TUN device and firewall zone). The **section name** is used as the default value for `--instance-name` and `--dev-name` (`et_{section_name}`).

Options are ordered following the [official documentation](https://easytier.cn/guide/network/configurations.html).

### Config Server

| Option | Type | Default | CLI Equivalent | Description |
|--------|------|---------|---------------|-------------|
| `config_server` | string | (empty) | `--config-server` | Config server address (URL or username for official server) |
| `machine_id` | string | (auto) | `--machine-id` | Machine ID for config server identification (auto-detected if empty) |

### Network Settings

| Option | Type | Default | CLI Equivalent | Description |
|--------|------|---------|---------------|-------------|
| `network_name` | string | `easytier` | `--network-name` | Network identity (required in CLI mode) |
| `network_secret` | string | (empty) | `--network-secret` | Network secret for authentication |
| `secure_mode` | bool | `0` | `--secure-mode` | Enable Noise secure handshake |
| `local_private_key` | string | (empty) | `--local-private-key` | Static private key for secure mode (base64) |
| `local_public_key` | string | (empty) | `--local-public-key` | Static public key for secure mode (base64) |
| `credential` | string | (empty) | `--credential` | Temporary credential private key (base64) |
| `credential_file` | string | (empty) | `--credential-file` | Credential persistence file path |
| `ipv4` | string | (empty) | `--ipv4` | Virtual IPv4 address (CIDR) |
| `ipv6` | string | (empty) | `--ipv6` | Virtual IPv6 address |
| `dhcp` | bool | `0` | `--dhcp` | Auto-assign IP via DHCP |
| `hostname` | string | (system) | `--hostname` | Device hostname for Magic DNS |
| `instance_name` | string | (section) | `--instance-name` | Instance name |
| `peers` | list | - | `--peers` | Initial peer node addresses |
| `external_node` | list | - | `--external-node` | Public shared node addresses |
| `proxy_networks` | list | - | `--proxy-networks` | Export local subnets (supports mapping: `10.0.0.0/24->192.168.0.0/24`) |

### RPC Settings

| Option | Type | Default | CLI Equivalent | Description |
|--------|------|---------|---------------|-------------|
| `rpc_portal` | string | (empty) | `--rpc-portal` | RPC portal address (`0` = random port) |
| `rpc_portal_whitelist` | string | (empty) | `--rpc-portal-whitelist` | RPC whitelist (CIDR, comma-separated) |

### Listener Settings

| Option | Type | Default | CLI Equivalent | Description |
|--------|------|---------|---------------|-------------|
| `listeners` | list | (defaults) | `--listeners` | Listener URLs (tcp, udp, ws, wss, quic, wg, faketcp) |
| `mapped_listeners` | list | - | `--mapped-listeners` | Public address mapping for NAT traversal |
| `no_listener` | bool | `0` | `--no-listener` | Don't listen on any port |
| `default_protocol` | string | (auto) | `--default-protocol` | Default protocol for peer connections |

### Other Settings

| Option | Type | Default | CLI Equivalent | Description |
|--------|------|---------|---------------|-------------|
| `hostname` | string | (system) | `--hostname` | Device hostname |
| `instance_name` | string | (section) | `--instance-name` | Instance name |
| `vpn_portal` | string | (empty) | `--vpn-portal` | VPN portal URL, e.g. `wg://0.0.0.0:11010/10.14.14.0/24` |
| `disable_encryption` | bool | `0` | `--disable-encryption` | Disable encryption |
| `encryption_algorithm` | string | (aes-gcm) | `--encryption-algorithm` | `xor`, `chacha20`, `aes-gcm`, `aes-256-gcm`, etc. |
| `multi_thread` | bool | `0` | `--multi-thread` | Enable multi-threaded runtime |
| `multi_thread_count` | uint | (2) | `--multi-thread-count` | Thread count (must be > 2, only with multi-thread) |
| `disable_ipv6` | bool | `0` | `--disable-ipv6` | Disable IPv6 |
| `dev_name` | string | `et_{section}` | `--dev-name` | TUN device name |
| `mtu` | uint | (auto) | `--mtu` | TUN device MTU |
| `latency_first` | bool | `0` | `--latency-first` | Use lowest-latency path |
| `exit_nodes` | list | - | `--exit-nodes` | Exit node IPv4 addresses (traffic forwarding) |
| `enable_exit_node` | bool | `0` | `--enable-exit-node` | Allow this node to be an exit node |
| `proxy_forward_by_system` | bool | `0` | `--proxy-forward-by-system` | Forward subnet proxy via kernel routing |
| `no_tun` | bool | `0` | `--no-tun` | Don't create TUN device |
| `use_smoltcp` | bool | `0` | `--use-smoltcp` | Enable smoltcp stack for subnet proxy and KCP |
| `manual_routes` | list | - | `--manual-routes` | Manual route CIDRs (disables subnet proxy) |
| `relay_network_whitelist` | string | (empty) | `--relay-network-whitelist` | Only relay traffic for whitelisted networks |
| `p2p_only` | bool | `0` | `--p2p-only` | Only communicate with established P2P peers |
| `lazy_p2p` | bool | `0` | `--lazy-p2p` | Establish P2P only when traffic needs it |
| `disable_p2p` | bool | `0` | `--disable-p2p` | Disable automatic P2P |
| `need_p2p` | bool | `0` | `--need-p2p` | Ask peers to proactively establish P2P |
| `disable_tcp_hole_punching` | bool | `0` | `--disable-tcp-hole-punching` | Disable TCP hole punching |
| `disable_udp_hole_punching` | bool | `0` | `--disable-udp-hole-punching` | Disable UDP hole punching |
| `disable_sym_hole_punching` | bool | `0` | `--disable-sym-hole-punching` | Disable symmetric NAT hole punching |
| `relay_all_peer_rpc` | bool | `0` | `--relay-all-peer-rpc` | Relay all peer RPC packets |
| `socks5` | string | (empty) | `--socks5` | SOCKS5 proxy port, e.g. `1080` |
| `compression` | string | (none) | `--compression` | `none` or `zstd` |
| `bind_device` | string | (empty) | `--bind-device` | Bind connector sockets to physical device |
| `enable_kcp_proxy` | bool | `0` | `--enable-kcp-proxy` | Use KCP proxy for TCP streams |
| `disable_kcp_input` | bool | `0` | `--disable-kcp-input` | Disallow KCP proxy input from other nodes |
| `enable_quic_proxy` | bool | `0` | `--enable-quic-proxy` | Use QUIC proxy for TCP streams |
| `disable_quic_input` | bool | `0` | `--disable-quic-input` | Disallow QUIC proxy input from other nodes |
| `quic_listen_port` | uint | (0) | `--quic-listen-port` | QUIC listener port (0 = random) |
| `port_forward` | list | - | `--port-forward` | Port forwarding rules, e.g. `udp://0.0.0.0:12345/10.126.126.1:23456` |
| `accept_dns` | bool | `0` | `--accept-dns` | Enable Magic DNS |
| `tld_dns_zone` | string | `et.net` | `--tld-dns-zone` | TLD DNS zone for Magic DNS |
| `private_mode` | bool | `0` | `--private-mode` | Only relay same-network traffic |
| `foreign_relay_bps_limit` | string | (empty) | `--foreign-relay-bps-limit` | Limit relay bandwidth |
| `tcp_whitelist` | string | (empty) | `--tcp-whitelist` | TCP port whitelist (supports ranges: `80`, `8000-9000`) |
| `udp_whitelist` | string | (empty) | `--udp-whitelist` | UDP port whitelist (supports ranges) |
| `disable_relay_kcp` | bool | `0` | `--disable-relay-kcp` | Disallow forwarding KCP packets |
| `enable_relay_foreign_network_kcp` | bool | `0` | `--enable-relay-foreign-network-kcp` | Allow relaying foreign network KCP |
| `stun_servers` | list | - | `--stun-servers` | Override default STUN server list |
| `stun_servers_v6` | list | - | `--stun-servers-v6` | Override default IPv6 STUN server list |

### Logging Settings

| Option | Type | Default | CLI Equivalent | Description |
|--------|------|---------|---------------|-------------|
| `console_log_level` | string | `info` | `--console-log-level` | `off`, `error`, `warn`, `info`, `debug`, `trace` |
| `file_log_level` | string | (empty) | `--file-log-level` | File log level |
| `file_log_dir` | string | (empty) | `--file-log-dir` | Log directory (empty = disabled) |
| `file_log_size` | uint | `100` | `--file-log-size` | Per-file log size (MB) |
| `file_log_count` | uint | `10` | `--file-log-count` | Max log file count |

### OpenWrt Integration (CLI mode only)

These options are only effective in CLI mode (when `config_server` is not set).

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `auto_firewall` | bool | `1` | Create firewall zone with `masq` and `mtu_fix`, plus forwarding |
| `firewall_zone` | string | `lan` | Firewall zone to forward traffic to/from |
| `auto_dnsmasq` | bool | `1` | Forward `tld_dns_zone` queries to `100.100.100.101` via dnsmasq |

## What the init.d Script Does

The procd init script automatically handles:

1. **IP forwarding** - Enable `net.ipv4.ip_forward` on start
2. **Process management** - Start/stop/restart `easytier-core` via procd, auto-respawn
3. **TUN device** - Wait for TUN device, bring it up
4. **Firewall** - Create zone with `masq`/`mtu_fix`, bidirectional forwarding (CLI mode only)
5. **DNS (Magic DNS)** - Add dnsmasq forwarding rule for `tld_dns_zone` (CLI mode only)
6. **Cleanup** - Remove firewall rules and dnsmasq config on stop
7. **Hot reload** - UCI changes trigger automatic restart via `procd_add_reload_trigger`

### Magic DNS on OpenWrt

When `accept_dns` is enabled, the init script adds a dnsmasq forwarding rule:
```
server=/et.net/100.100.100.101
```

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
