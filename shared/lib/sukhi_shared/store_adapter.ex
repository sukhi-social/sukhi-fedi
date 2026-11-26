# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiShared.StoreAdapter do
  @moduledoc """
  The `Ecto.Adapter` a repo over the store (hosigraph, through `Ecto.Adapters.Hosi`) is built with.

      use SukhiShared.StoreAdapter,
        adapter: Ecto.Adapters.Hosi,
        owner?: true

  Every call goes straight through to the adapter module, by name at runtime, so an app compiled
  without it (the delivery node, on its own) still builds.

  `owner?: true` means this repo's boot starts the store. A second repo in the same BEAM that
  reads and writes the same database (`owner?: false`, the delivery node inside a combined
  release) must not start another: give it `join: SukhiFedi.Repo` in its config and it shares
  the one already running (see `Ecto.Adapters.Hosi`).
  """

  defmacro __using__(opts) do
    datalevin = Keyword.fetch!(opts, :adapter)
    owner? = Keyword.get(opts, :owner?, true)

    quote bind_quoted: [datalevin: datalevin, owner?: owner?] do
      @behaviour Ecto.Adapter
      @behaviour Ecto.Adapter.Queryable
      @behaviour Ecto.Adapter.Schema
      @behaviour Ecto.Adapter.Transaction

      @d datalevin
      @owner owner?

      # An app that never starts the store itself need not contain its adapter.
      @compile {:no_warn_undefined, datalevin}

      # Ecto asks every adapter for this; there is no SQL to define on the repo.
      @impl Ecto.Adapter
      defmacro __before_compile__(_env), do: nil

      # No other application has to be running for the store.
      @impl Ecto.Adapter
      def ensure_all_started(_config, _type), do: {:ok, []}

      @impl Ecto.Adapter
      def init(config) do
        {:ok, spec, meta} = apply(@d, :init, [config])
        {:ok, if(@owner, do: spec, else: joined()), meta}
      end

      # The store is already running (another repo in this BEAM started it):
      # a child that starts, does nothing and is not restarted.
      defp joined do
        %{id: :joined_store, start: {Task, :start_link, [fn -> :ok end]}, restart: :temporary}
      end

      # Every call below is a dynamic one (`apply/3`), so this app need not
      # contain the store adapter to compile.
      @impl Ecto.Adapter
      def loaders(p, t), do: apply(@d, :loaders, [p, t])
      @impl Ecto.Adapter
      def dumpers(p, t), do: apply(@d, :dumpers, [p, t])
      @impl Ecto.Adapter.Schema
      def autogenerate(t), do: apply(@d, :autogenerate, [t])
      @impl Ecto.Adapter.Queryable
      def prepare(kind, q), do: apply(@d, :prepare, [kind, q])

      @impl Ecto.Adapter
      def checkout(meta, opts, fun), do: apply(@d, :checkout, [meta, opts, fun])
      @impl Ecto.Adapter
      def checked_out?(meta), do: apply(@d, :checked_out?, [meta])

      @impl Ecto.Adapter.Queryable
      def execute(meta, qm, q, params, opts), do: apply(@d, :execute, [meta, qm, q, params, opts])
      @impl Ecto.Adapter.Queryable
      def stream(meta, qm, q, params, opts), do: apply(@d, :stream, [meta, qm, q, params, opts])

      @impl Ecto.Adapter.Schema
      def insert_all(meta, sm, header, rows, oc, returning, placeholders, opts),
        do: apply(@d, :insert_all, [meta, sm, header, rows, oc, returning, placeholders, opts])

      @impl Ecto.Adapter.Schema
      def insert(meta, sm, fields, oc, returning, opts),
        do: apply(@d, :insert, [meta, sm, fields, oc, returning, opts])

      @impl Ecto.Adapter.Schema
      def update(meta, sm, fields, filters, returning, opts),
        do: apply(@d, :update, [meta, sm, fields, filters, returning, opts])

      @impl Ecto.Adapter.Schema
      def delete(meta, sm, filters, returning, opts),
        do: apply(@d, :delete, [meta, sm, filters, returning, opts])

      @impl Ecto.Adapter.Transaction
      def transaction(meta, opts, fun), do: apply(@d, :transaction, [meta, opts, fun])
      @impl Ecto.Adapter.Transaction
      def in_transaction?(meta), do: apply(@d, :in_transaction?, [meta])
      @impl Ecto.Adapter.Transaction
      def rollback(meta, value), do: apply(@d, :rollback, [meta, value])
    end
  end
end
