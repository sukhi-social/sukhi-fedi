import Config
config :demo, Oban,
  queues: [
    monitor: String.to_integer(System.get_env("OBAN_MONITOR_CONCURRENCY", "5"))
  ]
