import os
import paho.mqtt.client as mqtt
import json
import scapy.all as scapy
import time

verbose = os.environ.get("VERBOSE", "false").lower() == "true"

MQTT_BROKER = os.environ.get("MQTT_BROKER", "192.168.1.180")
MQTT_PORT = int(os.environ.get("MQTT_PORT", "1883"))
TOPIC = os.environ.get("MQTT_TOPIC", "captured")
WLAN_IFACE = os.environ.get("WLAN_IFACE", "wlan0")

# Initialize MQTT client
mqtt_client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2)


def connect_mqtt():
    while True:
        try:
            print("Connecting to MQTT broker...")
            mqtt_client.connect(MQTT_BROKER, MQTT_PORT, 60)
            mqtt_client.loop_start()  # Keep connection alive in the background
            print(f"Connected to MQTT broker at {MQTT_BROKER}:{MQTT_PORT}")
            return
        except Exception as e:
            print(f"MQTT connection failed: {e}")
            time.sleep(10)


connect_mqtt()

print(f"Starting on topic: {TOPIC}")


def process_packet(packet):
    try:
        if packet.haslayer(scapy.TCP) and packet.haslayer(scapy.Raw):
            payload = packet[scapy.Raw].load

            if verbose:
                print(f"Raw Payload: {payload}")

            # Find the start of JSON data
            json_start_index = payload.find(b"{")

            if json_start_index != -1:
                json_payload = payload[json_start_index:]

                try:
                    decoded_payload = json_payload.decode("utf-8", errors="ignore")
                    parsed_payload = json.loads(decoded_payload)

                    if verbose:
                        print(
                            f"Decoded JSON Payload: {json.dumps(parsed_payload, indent=2)}"
                        )

                    # Extract DSN
                    dsn = parsed_payload.get("device", {}).get("dsn", "unknown")

                    # Construct topic using DSN
                    topic_per_device = f"{TOPIC}/{dsn}"

                    mqtt_client.publish(topic_per_device, json.dumps(parsed_payload))
                    if verbose:
                        print(f"Published to {topic_per_device}")
                except (UnicodeDecodeError, json.JSONDecodeError) as e:
                    if verbose:
                        print(f"Error decoding or parsing JSON: {e}")
            else:
                if verbose:
                    print("No JSON found in the payload.")
    except Exception as e:
        if verbose:
            print(f"Error processing packet: {e}")


def start_sniffing():
    while True:
        try:
            print(f"Starting packet sniffing on {WLAN_IFACE}...")
            scapy.sniff(
                iface=WLAN_IFACE,
                filter="tcp port 1883",
                prn=process_packet,
                store=False,
            )
        except Exception as e:
            print(f"Error in sniffing: {e}")
            time.sleep(10)


try:
    start_sniffing()
except KeyboardInterrupt:
    print("Stopping script gracefully...")
    mqtt_client.loop_stop()
    mqtt_client.disconnect()
