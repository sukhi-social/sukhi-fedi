dtlv =
  System.get_env("HOSI_DTLV") ||
    "/private/tmp/claude-501/-Users-nyanrus--claude-spares-spare-WALasA/97f5f6c9-1e2f-41fc-9719-9bb419ac3841/scratchpad/dtlv-bin/dtlv"

java = "/Volumes/APFS64/jdk-temurin-21.noindex/home/jdk-21.0.13+9/Contents/Home/bin/java"

jar =
  System.get_env("HOSI_JAR") ||
    "/private/tmp/claude-501/-Users-nyanrus--claude-spares-spare-WALasA/97f5f6c9-1e2f-41fc-9719-9bb419ac3841/scratchpad/jvm-jar/datalevin-1.2.10-standalone.jar"

# HOSI_BACKEND=jvm runs everything on the JVM khana; the default is dtlv.
backend = if System.get_env("HOSI_BACKEND") == "jvm", do: [jvm: {java, jar}], else: [dtlv: dtlv]
have? = if backend[:jvm], do: File.exists?(java) and File.exists?(jar), else: File.exists?(dtlv)

Application.put_env(:sukhi_hosi, :backend, backend)

# PostgreSQL for the feeder and the markers: the PGlite that sukhi-fedi's own DB tests use (Postgres in
# WASM, over the wire protocol), started from ../pglite (server.mjs; `pnpm install` there first); without node or its packages those tests
# are left out. PGlite serves one connection to many and mixes their messages, so what needs two
# connections at once (`:concurrent_pg`) runs only against a real Postgres: HOSI_PG_PORT=5432 mix test.
real_pg = System.get_env("HOSI_PG_PORT")
pglite = Path.expand("../pglite", File.cwd!())
node = System.find_executable("node")
pg_port = if real_pg, do: String.to_integer(real_pg), else: 15_700 + :rand.uniform(200)

have_pg? =
  real_pg != nil or
    (node != nil and File.dir?(Path.join(pglite, "node_modules/@electric-sql/pglite")) and
       (
         port =
           Port.open({:spawn_executable, node}, [
             :binary,
             :exit_status,
             {:cd, pglite},
             {:env, [{~c"PGLITE_PORT", ~c"#{pg_port}"}]},
             {:args, ["server.mjs"]}
           ])

         {:os_pid, os_pid} = Port.info(port, :os_pid)
         ExUnit.after_suite(fn _ -> System.cmd("kill", [to_string(os_pid)]) end)

         Enum.any?(1..100, fn _ ->
           case :gen_tcp.connect(~c"127.0.0.1", pg_port, []) do
             {:ok, s} -> :gen_tcp.close(s) && true
             _ -> Process.sleep(100) && false
           end
         end)
       ))

# One pool for the whole run: PGlite serves one connection to many, and a pool per test leaves
# closed sockets behind that the next one trips over.
if have_pg? do
  {:ok, _} = SukhiHosi.Pg.start_link(port: pg_port, name: SpikePg)
  SukhiHosi.Pg.migrate!(SpikePg)
end

exclude =
  if(have?, do: [], else: [:needs_dtlv]) ++ if(backend[:jvm], do: [], else: [:concurrent_read]) ++
    if(have_pg?, do: [], else: [:needs_pg]) ++ if(real_pg, do: [], else: [:concurrent_pg])

ExUnit.start(exclude: exclude)

defmodule TestDb do
  @moduledoc "A database in a directory of its own; it is stopped, and waited for, before the directory goes."
  import ExUnit.Callbacks, only: [on_exit: 1]

  def dir, do: Path.join(System.tmp_dir!(), "hosi-spike-#{System.os_time(:millisecond)}-#{:rand.uniform(1_000_000)}")

  def open do
    dir = dir()
    {:ok, db} = open_at(dir)
    on_exit(fn -> close(db, dir) end)
    {db, dir}
  end

  def open_at(dir), do: SukhiHosi.Store.start_link([dir: dir] ++ Application.fetch_env!(:sukhi_hosi, :backend))

  defp close(db, dir) do
    ref = Process.monitor(db)

    try do
      Hosi.stop(db)
    catch
      :exit, _ -> :ok
    end

    receive do
      {:DOWN, ^ref, _, _, _} -> :ok
    after
      10_000 -> :ok
    end

    File.rm_rf(dir)
  end
end
