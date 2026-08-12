import Config

config :zaik,
  environment: :development

config :zaik, :watchdog,
  enabled: true,
  scan_interval_ms: 30_000,
  assigned_stale_after_ms: 10_000,
  running_stale_after_ms: 120_000,
  dispatch_after_scan?: true

config :zaik, :signal,
  enabled: false,
  mode: :cli,
  api_url: "http://localhost:8080",
  account: nil,
  allowed_senders: [],
  poll_interval_ms: 5_000,
  cli_path: "signal-cli",
  data_dir: nil
