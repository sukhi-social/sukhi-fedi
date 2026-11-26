dtlv = System.get_env("DATALEVIN_BIN", "dtlv")
skip = if System.find_executable(dtlv), do: [], else: [:dtlv]

# test/hosi needs a Datalevin jar and `mix test --no-start` (SukhiFedi.HosiCase).
hosi = if System.get_env("HOSI_JAR"), do: [], else: [:hosi]

ExUnit.start(exclude: [:integration | skip ++ hosi])
