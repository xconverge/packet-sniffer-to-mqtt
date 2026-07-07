# packet-sniffer-to-mqtt

Turn a Linux box with a WiFi adapter into a transparent WiFi access point that
**sniffs MQTT traffic from the devices connected to it** and re-publishes the
JSON payloads to your own MQTT broker.

It's designed for IoT devices that phone home to a vendor's cloud over MQTT
(TCP port 1883): you point the device at this AP, it happily talks to its cloud
as usual, and this tool passively mirrors every JSON message to a broker you
control — one topic per device, keyed by the device serial (`dsn`).

## How it works

```
                 ┌─────────────────────────── this container ───────────────────────────┐
  IoT device     │  hostapd (AP) → dnsmasq (DHCP) → iptables NAT → uplink (eth0)          │   vendor
  ───(WiFi)────► │        │                                                               │ ──► cloud
                 │        └── scapy sniffs tcp/1883 ── parse JSON ── publish ──► your MQTT │
                 └───────────────────────────────────────────────────────────────────────┘
```

1. **hostapd** turns `WLAN_IFACE` into a WPA2 access point.
2. **dnsmasq** hands out DHCP leases (`10.60.10.0/24`) to connected devices.
3. **iptables** NATs traffic from the AP out through the uplink interface, so
   devices reach the internet normally.
4. **scapy** sniffs `tcp port 1883` on the AP interface, finds the JSON body of
   each packet, extracts `device.dsn`, and publishes the payload to
   `MQTT_TOPIC/<dsn>` on your broker.

## Requirements

- A WiFi adapter that supports **AP mode** (`iw list` → "AP" under supported
  interface modes).
- An uplink with internet (auto-detected from the default route, or set
  `ETH_IFACE`).
- Docker + Docker Compose.
- `net.ipv4.ip_forward=1` **on the host** (see below).

## Configuration

All configuration is via environment variables in `docker-compose.yml`:

| Variable      | Required | Default          | Description                                        |
|---------------|----------|------------------|----------------------------------------------------|
| `MQTT_BROKER` | yes      | —                | IP/hostname of your MQTT broker                    |
| `MQTT_PORT`   | yes      | —                | Broker port (usually `1883`)                       |
| `MQTT_TOPIC`  | yes      | —                | Base topic; messages publish to `<topic>/<dsn>`    |
| `WLAN_IFACE`  | yes      | —                | WiFi interface to run the AP on (e.g. `wlan0`)     |
| `AP_SSID`     | no       | `ap_ssid`        | SSID broadcast by the AP                           |
| `AP_PASSWORD` | no       | `ap_password`    | WPA2 passphrase                                    |
| `AP_COUNTRY`  | no       | `US`             | Regulatory domain (affects channels & TX power)    |
| `AP_CHANNEL`  | no       | `6`              | 2.4 GHz channel                                    |
| `ETH_IFACE`   | no       | default route    | Uplink interface for NAT                           |
| `VERBOSE`     | no       | `false`          | Log raw/parsed payloads (noisy — debugging only)   |

The four required variables are validated at startup; the container exits with
a clear message if any are missing.

## Usage

1. Edit `docker-compose.yml` and fill in the required environment variables.
2. Enable IP forwarding **on the host** (see [Privileges](#privileges-and-ip_forward)):
   ```sh
   sudo sysctl -w net.ipv4.ip_forward=1
   ```
3. Build and run:
   ```sh
   docker compose up -d --build
   docker compose logs -f
   ```
4. Connect an IoT device to the `AP_SSID` network and watch messages appear on
   your broker under `MQTT_TOPIC/<dsn>`.

A prebuilt multi-arch image (amd64 + arm64) is published to GHCR on every push
via `.github/workflows/docker-publish.yml`.

## Privileges and `ip_forward`

The container needs to control the WiFi chip, manage iptables rules, and open
raw packet sockets. Rather than full `privileged: true`, it runs with only two
capabilities:

- **`NET_ADMIN`** — hostapd, `iw`, `ip`, iptables
- **`NET_RAW`** — scapy raw packet sockets

Because it uses `network_mode: host`, the container shares the host's network
namespace, and `/proc/sys/net/ipv4/ip_forward` is **read-only** to a
non-privileged container. So IP forwarding must be enabled on the host:

```sh
# One-off:
sudo sysctl -w net.ipv4.ip_forward=1

# Persistent across reboots:
echo 'net.ipv4.ip_forward=1' | sudo tee /etc/sysctl.d/99-mqtt-sniffer.conf
sudo sysctl --system
```

If your adapter/driver refuses to come up with just these capabilities, some
setups also need `/dev/rfkill` (uncomment the `devices:` block in the compose
file) or, as a last resort, full `privileged: true` (also commented in the
compose file).

## Notes and limitations

- **Single-packet JSON only.** Each captured TCP packet is parsed
  independently. MQTT messages whose JSON body spans multiple TCP segments
  won't parse. This is fine for typical small telemetry payloads; full TCP
  reassembly would be required otherwise.
- **Plaintext MQTT only.** This intercepts unencrypted MQTT on port 1883.
  TLS-encrypted MQTT (8883) cannot be read this way.
- **Passive mirror.** The tool does not modify or block device traffic; devices
  continue to reach their vendor cloud normally.
- Intended for use on networks and devices you own / are authorized to monitor.

## Development notes

Recent optimizations made to this project:

- **Image size:** dropped `libpcap-dev` from the Dockerfile. On Linux, scapy
  defaults to native `AF_PACKET` sockets (`conf.use_pcap = False`) and does not
  need libpcap, so it was pure bloat.
- **Performance:** the sniffer no longer re-serializes payloads. It parses each
  packet only to extract the `dsn`, then publishes the original JSON bytes as-is
  instead of `json.dumps()`-ing a round-tripped object.
- **Robustness:** MQTT reconnection now relies on paho's built-in network-loop
  reconnect (`reconnect_delay_set`) instead of a manual handler that called
  `loop_start()` from the network thread. Required environment variables are
  validated at startup.
- **Privileges:** replaced `privileged: true` with `cap_add: [NET_ADMIN,
  NET_RAW]` plus host-side `ip_forward`, with privileged left as a documented
  fallback.
</content>
</invoke>
