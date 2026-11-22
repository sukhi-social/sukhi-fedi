# SPDX-License-Identifier: AGPL-3.0-or-later
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

# PostgreSQL for the feeder and the markers: a throwaway pgrust server (a PostgreSQL-compatible
# binary; scripts/pgrust-serve.sh at the repo root fetches it the first time and runs it on this
# port). If it does not come up, the tests that need it are left out and a line says why.
# HOSI_PG_PORT=5432 uses a Postgres you already have instead (database HOSI_PG_DB).
real_pg = System.get_env("HOSI_PG_PORT")
pg_port = if real_pg, do: String.to_integer(real_pg), else: 15_700 + :rand.uniform(200)

defmodule PgrustServer do
  @moduledoc "scripts/pgrust-serve.sh as a child of the test run; it is stopped, and waited for, when the suite ends."

  # The first run fetches pgrust (about 30 MB), so waiting is generous; it stops as soon as the script has ended.
  @tries 900

  def start(port_number) do
    serve = Path.expand("../scripts/pgrust-serve.sh", File.cwd!())
    bash = System.find_executable("bash")

    cond do
      bash == nil -> {false, "no bash on the PATH"}
      not File.exists?(serve) -> {false, "#{serve} is missing"}
      true -> run(bash, serve, port_number)
    end
  end

  defp run(bash, serve, port_number) do
    port =
      Port.open({:spawn_executable, bash}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:args, [serve, to_string(port_number)]}
      ])

    {:os_pid, os_pid} = Port.info(port, :os_pid)

    ExUnit.after_suite(fn _ ->
      System.cmd("kill", [to_string(os_pid)])
      # it stops the server and removes the cluster; let it, before the VM goes
      Enum.any?(1..50, fn _ ->
        {_, status} = System.cmd("kill", ["-0", to_string(os_pid)], stderr_to_stdout: true)
        status != 0 or (Process.sleep(100) && false)
      end)
    end)

    wait(port, port_number, [], @tries)
  end

  defp wait(_port, _n, out, 0), do: {false, "did not come up in time\n" <> IO.iodata_to_binary(Enum.reverse(out))}

  defp wait(port, n, out, tries) do
    receive do
      {^port, {:data, data}} ->
        wait(port, n, [data | out], tries)

      {^port, {:exit_status, status}} ->
        {false, "the script ended (#{status})\n" <> IO.iodata_to_binary(Enum.reverse(out))}
    after
      0 ->
        case :gen_tcp.connect(~c"127.0.0.1", n, []) do
          {:ok, s} ->
            :gen_tcp.close(s)
            {true, ""}

          _ ->
            Process.sleep(200)
            wait(port, n, out, tries - 1)
        end
    end
  end
end

have_pg? =
  if real_pg do
    true
  else
    {ok?, why} = PgrustServer.start(pg_port)
    if not ok?, do: IO.puts(:stderr, "pgrust did not start, so the tests that need PostgreSQL are left out: " <> why)
    ok?
  end

# One pool for the whole run.
if have_pg? do
  {:ok, _} = SukhiHosi.Pg.start_link(port: pg_port, name: SpikePg)
  SukhiHosi.Pg.migrate!(SpikePg)
end

exclude =
  if(have?, do: [], else: [:needs_dtlv]) ++ if(backend[:jvm], do: [], else: [:concurrent_read]) ++
    if(have_pg?, do: [], else: [:needs_pg])

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
