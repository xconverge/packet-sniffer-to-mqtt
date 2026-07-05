#!/bin/bash
set -e

WLAN_IFACE="${WLAN_IFACE:-wlan0}"
ETH_IFACE="${ETH_IFACE:-$(ip route show default | awk '/default/ {print $5; exit}')}"
AP_SSID="${AP_SSID:-ap_ssid}"
AP_PASSWORD="${AP_PASSWORD:-ap_password}"

echo "Using uplink interface: ${ETH_IFACE}"

# Generate hostapd config from environment
cat > /etc/hostapd/hostapd.conf << EOF
interface=${WLAN_IFACE}
driver=nl80211
ssid=${AP_SSID}
hw_mode=g
channel=7
wmm_enabled=0
macaddr_acl=0
auth_algs=1
ignore_broadcast_ssid=0
wpa=2
wpa_passphrase=${AP_PASSWORD}
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
EOF

# Generate dnsmasq config from environment
cat > /etc/dnsmasq.conf << EOF
interface=${WLAN_IFACE}
dhcp-range=10.60.10.2,10.60.10.20,255.255.255.0,24h
EOF

# Enable IP forwarding for NAT routing (WLAN -> ETH)
echo 1 > /proc/sys/net/ipv4/ip_forward

# Assign static IP to the AP interface
ip addr flush dev "${WLAN_IFACE}" 2>/dev/null || true
ip addr add 10.60.10.1/24 dev "${WLAN_IFACE}"
ip link set "${WLAN_IFACE}" up

# Set up NAT so devices on the AP can reach the internet via the uplink
iptables -t nat -A POSTROUTING -o "${ETH_IFACE}" -j MASQUERADE
iptables -A FORWARD -i "${ETH_IFACE}" -o "${WLAN_IFACE}" -m state --state RELATED,ESTABLISHED -j ACCEPT
iptables -A FORWARD -i "${WLAN_IFACE}" -o "${ETH_IFACE}" -j ACCEPT

# Start hostapd (WiFi access point)
echo "Starting hostapd..."
hostapd /etc/hostapd/hostapd.conf &
HOSTAPD_PID=$!
sleep 2

# Start dnsmasq (DHCP server)
echo "Starting dnsmasq..."
dnsmasq --conf-file=/etc/dnsmasq.conf --no-daemon --log-facility=- &
DNSMASQ_PID=$!
sleep 1

# Trap signals to cleanly shut down child processes
trap "kill $HOSTAPD_PID $DNSMASQ_PID 2>/dev/null; exit 0" SIGTERM SIGINT

# Run the packet sniffer (foreground)
echo "Starting mqtt_sniffer..."
exec python3 /app/mqtt_sniffer.py
