FROM python:3.13-slim

# Install system dependencies:
#   hostapd  - WiFi access point daemon
#   dnsmasq  - DHCP server for wlan0 clients
#   iptables - NAT forwarding rules
#   iproute2 - ip addr / ip link commands
#   iw       - regulatory domain and TX power control
#
# scapy captures via native AF_PACKET sockets, but it still needs libpcap to
# COMPILE the BPF filter string ("tcp port 1883"). We install only the runtime
# library (libpcap0.8t64), not the -dev headers, which keeps the image small.
RUN apt-get update && apt-get install -y --no-install-recommends \
        hostapd \
        dnsmasq \
        iptables \
        iproute2 \
        iw \
        libpcap0.8t64 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Install Python dependencies first (better layer caching)
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy application files
COPY mqtt_sniffer.py .
COPY entrypoint.sh /entrypoint.sh

# Create directories for dynamically generated configs
RUN mkdir -p /etc/hostapd

RUN chmod +x /entrypoint.sh

# Consider the container healthy only while the access point daemon is running.
# Checks /proc directly (grep is in the base image) to avoid pulling in procps.
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD grep -qx hostapd /proc/[0-9]*/comm || exit 1

ENTRYPOINT ["/entrypoint.sh"]
