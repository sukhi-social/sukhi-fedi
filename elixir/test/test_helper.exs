dtlv = System.get_env("DATALEVIN_BIN", "dtlv")
skip = if System.find_executable(dtlv), do: [], else: [:dtlv]

ExUnit.start(exclude: [:integration | skip])
