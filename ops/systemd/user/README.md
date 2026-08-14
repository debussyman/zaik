# Zaik user services

These user-level systemd units keep the local home-agent runtime alive:

- `zigbee2mqtt.service` runs the Zigbee2MQTT checkout from `~/.local/share/zigbee2mqtt`.
- `zaik.service` runs the Zaik OTP app with Signal ingress and MQTT home integration.

Mosquitto is expected to run as a system service on `localhost:1883`.

## Private Signal env

Create `~/.config/zaik/signal.env` with mode `0600`:

```sh
ZAIK_SIGNAL_ENABLED=true
ZAIK_SIGNAL_MODE=cli
ZAIK_SIGNAL_ACCOUNT=+15555555555
ZAIK_SIGNAL_ALLOWED_SENDERS=+15555555555
ZAIK_SIGNAL_POLL_INTERVAL_MS=5000
```

Optional overrides:

```sh
ZAIK_MQTT_HOST=localhost
ZAIK_MQTT_PORT=1883
ZAIK_ZIGBEE2MQTT_DATA_DIR=/home/ryan/.local/share/zigbee2mqtt/data
```

## Install

```sh
mkdir -p ~/.config/systemd/user
cp ops/systemd/user/zigbee2mqtt.service ~/.config/systemd/user/
cp ops/systemd/user/zaik.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now zigbee2mqtt.service
systemctl --user enable --now zaik.service
```

To start at boot without an interactive login, enable lingering:

```sh
loginctl enable-linger "$USER"
```

## Operate

```sh
systemctl --user status zigbee2mqtt.service zaik.service
journalctl --user -u zigbee2mqtt.service -f
journalctl --user -u zaik.service -f
```
