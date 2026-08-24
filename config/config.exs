import Config

config :zaik,
  environment: :development

# Optional task type extensions. Built-in defaults are provided by Zaik.TaskResolver.
# Example:
# config :zaik, :task_modules,
#   custom_task: MyApp.CustomTask
config :zaik, :task_modules, []

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

config :zaik, :llama_cpp,
  base_url: "http://localhost:8080",
  default_model: "local-model",
  num_predict: 512,
  timeout_ms: 180_000,
  temperature: 0.2

config :zaik, :intent,
  enabled: true,
  provider: :ollama,
  model: "qwen3:4b",
  num_ctx: 2048,
  num_predict: 160,
  timeout_ms: 30_000,
  keep_alive: "30m",
  temperature: 0.0,
  confidence_threshold: 0.4

config :zaik, :agent_chat,
  enabled: true,
  model: "qwen3:4b-instruct",
  fallback_enabled: true,
  fallback_model: "qwen3-coder:30b",
  num_ctx: 4096,
  num_predict: 900,
  timeout_ms: 45_000,
  keep_alive: "30m",
  temperature: 0.0,
  max_tool_calls: 3

config :zaik, :self_improvement,
  candidate_model: "qwen3:4b-instruct",
  reference_model: "qwen3-coder:30b",
  timeout_ms: 120_000,
  notify_telegram_chat_id: nil

config :zaik, :scheduler,
  enabled: config_env() != :test,
  jobs: [
    %{
      name: :agent_chat_self_improvement,
      module: Zaik.AgentChat.SelfImprovementJob,
      schedule: {:daily, "03:00:00"},
      enabled:
        System.get_env("ZAIK_SELF_IMPROVEMENT_ENABLED")
        |> to_string()
        |> String.downcase()
        |> then(&(&1 in ["1", "true", "yes", "on"])),
      opts: []
    }
  ]

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

config :zaik, :telemetry_store,
  enabled: true,
  db_path: if(config_env() == :test, do: ":memory:", else: "~/.zaik/zaik.db")

config :zaik, :signal,
  enabled: false,
  mode: :cli,
  api_url: "http://localhost:8080",
  account: nil,
  allowed_senders: [],
  poll_interval_ms: 5_000,
  cli_path: "signal-cli",
  data_dir: nil

config :zaik, :telegram,
  enabled: false,
  bot_token: nil,
  bot_username: nil,
  api_url: "https://api.telegram.org",
  allowed_user_ids: [],
  allowed_chat_ids: [],
  poll_interval_ms: 1_000,
  long_poll_timeout_seconds: 10,
  require_direct_addressing: false,
  group_trigger: "zaik"
