# Zaik

Zaik is a local-first personal agent harness built with Elixir/OTP. It provides a supervised task runtime, filesystem-backed session memory, Signal chat ingress, local Ollama LLM tasks, and MQTT/Zigbee2MQTT home-state integration.

## Current capabilities

- OTP supervision tree for the runtime and agents
- Dynamic supervised task execution with retry/cancel/await APIs
- In-memory task queue and task store
- Filesystem-backed session memory under `~/.zaik/sessions`
- Context building from session branches/messages
- Observability snapshots, health summaries, and watchdog reconciliation
- Signal ingress/replies via linked-device `signal-cli`
- Telegram Bot API polling for a separate bot identity and multi-user chat
- Natural-language chat routing with a small local Ollama intent model
- Local Ollama prompt tasks
- MQTT subscription to Zigbee2MQTT state
- SQLite-backed home telemetry history in `~/.zaik/home/home.db`
- Home commands for latest Zigbee2MQTT device/sensor state and trends
- User-level systemd services for long-running Zaik and Zigbee2MQTT

## Development

Enter the Nix dev shell:

```bash
nix develop
```

Run tests:

```bash
nix develop -c mix test
```

Run the app in the foreground:

```bash
nix develop -c mix run --no-halt
```

Run a one-off command processor smoke test:

```bash
nix develop -c mix run -e 'IO.puts(Zaik.CommandProcessor.process("health"))'
```

## Public Elixir API

Task harness:

```elixir
{:ok, task_id} = Zaik.submit_task(:echo, %{message: "hello"})
{:ok, result} = Zaik.await_task(task_id)
Zaik.cancel_task(task_id)
Zaik.get_task(task_id)
Zaik.list_tasks(status: :running)
Zaik.queue_size()
```

Observability:

```elixir
Zaik.snapshot()
Zaik.health()
Zaik.task_summary()
Zaik.watchdog_scan()
Zaik.watchdog_state()
```

Sessions/context:

```elixir
Zaik.create_session(scope: "local")
Zaik.list_sessions()
Zaik.get_session_context(session_id)
```

Natural chat:

```elixir
Zaik.ChatRouter.process("Is Lily's room cooling off?")
Zaik.Intent.Parser.parse("Is anyone in Lily's room?")
```

Home state:

```elixir
Zaik.home_devices()
Zaik.home_device("lily")
Zaik.presence_devices()
Zaik.home_trend("lily")
Zaik.home_readings("lily", limit: 20)
Zaik.mqtt_status()
```

## Text / messaging chat

Signal and Telegram ingress go through `Zaik.ChatRouter`: exact commands still work, and free-form messages are parsed by a small local intent model and dispatched to trusted Elixir handlers.

Telegram is the preferred multi-person chat path because Zaik appears as its own bot identity instead of speaking as your linked Signal account.

Natural-language examples:

```text
How's Lily's room?
Is Lily's room getting colder?
Has her room cooled off in the last hour?
Is anyone in Lily's room right now?
How bright is it in Lily's room?
What's going on at home?
Is Zaik healthy?
Do a watchdog scan
```

Explicit commands are still supported through `Zaik.CommandProcessor`:

```text
help
health
snapshot
queue
tasks
tasks queued|running|failed
task <task_id>
sessions
home
home devices
home sensors
home trends
presence
sensor <device name>
sensor <device name> trend
watchdog
watchdog scan
ask <prompt>
submit llm <prompt>
submit echo <message>
echo <message>
system
```

Home command examples:

```text
home
home devices
presence
sensor lily
sensor lily trend
home trends
```

LLM command example:

```text
ask summarize the current home state
```

## Runtime configuration

Main config lives in `config/config.exs`. Runtime-sensitive values should be supplied via environment variables or private local files, not committed.

### Signal

Zaik uses `signal-cli` as a linked Signal device.

Environment variables used by the service:

```sh
ZAIK_SIGNAL_ENABLED=true
ZAIK_SIGNAL_MODE=cli
ZAIK_SIGNAL_ACCOUNT=+15555555555
ZAIK_SIGNAL_ALLOWED_SENDERS=+15555555555
ZAIK_SIGNAL_POLL_INTERVAL_MS=5000
```

For the systemd service, put Signal settings in:

```text
~/.config/zaik/signal.env
```

Keep it private:

```bash
chmod 600 ~/.config/zaik/signal.env
```

### Telegram

Zaik can also run as a Telegram bot using Bot API polling. This requires no public webhook.

Create a bot:

1. Open Telegram and message `@BotFather`.
2. Run `/newbot` and follow the prompts.
3. Save the bot token.
4. Start a private chat with the bot and send any message.

The systemd service also loads this optional Telegram env file:

```text
~/.config/zaik/telegram.env
```

Example:

```sh
ZAIK_TELEGRAM_ENABLED=true
ZAIK_TELEGRAM_BOT_TOKEN=123456:replace_me
ZAIK_TELEGRAM_BOT_USERNAME=your_bot_username
ZAIK_TELEGRAM_ALLOWED_USER_IDS=111111111,222222222
ZAIK_TELEGRAM_ALLOWED_CHAT_IDS=
ZAIK_TELEGRAM_GROUP_TRIGGER=zaik
```

Keep it private:

```bash
chmod 600 ~/.config/zaik/telegram.env
```

Find your Telegram user/chat IDs from logs while testing, or use a bot like `@userinfobot`. For groups, add the bot to the group and allowlist the group chat ID. Group messages only trigger Zaik if addressed, e.g.:

```text
zaik how's Lily's room?
@your_bot_username is Lily's room cooling?
```

Private one-on-one Telegram chats do not require a trigger.

### Ollama

Defaults are configured for local Ollama:

```text
URL:          http://localhost:11434
Prompt model: qwen3-coder:30b
Intent model: qwen3:4b
```

The intent model is used only for structured routing. It returns JSON like:

```json
{
  "intent": "home_sensor_trend",
  "device_query": "lily",
  "fields": ["temperature"],
  "time_window": "last hour",
  "confidence": 0.95
}
```

Pull the intent model if needed:

```bash
ollama pull qwen3:4b
```

Important Ollama settings for the intent parser:

```text
format: json
think: false
temperature: 0
num_ctx: 2048
num_predict: 160
```

Optional environment overrides:

```sh
ZAIK_INTENT_ENABLED=true
ZAIK_INTENT_MODEL=qwen3:4b
ZAIK_INTENT_NUM_CTX=2048
ZAIK_INTENT_NUM_PREDICT=160
ZAIK_INTENT_KEEP_ALIVE=30m
```

Useful smoke test through Zaik:

```bash
nix develop -c mix run -e 'IO.puts(Zaik.CommandProcessor.process("ask say zaik ollama ok"))'
```

Intent parser smoke test:

```bash
nix develop -c mix run -e 'IO.inspect(Zaik.Intent.Parser.parse("Is Lily room cooling?"))'
```

### MQTT / Zigbee2MQTT

Zaik subscribes to Zigbee2MQTT via the Nix-provided Mosquitto CLI tools:

```text
MQTT broker: localhost:1883
Base topic:  zigbee2mqtt
```

Optional environment overrides:

```sh
ZAIK_MQTT_HOST=localhost
ZAIK_MQTT_PORT=1883
ZAIK_ZIGBEE2MQTT_DATA_DIR=/home/ryan/.local/share/zigbee2mqtt/data
ZAIK_HOME_HISTORY_DB=/home/ryan/.zaik/home/home.db
```

Zaik also bootstraps latest Zigbee2MQTT state from:

```text
~/.local/share/zigbee2mqtt/data/state.json
~/.local/share/zigbee2mqtt/data/configuration.yaml
~/.local/share/zigbee2mqtt/data/database.db
```

This makes `home`, `presence`, and `sensor ...` useful immediately after a Zaik restart even if device state MQTT messages are not retained.

### Home telemetry history

Zaik records structured sensor readings to SQLite:

```text
~/.zaik/home/home.db
```

The `readings` table stores normalized columns for common fields:

```text
temperature_c, humidity, illuminance, presence, pir_detection,
battery, voltage, linkquality, target_distance, payload_json
```

Trend commands use this history, for example:

```text
sensor lily trend
```

Example response once at least two readings exist in the recent window:

```text
Lily's room is cooling. It is now 78.8°F, down 1.8°F over 1 hour. Humidity is steady at 54%. The room is getting brighter at 200 lux, up 100 lux. Based on 2 readings over 1 hour.
```

Tests use an in-memory SQLite database by default, so test runs do not mutate the real home telemetry database.

## Runtime services

Service templates are tracked in:

```text
ops/systemd/user/
```

Installed local units:

```text
~/.config/systemd/user/zigbee2mqtt.service
~/.config/systemd/user/zaik.service
```

Mosquitto runs as a system service. Zaik and Zigbee2MQTT run as user services.

### Install / update service units

```bash
mkdir -p ~/.config/systemd/user
cp ops/systemd/user/zigbee2mqtt.service ~/.config/systemd/user/
cp ops/systemd/user/zaik.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now zigbee2mqtt.service
systemctl --user enable --now zaik.service
```

Start user services at boot before login:

```bash
sudo loginctl enable-linger "$USER"
loginctl show-user "$USER" -p Linger
```

Expected:

```text
Linger=yes
```

### Useful commands

Check service status:

```bash
systemctl --user status zigbee2mqtt.service zaik.service
systemctl status mosquitto
```

Follow logs:

```bash
journalctl --user -u zigbee2mqtt.service -f
journalctl --user -u zaik.service -f
journalctl -u mosquitto -f
```

Restart after code/config changes:

```bash
systemctl --user restart zaik.service
systemctl --user restart zigbee2mqtt.service
```

Stop/start manually:

```bash
systemctl --user stop zaik.service zigbee2mqtt.service
systemctl --user start zigbee2mqtt.service zaik.service
```

Check enabled/active state:

```bash
systemctl --user is-enabled zigbee2mqtt.service zaik.service
systemctl --user is-active zigbee2mqtt.service zaik.service
systemctl is-enabled mosquitto
systemctl is-active mosquitto
```

Inspect running processes:

```bash
ps -ef | grep -E '[m]osquitto|[z]igbee2mqtt|[p]npm start|[b]eam.smp|[m]osquitto_sub'
```

Zigbee2MQTT frontend:

```text
http://192.168.1.1:8081/
```

MQTT topic watch:

```bash
mosquitto_sub -t 'zigbee2mqtt/#' -v
```

## Project layout

```text
lib/zaik.ex                         Public API
lib/zaik/application.ex             OTP supervision tree
lib/zaik/task*.ex                   Task model/store/queue/watchdog
lib/zaik/dispatcher.ex              Dynamic task dispatcher
lib/zaik/agent/*.ex                 Task runner and workloads
lib/zaik/session*.ex                Filesystem-backed sessions
lib/zaik/context_builder.ex         Session context assembly
lib/zaik/command_processor.ex       Text/Signal command routing
lib/zaik/messaging/*.ex             Signal CLI ingress/replies
lib/zaik/llm/*.ex                   Ollama client/workload
lib/zaik/mqtt/*.ex                  MQTT subscription wrapper
lib/zaik/home/*.ex                  Zigbee2MQTT state parsing/store/bootstrap
ops/systemd/user/*.service          User service templates
```

## Git hygiene

Local development/runtime files should stay untracked:

```text
.envrc
.direnv/
~/.config/zaik/signal.env
~/.local/share/zigbee2mqtt/
```

## License

MIT License. See [LICENSE](LICENSE) for more information.
