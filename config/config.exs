import Config

config :logger,
  backends: [:console],
  utc_log: true,
  level: if(config_env() == :prod, do: :info, else: :debug),
  compile_time_purge_matching: [
    [level_lower_than: if(config_env() == :prod, do: :info, else: :debug)]
  ],
  truncate: 4096

config :logger, :console,
  metadata: [
    :registered_name,
    :mfa,
    :pid,
    :line,
    :crash_reason,
    :data
  ],
  format: "[$level] $metadata msg=$message\n"
