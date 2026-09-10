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

config :zaik, :skills,
  enabled: true,
  paths: [
    if(config_env() == :test,
      do: Path.join(System.tmp_dir!(), "zaik-skills-test"),
      else: "~/.zaik/home/skills"
    )
  ],
  max_relevant: 3

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

config :zaik, :alerts,
  enabled: true,
  path:
    if(config_env() == :test,
      do: Path.join(System.tmp_dir!(), "zaik-alert-rules-test.json"),
      else: "~/.zaik/alerts/rules.json"
    ),
  default_cooldown_seconds: 900

config :zaik, :mqtt,
  enabled: true,
  host: "localhost",
  port: 1883,
  client_id: "zaik",
  topics: ["zigbee2mqtt/#"],
  handlers: [Zaik.Home.Zigbee2MQTT],
  reconnect_interval_ms: 5_000,
  connect_timeout_ms: 5_000

config :zaik, :zigbee2mqtt,
  base_topic: "zigbee2mqtt",
  device_store: Zaik.Home.DeviceStore,
  bootstrap_state?: true,
  data_dir: "~/.local/share/zigbee2mqtt/data"

config :zaik, :blinds,
  base_topic: "zigbee2mqtt",
  device_store: Zaik.Home.DeviceStore,
  preset_store: Zaik.Home.DevicePresetStore,
  mqtt_client: Zaik.MQTT.Client

config :zaik, :device_presets,
  enabled: true,
  db_path: if(config_env() == :test, do: ":memory:", else: "~/.zaik/home/home.db"),
  import_legacy_blind_presets?: true,
  legacy_blind_presets_path: "~/.zaik/home/blind_presets.json"

# Runtime-discovered modules are looked up on every use so hot-loaded modules
# and configuration changes do not require rebuilding the brain process.
config :zaik, :tools, additional_modules: []
config :zaik, :home_capabilities, additional_modules: []
config :zaik, :home_executors, additional_modules: []

config :zaik, :tool_execution, action_timeout_ms: 30_000
config :zaik, :home_action_plans, max_actions: 10

config :zaik, :home_action_verification,
  enabled: true,
  timeout_ms: 30_000,
  wait_ms: 1_500,
  retention_ms: 300_000,
  position_tolerance: 2

config :zaik, :home_action_retries,
  enabled: true,
  max_attempts: 2,
  cooldown_ms: 30_000,
  settle_ms: 5_000,
  max_state_age_ms: 120_000

config :zaik, :home_action_ledger,
  enabled: true,
  db_path: if(config_env() == :test, do: ":memory:", else: "~/.zaik/home/home.db")

config :zaik, :home_history,
  enabled: true,
  db_path: if(config_env() == :test, do: ":memory:", else: "~/.zaik/home/home.db")

# Deterministic civil-time context for home policies. When utc_offset_minutes is
# nil, production uses the host's current local offset; mirrors should inject it.
config :zaik, :home_environment,
  utc_offset_minutes: nil,
  hemisphere: "north",
  day_start_hour: 6,
  night_start_hour: 20

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
