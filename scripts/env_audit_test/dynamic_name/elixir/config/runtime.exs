import Config
name = "DYN"
config :demo, :a, System.get_env(name)
config :demo, :b, System.get_env("lowercase_is_not_an_env_var_name")
config :demo, :c, System.get_env("REAL_ONE")
