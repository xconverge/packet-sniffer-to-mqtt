FROM python:3.13-slim

# Install system dependencies:
#   hostapd  - WiFi access point daemon
#   dnsmasq  - DHCP server for wlan0 clients
#   iptables - NAT forwarding rules
#   iproute2 - ip addr / ip link commands
#   iw       - regulatory domain and TX power control
#   libpcap-dev - required by scapy for packet capture
RUN apt-get update && apt-get install -y --no-install-recommends \
        hostapd \
        dnsmasq \
        iptables \
        iproute2 \
        iw \
        libpcap-dev \
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

ENTRYPOINT ["/entrypoint.sh"]
