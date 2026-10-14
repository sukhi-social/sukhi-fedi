import Config
config :demo, Oban,
  queues: [
    monitor: 5,
    publish: 5,
    preview: 3
  ]
