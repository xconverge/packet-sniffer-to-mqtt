import os
import logging
import paho.mqtt.client as mqtt
import json
from scapy.layers.inet import TCP
from scapy.packet import Raw
from scapy.sendrecv import sniff
import time

# Use the stdlib logging module: this gives every line a timestamp and level
# for free, and the VERBOSE env var simply selects DEBUG vs INFO instead of
# guarding each noisy line with `if verbose`.
verbose = os.environ.get("VERBOSE", "false").lower() == "true"
logging.basicConfig(
    level=logging.DEBUG if verbose else logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
log = logging.getLogger("mqtt_sniffer")


def _require_env(name):
    value = os.environ.get(name)
    if not value:
        raise SystemExit(f"Required environment variable {name} is not set")
    return value


MQTT_BROKER = _require_env("MQTT_BROKER")
MQTT_PORT = int(_require_env("MQTT_PORT"))
TOPIC = _require_env("MQTT_TOPIC")
WLAN_IFACE = _require_env("WLAN_IFACE")

# Initialize MQTT client. paho's network loop handles reconnection on its own
# once loop_start() is running, so we only need to configure the backoff and
# make the initial connection.
mqtt_client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2)
mqtt_client.reconnect_delay_set(min_delay=1, max_delay=120)


def connect_mqtt():
    while True:
        try:
            log.info("Connecting to MQTT broker...")
            mqtt_client.connect(MQTT_BROKER, MQTT_PORT, 60)
            mqtt_client.loop_start()  # Keep connection alive (and auto-reconnect)
            log.info("Connected to MQTT broker at %s:%s", MQTT_BROKER, MQTT_PORT)
            return
        except Exception as e:
            log.warning("MQTT connection failed: %s", e)
            time.sleep(10)


connect_mqtt()

log.info("Starting on topic: %s", TOPIC)


def process_packet(packet):
    try:
        if packet.haslayer(TCP) and packet.haslayer(Raw):
            payload = packet[Raw].load

            log.debug("Raw payload: %s", payload)

            # Find the start of JSON data
            json_start_index = payload.find(b"{")

            if json_start_index != -1:
                json_payload = payload[json_start_index:]

                try:
                    decoded_payload = json_payload.decode("utf-8", errors="ignore")
                    parsed_payload = json.loads(decoded_payload)

                    log.debug(
                        "Decoded JSON payload: %s",
                        json.dumps(parsed_payload, indent=2),
                    )

                    # Extract DSN
                    dsn = parsed_payload.get("device", {}).get("dsn", "unknown")

                    # Construct topic using DSN
                    topic_per_device = f"{TOPIC}/{dsn}"

                    # Publish the original bytes as-is; we only parsed above to
                    # pull out the DSN, so there's no need to re-serialize.
                    mqtt_client.publish(topic_per_device, json_payload)
                    log.debug("Published to %s", topic_per_device)
                except (UnicodeDecodeError, json.JSONDecodeError) as e:
                    log.debug("Error decoding or parsing JSON: %s", e)
            else:
                log.debug("No JSON found in the payload.")
    except Exception as e:
        log.debug("Error processing packet: %s", e)


def start_sniffing():
    while True:
        try:
            log.info("Starting packet sniffing on %s...", WLAN_IFACE)
            sniff(
                iface=WLAN_IFACE,
                filter="tcp port 1883",
                prn=process_packet,
                store=False,
            )
        except Exception as e:
            log.error("Error in sniffing: %s", e)
            time.sleep(10)


try:
    start_sniffing()
except KeyboardInterrupt:
    log.info("Stopping script gracefully...")
    mqtt_client.loop_stop()
    mqtt_client.disconnect()
