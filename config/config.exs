import Config

config :zaik,
  environment: :development

config :zaik, :watchdog,
  enabled: true,
  scan_interval_ms: 30_000,
  assigned_stale_after_ms: 10_000,
  running_stale_after_ms: 120_000,
  dispatch_after_scan?: true

config :zaik, :llm,
  provider: :ollama,
  ollama_url: "http://localhost:11434",
  default_model: "qwen3-coder:30b",
  num_ctx: 32_768,
  num_predict: 512,
  timeout_ms: 180_000,
  keep_alive: "30m",
  temperature: 0.2

config :zaik, :mqtt,
  enabled: true,
  host: "localhost",
  port: 1883,
  client_id: "zaik",
  topics: ["zigbee2mqtt/#"],
  reconnect_interval_ms: 5_000,
  connect_timeout_ms: 5_000

config :zaik, :zigbee2mqtt,
  base_topic: "zigbee2mqtt",
  device_store: Zaik.Home.DeviceStore,
  bootstrap_state?: true,
  data_dir: "~/.local/share/zigbee2mqtt/data"

config :zaik, :home_history,
  enabled: true,
  db_path: if(config_env() == :test, do: ":memory:", else: "~/.zaik/home/home.db")

config :zaik, :signal,
  enabled: false,
  mode: :cli,
  api_url: "http://localhost:8080",
  account: nil,
  allowed_senders: [],
  poll_interval_ms: 5_000,
  cli_path: "signal-cli",
  data_dir: nil
