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
ZAIK_HOME_HISTORY_DB=/home/ryan/.zaik/home/home.db
```

## Install / update

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
sudo loginctl enable-linger "$USER"
loginctl show-user "$USER" -p Linger
```

Expected:

```text
Linger=yes
```

## Useful commands

Check service status:

```sh
systemctl --user status zigbee2mqtt.service zaik.service
systemctl status mosquitto
```

Follow logs:

```sh
journalctl --user -u zigbee2mqtt.service -f
journalctl --user -u zaik.service -f
journalctl -u mosquitto -f
```

Restart after code/config changes:

```sh
systemctl --user restart zaik.service
systemctl --user restart zigbee2mqtt.service
```

Stop/start manually:

```sh
systemctl --user stop zaik.service zigbee2mqtt.service
systemctl --user start zigbee2mqtt.service zaik.service
```

Check enabled/active state:

```sh
systemctl --user is-enabled zigbee2mqtt.service zaik.service
systemctl --user is-active zigbee2mqtt.service zaik.service
systemctl is-enabled mosquitto
systemctl is-active mosquitto
```

Inspect relevant processes:

```sh
ps -ef | grep -E '[m]osquitto|[z]igbee2mqtt|[p]npm start|[b]eam.smp|[m]osquitto_sub'
```

Watch raw Zigbee2MQTT topics:

```sh
mosquitto_sub -t 'zigbee2mqtt/#' -v
```
