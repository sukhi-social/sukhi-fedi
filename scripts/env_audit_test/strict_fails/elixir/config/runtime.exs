import Config
config :demo, :a, System.get_env("ALPHA_KEY", "x")
config :demo, :b, System.fetch_env!("BETA_KEY")
config :demo, :c, String.to_integer(System.get_env("GAMMA_PORT", "1"))
