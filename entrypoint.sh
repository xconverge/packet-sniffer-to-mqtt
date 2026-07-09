#!/bin/bash
set -e

WLAN_IFACE="${WLAN_IFACE:-wlan0}"
ETH_IFACE="${ETH_IFACE:-$(ip route show default | awk '/default/ {print $5; exit}')}"
AP_SSID="${AP_SSID:-ap_ssid}"
AP_PASSWORD="${AP_PASSWORD:-ap_password}"
AP_COUNTRY="${AP_COUNTRY:-US}"
AP_CHANNEL="${AP_CHANNEL:-6}"
AP_TXPOWER="${AP_TXPOWER:-2000}"

# Set regulatory domain so the adapter can use its full legal TX power
iw reg set "${AP_COUNTRY}"

echo "Using uplink interface: ${ETH_IFACE}"

# Generate hostapd config from environment
cat > /etc/hostapd/hostapd.conf << EOF
interface=${WLAN_IFACE}
driver=nl80211
ssid=${AP_SSID}
hw_mode=g
channel=${AP_CHANNEL}
wmm_enabled=1
country_code=${AP_COUNTRY}
ieee80211d=1
macaddr_acl=0
auth_algs=1
ignore_broadcast_ssid=0
wpa=2
wpa_passphrase=${AP_PASSWORD}
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
ap_max_inactivity=3600
disassoc_low_ack=0
EOF

# Generate dnsmasq config from environment
cat > /etc/dnsmasq.conf << EOF
interface=${WLAN_IFACE}
dhcp-range=10.60.10.2,10.60.10.20,255.255.255.0,24h
EOF

# Enable IP forwarding for NAT routing (WLAN -> ETH).
#
# With network_mode: host the container shares the host's network namespace, so
# /proc/sys/net is read-only unless the container is fully privileged. We try to
# set it here for the privileged case, but this MUST be enabled on the host for
# the unprivileged (cap_add) setup:
#     sudo sysctl -w net.ipv4.ip_forward=1
# (persist it in /etc/sysctl.d/99-mqtt-sniffer.conf to survive reboots).
#
# Check the current VALUE, not writability: under host networking the file is
# read-only to an unprivileged container even when the host has already set it
# to 1, so testing writability would warn about a non-problem.
if [ "$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)" = "1" ]; then
    echo "net.ipv4.ip_forward is already enabled."
elif [ -w /proc/sys/net/ipv4/ip_forward ] && echo 1 > /proc/sys/net/ipv4/ip_forward 2>/dev/null; then
    echo "Enabled net.ipv4.ip_forward inside the container."
else
    echo "WARNING: net.ipv4.ip_forward is 0 and cannot be set from here."
    echo "         NAT will NOT work until it is enabled on the host:"
    echo "             sudo sysctl -w net.ipv4.ip_forward=1"
fi

# Assign static IP to the AP interface
ip addr flush dev "${WLAN_IFACE}" 2>/dev/null || true
ip addr add 10.60.10.1/24 dev "${WLAN_IFACE}"
ip link set "${WLAN_IFACE}" up

# Set TX power
iw dev "${WLAN_IFACE}" set txpower fixed "${AP_TXPOWER}" || true

# Set up NAT so devices on the AP can reach the internet via the uplink.
# Under host networking these rules live in the HOST's tables and persist across
# container restarts, so add each only if it isn't already present (-C check)
# to avoid accumulating duplicates.
iptables -t nat -C POSTROUTING -o "${ETH_IFACE}" -j MASQUERADE 2>/dev/null \
    || iptables -t nat -A POSTROUTING -o "${ETH_IFACE}" -j MASQUERADE
iptables -C FORWARD -i "${ETH_IFACE}" -o "${WLAN_IFACE}" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null \
    || iptables -A FORWARD -i "${ETH_IFACE}" -o "${WLAN_IFACE}" -m state --state RELATED,ESTABLISHED -j ACCEPT
iptables -C FORWARD -i "${WLAN_IFACE}" -o "${ETH_IFACE}" -j ACCEPT 2>/dev/null \
    || iptables -A FORWARD -i "${WLAN_IFACE}" -o "${ETH_IFACE}" -j ACCEPT

# Start hostapd (WiFi access point)
echo "Starting hostapd..."
hostapd /etc/hostapd/hostapd.conf &
HOSTAPD_PID=$!
sleep 2
if ! kill -0 "$HOSTAPD_PID" 2>/dev/null; then
    echo "ERROR: hostapd failed to start; check the interface and config above." >&2
    exit 1
fi

# Start dnsmasq (DHCP server)
echo "Starting dnsmasq..."
dnsmasq --conf-file=/etc/dnsmasq.conf --no-daemon --log-facility=- &
DNSMASQ_PID=$!
sleep 1
if ! kill -0 "$DNSMASQ_PID" 2>/dev/null; then
    echo "ERROR: dnsmasq failed to start." >&2
    kill "$HOSTAPD_PID" 2>/dev/null || true
    exit 1
fi

# Run the packet sniffer (background so the shell can handle signals)
echo "Starting mqtt_sniffer..."
python3 /app/mqtt_sniffer.py &
SNIFFER_PID=$!

# Trap signals to cleanly shut down child processes
trap "kill $HOSTAPD_PID $DNSMASQ_PID $SNIFFER_PID 2>/dev/null; exit 0" SIGTERM SIGINT

# Exit (and let Docker restart us) if ANY of the three processes dies, rather
# than lingering as a half-broken container.
wait -n "$HOSTAPD_PID" "$DNSMASQ_PID" "$SNIFFER_PID"
echo "A managed process exited; shutting down so the container can restart." >&2
kill "$HOSTAPD_PID" "$DNSMASQ_PID" "$SNIFFER_PID" 2>/dev/null || true
exit 1
