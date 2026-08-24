# Zaik user services

These user-level systemd units keep the local home-agent runtime alive:

- `zigbee2mqtt.service` runs the Zigbee2MQTT checkout from `~/.local/share/zigbee2mqtt`.
- `zaik.service` runs the Zaik OTP app with Telegram/optional Signal ingress and MQTT home integration.

Mosquitto is expected to run as a system service on `localhost:1883`.

## Private env files

Create private env files under `~/.config/zaik/` with mode `0600`. See `examples/env/*.env.example` for templates.

Optional legacy Signal example:

```sh
ZAIK_SIGNAL_ENABLED=true
ZAIK_SIGNAL_MODE=cli
ZAIK_SIGNAL_ACCOUNT=+15555555555
ZAIK_SIGNAL_ALLOWED_SENDERS=+15555555555
ZAIK_SIGNAL_POLL_INTERVAL_MS=5000
```

Optional Telegram/home/LLM overrides:

```sh
ZAIK_TELEGRAM_ENABLED=false
ZAIK_TELEGRAM_BOT_TOKEN=123456:replace_me
ZAIK_TELEGRAM_BOT_USERNAME=your_bot_username
ZAIK_TELEGRAM_ALLOWED_USER_IDS=111111111,222222222
ZAIK_TELEGRAM_ALLOWED_CHAT_IDS=
ZAIK_TELEGRAM_REQUIRE_DIRECT_ADDRESSING=false
ZAIK_TELEGRAM_GROUP_TRIGGER=zaik
ZAIK_TELEMETRY_ENABLED=true
ZAIK_TELEMETRY_DB=$HOME/.zaik/zaik.db
ZAIK_AGENT_CHAT_ENABLED=true
ZAIK_AGENT_MODEL=qwen3:4b-instruct
ZAIK_AGENT_FALLBACK_ENABLED=true
ZAIK_AGENT_FALLBACK_MODEL=qwen3.8:27b
ZAIK_AGENT_NUM_PREDICT=900
ZAIK_AGENT_TEMPERATURE=0
ZAIK_AGENT_MAX_TOOL_CALLS=3
ZAIK_MQTT_HOST=localhost
ZAIK_MQTT_PORT=1883
ZAIK_ZIGBEE2MQTT_DATA_DIR=$HOME/.local/share/zigbee2mqtt/data
ZAIK_HOME_HISTORY_DB=$HOME/.zaik/home/home.db
ZAIK_ALERTS_ENABLED=true
ZAIK_ALERTS_PATH=$HOME/.zaik/alerts/rules.json
ZAIK_ALERT_DEFAULT_COOLDOWN_SECONDS=900
ZAIK_LLM_PROVIDER=ollama
ZAIK_OLLAMA_URL=http://127.0.0.1:11434
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
