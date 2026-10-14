import Config
if config_env() == :prod do
  config :demo, Oban,
    queues: [
      monitor: String.to_integer(System.get_env("OBAN_MONITOR_CONCURRENCY", "5")),
      publish: String.to_integer(System.get_env("OBAN_PUBLISH_CONCURRENCY", "9")),
      preview:
        String.to_integer(System.get_env("OBAN_PREVIEW_CONCURRENCY", "3"))
    ]
end
