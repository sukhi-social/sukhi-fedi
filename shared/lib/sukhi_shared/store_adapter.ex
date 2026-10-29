# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiShared.StoreAdapter do
  @moduledoc """
  The `Ecto.Adapter` that a repo is built with when its store is chosen at
  boot (`SUKHI_STORE`), not at compile time: the release is built once.

      use SukhiShared.StoreAdapter,
        app: :sukhi_fedi,
        datalevin: SukhiFedi.Datalevin.Adapter,
        owner?: true

  For every callback the generated module asks which store this node uses
  (`config app, :store`, `:postgres` by default) and hands the call to
  `Ecto.Adapters.Postgres` or to the Datalevin adapter. Postgres calls pass
  through untouched, so with the default store it changes nothing. The
  repo's own metadata carries `:store`, so calls that arrive with it route on
  it; the few that arrive without (type loaders and dumpers, `prepare/2`)
  route on the global setting, which is the same value for the life of the
  node.

  The Datalevin adapter lives in the gateway app (`elixir/`) and is called
  by name at runtime, so an app that never selects Datalevin (the delivery
  node on Postgres) compiles and runs without it.

  `owner?: true` means this repo's boot starts the Datalevin processes (the
  `dtlv` child, the writer lock). A second repo in the same BEAM that reads
  and writes the same database (`owner?: false`, the delivery node inside a
  combined release) must not start another: it joins the one already running.
  """

  defmacro __using__(opts) do
    app = Keyword.fetch!(opts, :app)
    datalevin = Keyword.fetch!(opts, :datalevin)
    owner? = Keyword.get(opts, :owner?, true)

    quote bind_quoted: [app: app, datalevin: datalevin, owner?: owner?] do
      @behaviour Ecto.Adapter
      @behaviour Ecto.Adapter.Queryable
      @behaviour Ecto.Adapter.Schema
      @behaviour Ecto.Adapter.Transaction
      @behaviour Ecto.Adapter.Migration
      @behaviour Ecto.Adapter.Storage

      @app app
      @d datalevin
      @owner owner?
      @pg Ecto.Adapters.Postgres

      # What `use Ecto.Adapters.SQL` would have defined on the repo (`query/3` …).
      @impl Ecto.Adapter
      defmacro __before_compile__(env), do: Ecto.Adapters.SQL.__before_compile__(:postgres, env)

      @doc "`:postgres` or `:datalevin`, as this node was configured."
      def kind, do: Application.get_env(@app, :store, :postgres)

      # Routed on the global setting: no adapter metadata in hand.
      @impl Ecto.Adapter
      def ensure_all_started(config, type), do: @pg.ensure_all_started(config, type)

      @impl Ecto.Adapter
      def init(config) do
        case kind() do
          :datalevin ->
            {:ok, spec, meta} = apply(@d, :init, [config])
            {:ok, if(@owner, do: spec, else: joined()), meta}

          :postgres ->
            @pg.init(config)
        end
      end

      # The store is already running (another repo in this BEAM started it):
      # a child that starts, does nothing and is not restarted.
      defp joined do
        %{id: :joined_store, start: {Task, :start_link, [fn -> :ok end]}, restart: :temporary}
      end

      @impl Ecto.Adapter
      def loaders(p, t), do: impl().loaders(p, t)
      @impl Ecto.Adapter
      def dumpers(p, t), do: impl().dumpers(p, t)
      @impl Ecto.Adapter.Schema
      def autogenerate(t), do: impl().autogenerate(t)
      @impl Ecto.Adapter.Queryable
      def prepare(kind, q), do: impl().prepare(kind, q)

      # Routed on the repo's metadata.
      @impl Ecto.Adapter
      def checkout(meta, opts, fun), do: impl(meta).checkout(meta, opts, fun)
      @impl Ecto.Adapter
      def checked_out?(meta), do: impl(meta).checked_out?(meta)

      @impl Ecto.Adapter.Queryable
      def execute(meta, qm, q, params, opts), do: impl(meta).execute(meta, qm, q, params, opts)
      @impl Ecto.Adapter.Queryable
      def stream(meta, qm, q, params, opts), do: impl(meta).stream(meta, qm, q, params, opts)

      @impl Ecto.Adapter.Schema
      def insert_all(meta, sm, header, rows, oc, returning, placeholders, opts),
        do: impl(meta).insert_all(meta, sm, header, rows, oc, returning, placeholders, opts)

      @impl Ecto.Adapter.Schema
      def insert(meta, sm, fields, oc, returning, opts),
        do: impl(meta).insert(meta, sm, fields, oc, returning, opts)

      @impl Ecto.Adapter.Schema
      def update(meta, sm, fields, filters, returning, opts),
        do: impl(meta).update(meta, sm, fields, filters, returning, opts)

      @impl Ecto.Adapter.Schema
      def delete(meta, sm, filters, returning, opts),
        do: impl(meta).delete(meta, sm, filters, returning, opts)

      @impl Ecto.Adapter.Transaction
      def transaction(meta, opts, fun), do: impl(meta).transaction(meta, opts, fun)
      @impl Ecto.Adapter.Transaction
      def in_transaction?(meta), do: impl(meta).in_transaction?(meta)
      @impl Ecto.Adapter.Transaction
      def rollback(meta, value), do: impl(meta).rollback(meta, value)

      # Migrations and storage exist only for Postgres; the Datalevin schema is
      # derived (priv/datalevin/catalog.exs), not migrated.
      @impl Ecto.Adapter.Migration
      def supports_ddl_transaction?, do: @pg.supports_ddl_transaction?()
      @impl Ecto.Adapter.Migration
      def execute_ddl(meta, definition, opts), do: @pg.execute_ddl(meta, definition, opts)
      @impl Ecto.Adapter.Migration
      def lock_for_migrations(meta, opts, fun), do: @pg.lock_for_migrations(meta, opts, fun)

      @impl Ecto.Adapter.Storage
      def storage_up(opts), do: @pg.storage_up(opts)
      @impl Ecto.Adapter.Storage
      def storage_down(opts), do: @pg.storage_down(opts)
      @impl Ecto.Adapter.Storage
      def storage_status(opts), do: @pg.storage_status(opts)

      # `impl/0,1` return the module, so every call above is a dynamic one: this
      # app need not contain the Datalevin adapter to compile.
      defp impl, do: if(kind() == :datalevin, do: @d, else: @pg)
      defp impl(%{store: :datalevin}), do: @d
      defp impl(_), do: @pg
    end
  end
end
