# SPDX-License-Identifier: AGPL-3.0-or-later
Code.require_file("datalevin_port.ex", __DIR__)
dtlv = System.fetch_env!("DTLV")
dir = System.fetch_env!("DB_DIR")
{:ok, _} = DatalevinPort.start_link(dtlv: dtlv, name: DatalevinPort)
{:ok, %{"database" => db}} = DatalevinPort.tool("open_database", %{
  "dir" => dir, "create" => true,
  "schema" => %{
    ":job/id" => %{":db/valueType" => ":db.type/long", ":db/unique" => ":db.unique/identity"},
    ":job/host" => %{":db/valueType" => ":db.type/long"},
    ":job/state" => %{":db/valueType" => ":db.type/keyword"}}})
IO.inspect(db, label: "db handle")
IO.inspect(DatalevinPort.tool("transact", %{"database" => db,
  "txData" => [%{":job/id" => 1, ":job/host" => 7, ":job/state" => ":available"}]}), label: "transact")
IO.inspect(DatalevinPort.tool("query", %{"database" => db,
  "query" => "[:find ?id ?h :where [?e :job/id ?id] [?e :job/host ?h] [?e :job/state :available]]"}), label: "query")
