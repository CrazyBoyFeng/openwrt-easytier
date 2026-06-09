# openwrt-easytier

[EasyTier](https://github.com/EasyTier/EasyTier) OpenWrt package (lite & default variants of easytier-core).

EasyTier is a simple, decentralized and secure mesh VPN with WireGuard support, connecting your devices into a single virtual LAN, even behind NAT.

## Build Variants

| Variant | Package | Features |
|---------|---------|----------|
| lite | `easytier-lite` | tun, magic-dns, kcp, faketcp, zstd, aes-gcm |
| default | `easytier` | all default features |

Removed from lite: `wireguard`, `socks5`, `smoltcp`, `quic`, `websocket`. Users can install standalone OS packages (`wireguard-tools`, `microsocks`) if needed.

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

## External Config Modes

When `config_server` or `config_dir` is set, **network interface, firewall, and DNS can NOT auto-configured.** Users must manually set up the following three parts.

> **Prerequisite:** Find your TUN device name first. Run `ip link` after starting EasyTier, or check `logread | grep easytier` for the device name. The following examples assume the device name is `et0`.

```uci
# Config server
config easytier 'easytier'
    option enabled '1'
    option config_server 'admin'
    # option machine_id ''

# Config directory (load all .toml, persist config-server settings)
# option config_dir '/etc/easytier'
```

### 1. Network Interface

EasyTier creates the TUN device itself, but you need to bring it up and (optionally) assign it to a UCI network interface so that other OpenWrt services can reference it. Edit `/etc/config/network`:

```uci
# /etc/config/network
config device
    option name 'et0'              # must match the TUN device name
    option mtu '1420'              # optional, EasyTier default is 1420

config interface 'et0'
    option device 'et0'
    option proto 'none'            # no DHCP or static IP — EasyTier manages addressing
```

> If you don't need other OpenWrt services (e.g., `dhcp` firewall zone) to reference this interface, you can skip the UCI interface and just run `ip link set et0 up` manually or via a hotplug script.

### 2. Firewall

Create a firewall zone for the TUN device and set up forwarding rules. Edit `/etc/config/firewall`:

**Basic setup (bidirectional forwarding with LAN):**

```uci
# /etc/config/firewall
config zone
    option name 'et0'
    option input 'ACCEPT'
    option output 'ACCEPT'
    option forward 'ACCEPT'
    option network 'et0'
    option mtu_fix '1'             # MSS clamping — always recommended for TUN

# LAN ↔ EasyTier (LAN devices access the virtual network)
config forwarding
    option src 'lan'
    option dest 'et0'

# EasyTier ↔ LAN (virtual network devices access LAN)
config forwarding
    option src 'et0'
    option dest 'lan'
```

**If `proxy_forward_by_system` is enabled**, add masquerade on the EasyTier zone:

```uci
config zone
    option name 'et0'
    # ... (same as above)
    option masq '1'                # OS kernel performs NAT for forwarded traffic
```

**If both `proxy_forward_by_system` and `enable_exit_node` are enabled**, additionally allow EasyTier → WAN forwarding so exit traffic can reach the internet:

```uci
# EasyTier → WAN (exit node traffic to internet)
config forwarding
    option src 'et0'
    option dest 'wan'
```

### 3. DNS (Magic DNS)

If Magic DNS is enabled in your EasyTier config, forward the TLD zone to EasyTier's built-in DNS resolver (`100.100.100.101`). Edit `/etc/config/dhcp`:

```uci
# /etc/config/dhcp — replace "et.net" with your actual tld_dns_zone
config dnsmasq
    option server '/et.net/100.100.100.101'
```

Then reload the services:

```sh
/etc/init.d/network reload
/etc/init.d/firewall reload
/etc/init.d/dnsmasq restart
```

## UCI Configuration

Options are defined in `config easytier` sections in `/etc/config/easytier`.

Multiple `config easytier` sections can be defined for multi-instance (each section starts an independent `easytier-core` process with its own TUN device and firewall zone). The **section name** is used as the default value for `--instance-name` and `--dev-name` (`et_{section_name}`).

Options are following the [official documentation](https://easytier.cn/guide/network/configurations.html).

### Config Settings

| Option | Default | CLI Equivalent | Description |
|--------|---------|---------------|-------------|
| `config_server` | (empty) | `--config-server` | Config server address (URL or username for official server) |
| `machine_id` | (auto) | `--machine-id` | Machine ID for config server identification (auto-detected if empty) |
| `config_file` | (empty) | `--config-file` | TOML config file path (CLI options override file options) |
| `config_dir` | (empty) | `--config-dir` | Load all `.toml` files from a directory; also persists config-server settings |
| `disable_env_parsing` | `0` | `--disable-env-parsing` | Disable environment variable parsing in config files |

### Network Settings

| Option | Default | CLI Equivalent | Description |
|--------|---------|---------------|-------------|
| `network_name` | `easytier` | `--network-name` | Network identity (required in CLI mode) |
| `network_secret` | (empty) | `--network-secret` | Network secret for authentication |
| `secure_mode` | `0` | `--secure-mode` | Enable Noise secure handshake |
| `local_private_key` | (empty) | `--local-private-key` | Static private key for secure mode (base64) |
| `local_public_key` | (empty) | `--local-public-key` | Static public key for secure mode (base64) |
| `credential` | (empty) | `--credential` | Temporary credential private key (base64) |
| `credential_file` | (empty) | `--credential-file` | Credential persistence file path |
| `ipv4` | (empty) | `--ipv4` | Virtual IPv4 address (CIDR) |
| `ipv6` | (empty) | `--ipv6` | Virtual IPv6 address |
| `ipv6_public_addr_provider` | `0` | `--ipv6-public-addr-provider` | Share public IPv6 subnet with peers (Linux only) |
| `ipv6_public_addr_auto` | `0` | `--ipv6-public-addr-auto` | Auto-obtain public IPv6 address from a peer |
| `ipv6_public_addr_prefix` | (empty) | `--ipv6-public-addr-prefix` | Manually specify IPv6 public subnet to share (CIDR) |
| `dhcp` | `0` | `--dhcp` | Auto-assign IP via DHCP |
| `hostname` | (system) | `--hostname` | Device hostname for Magic DNS |
| `instance_name` | (section) | `--instance-name` | Instance name |
| `peers` | - | `--peers` | Peer node addresses. Transport: same as listeners; Discovery: `txt://`, `srv://` (all variants); `http://`, `https://` (default only) |
| `external_node` | (empty) | `--external-node` | Public shared node address (functionally equivalent to `peers`) |
| `proxy_networks` | - | `--proxy-networks` | Export local subnets (supports mapping: `10.0.0.0/24->192.168.0.0/24`) |

### RPC Settings

| Option | Default | CLI Equivalent | Description |
|--------|---------|---------------|-------------|
| `rpc_portal` | `0` | `--rpc-portal` | RPC portal address (`0` = random port) |
| `rpc_portal_whitelist` | (empty) | `--rpc-portal-whitelist` | RPC whitelist (CIDR, comma-separated) |

### Listener Settings

| Option | Default | CLI Equivalent | Description |
|--------|---------|---------------|-------------|
| `listeners` | (auto) | `--listeners` | Accept connections. Three formats: plain port `<11010>` (tcp/udp on 11010, ws/wss on 11010+11011, wg on 11011); URL `<protocol://0.0.0.0:11010>` (protocol: `tcp`, `udp`, `ring`, `unix`, `wg`, `ws`, `wss`, `quic`, `faketcp`); shorthand `<proto:port>` (e.g. `wg:11011`). Variant availability: `tcp`, `udp`, `ring`, `unix`, `faketcp` (all); `wg`, `quic`, `ws`, `wss` (default only) |
| `mapped_listeners` | - | `--mapped-listeners` | Public address for NAT traversal, e.g. `tcp://1.2.3.4:11010` |
| `no_listener` | `0` | `--no-listener` | Don't listen on any port |
| `default_protocol` | (auto) | `--default-protocol` | Default protocol for peer connections |

### Other Settings

| Option | Default | CLI Equivalent | Description |
|--------|---------|---------------|-------------|
| `vpn_portal` | (empty) | `--vpn-portal` | VPN portal URL, e.g. `wg://0.0.0.0:11010/10.14.14.0/24` (**no effect in lite**) |
| `disable_encryption` | `0` | `--disable-encryption` | Disable encryption |
| `encryption_algorithm` | `aes-gcm` | `--encryption-algorithm` | `xor`, `chacha20` (**not in lite**), `aes-gcm`, `aes-gcm-256`, `openssl-aes128-gcm`, `openssl-aes256-gcm`, `openssl-chacha20` (**openssl-* not available in packaged variants**) |
| `multi_thread` | `0` | `--multi-thread` | Enable multi-threaded runtime |
| `multi_thread_count` | `2` | `--multi-thread-count` | Thread count (must be > 2, only with multi-thread) |
| `disable_ipv6` | `0` | `--disable-ipv6` | Disable IPv6 |
| `dev_name` | `et_{section}` | `--dev-name` | TUN device name |
| `mtu` | `1380/1360` | `--mtu` | TUN device MTU (1380 for non-encryption, 1360 for encryption) |
| `latency_first` | `0` | `--latency-first` | Use lowest-latency path |
| `exit_nodes` | - | `--exit-nodes` | Exit node IPv4 addresses (traffic forwarding) |
| `enable_exit_node` | `0` | `--enable-exit-node` | Allow this node to be an exit node |
| `proxy_forward_by_system` | `0` | `--proxy-forward-by-system` | Forward subnet proxy via kernel routing |
| `no_tun` | `0` | `--no-tun` | Don't create TUN device |
| `use_smoltcp` | `0` | `--use-smoltcp` | Enable smoltcp stack for subnet proxy and KCP (**no effect in lite**) |
| `manual_routes` | - | `--manual-routes` | Manual route CIDRs (disables subnet proxy) |
| `relay_network_whitelist` | (empty) | `--relay-network-whitelist` | Only relay traffic for whitelisted networks |
| `p2p_only` | `0` | `--p2p-only` | Only communicate with established P2P peers |
| `lazy_p2p` | `0` | `--lazy-p2p` | Establish P2P only when traffic needs it |
| `disable_p2p` | `0` | `--disable-p2p` | Disable automatic P2P |
| `need_p2p` | `0` | `--need-p2p` | Ask peers to proactively establish P2P |
| `disable_tcp_hole_punching` | `0` | `--disable-tcp-hole-punching` | Disable TCP hole punching |
| `disable_udp_hole_punching` | `0` | `--disable-udp-hole-punching` | Disable UDP hole punching |
| `disable_sym_hole_punching` | `0` | `--disable-sym-hole-punching` | Disable symmetric NAT hole punching |
| `disable_upnp` | `0` | `--disable-upnp` | Disable UPnP/NAT-PMP automatic port mapping |
| `relay_all_peer_rpc` | `0` | `--relay-all-peer-rpc` | Relay all peer RPC packets |
| `socks5` | (empty) | `--socks5` | SOCKS5 proxy port number, e.g. `1080` (**not available in lite**) |
| `compression` | `none` | `--compression` | `none` or `zstd` |
| `bind_device` | (empty) | `--bind-device` | Bind connector sockets to physical device |
| `enable_kcp_proxy` | `0` | `--enable-kcp-proxy` | Use KCP proxy for TCP streams |
| `disable_kcp_input` | `0` | `--disable-kcp-input` | Disallow KCP proxy input from other nodes |
| `enable_quic_proxy` | `0` | `--enable-quic-proxy` | Use QUIC proxy for TCP streams (**no effect in lite**) |
| `disable_quic_input` | `0` | `--disable-quic-input` | Disallow QUIC proxy input from other nodes (**no effect in lite**) |
| `port_forward` | - | `--port-forward` | Port forwarding rules, e.g. `udp://0.0.0.0:12345/10.126.126.1:23456` |
| `accept_dns` | `0` | `--accept-dns` | Enable Magic DNS |
| `tld_dns_zone` | `et.net` | `--tld-dns-zone` | TLD DNS zone for Magic DNS |
| `private_mode` | `0` | `--private-mode` | Only relay same-network traffic |
| `foreign_relay_bps_limit` | (empty) | `--foreign-relay-bps-limit` | Limit foreign network relay bandwidth (BPS) |
| `instance_recv_bps_limit` | (empty) | `--instance-recv-bps-limit` | Limit instance receive bandwidth (BPS) |
| `tcp_whitelist` | (empty) | `--tcp-whitelist` | TCP port whitelist, comma-separated (supports ranges: `80`, `8000-9000`) |
| `udp_whitelist` | (empty) | `--udp-whitelist` | UDP port whitelist, comma-separated (supports ranges: `53`, `5000-6000`) |
| `disable_relay_kcp` | `0` | `--disable-relay-kcp` | Disallow forwarding KCP packets |
| `enable_relay_foreign_network_kcp` | `0` | `--enable-relay-foreign-network-kcp` | Allow relaying foreign network KCP |
| `disable_relay_quic` | `0` | `--disable-relay-quic` | Disallow forwarding QUIC packets (**no effect in lite**) |
| `enable_relay_foreign_network_quic` | `0` | `--enable-relay-foreign-network-quic` | Allow relaying foreign network QUIC (**no effect in lite**) |
| `stun_servers` | (defaults) | `--stun-servers` | Override default STUN server list (empty list disables STUN) |
| `stun_servers_v6` | (defaults) | `--stun-servers-v6` | Override default IPv6 STUN server list (empty list disables STUN) |

### Logging Settings

| Option | Default | CLI Equivalent | Description |
|--------|---------|---------------|-------------|
| `console_log_level` | `info` | `--console-log-level` | `off`, `error`, `warn`, `info`, `debug`, `trace` |
| `file_log_level` | (empty) | `--file-log-level` | File log level |
| `file_log_dir` | (empty) | `--file-log-dir` | Log directory (empty = disabled) |
| `file_log_size` | `100` | `--file-log-size` | Per-file log size (MB) |
| `file_log_count` | `10` | `--file-log-count` | Max log file count |

### OpenWrt Integration

Not effective when `config_server` or `config_dir` is set.

| Option | Default | Description |
|--------|---------|-------------|
| `auto_firewall` | `0` | Create firewall zone with `mtu_fix` and bidirectional forwarding |
| `firewall_zone` | `lan` | Firewall zone to forward traffic to/from |
| `auto_dnsmasq` | `0` | Forward `tld_dns_zone` queries to `100.100.100.101` via dnsmasq |

## What the init.d Script Does

The procd init script automatically handles:

1. **Process management** - Start/stop/restart `easytier-core` via procd, auto-respawn
2. **TUN device** - Wait for TUN device, bring it up
3. **Firewall** - Create zone with `mtu_fix` and bidirectional forwarding; `masq` when `proxy_forward_by_system=1`; enable `net.ipv4.ip_forward` when `proxy_forward_by_system=1`
4. **DNS (Magic DNS)** - Add dnsmasq forwarding rule for `tld_dns_zone`
5. **Cleanup** - Remove firewall rules and dnsmasq config on stop
6. **Hot reload** - UCI changes trigger automatic restart via `procd_add_reload_trigger`

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
git clone https://github.com/CrazyBoyFeng/openwrt-easytier.git package/easytier

# Update and install all feeds (required for rust/host, protobuf/host, kmod-tun)
./scripts/feeds update -a
./scripts/feeds install -a

# Configure
make menuconfig

# Build default variant
make package/easytier/compile V=s

# Build lite variant
make package/easytier/lite/compile V=s
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
