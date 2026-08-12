import Config

config :zaik,
  environment: :development

config :zaik, :signal,
  enabled: false,
  mode: :cli,
  api_url: "http://localhost:8080",
  account: nil,
  allowed_senders: [],
  poll_interval_ms: 5_000,
  cli_path: "signal-cli",
  data_dir: nil
