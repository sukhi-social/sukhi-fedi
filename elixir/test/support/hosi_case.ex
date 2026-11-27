# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.HosiCase do
  @moduledoc """
  Tests of the data layer on the hosi store (docs/STORE.md): only the Repo is
  started, on a real hosigraph in a temporary directory. Needs JDK 21+ and
  the Datalevin standalone jar:

      HOSI_JAR=/path/to/datalevin-standalone.jar mix test --no-start test/hosi

  `--no-start` matters: the application would start the Repo on Postgres
  first. Without `HOSI_JAR` these tests are excluded (see test_helper.exs).
  """

  use ExUnit.CaseTemplate

  alias SukhiFedi.{Repo, Schema}

  using do
    quote do
      import SukhiFedi.HosiCase
      alias SukhiFedi.Repo
      @moduletag :hosi
    end
  end

  setup_all do
    {:ok, _} = Application.ensure_all_started(:ecto)
    Application.put_env(:sukhi_fedi, :domain, "example.test")

    dir = Path.join(System.tmp_dir!(), "sukhi_hosi_#{System.unique_integer([:positive])}")
    jar = System.fetch_env!("HOSI_JAR")

    Application.put_env(:sukhi_fedi, Repo,
      dir: dir,
      open: %{config: %{khana: [:jvm, System.get_env("HOSI_JAVA", "java"), jar]}}
    )

    {:ok, _} = start_supervised(Repo)
    on_exit(fn -> File.rm_rf(dir) end)
    :ok
  end

  setup do
    SukhiFedi.Store.Hosi.wipe!()
    :ok
  end

  @doc """
  A local account to hang store rows on. Accounts are not in the store (it
  only keeps their ids), so this is the struct alone.
  """
  def account!(username \\ "ada") do
    %Schema.Account{id: System.unique_integer([:positive]), username: username}
  end
end
