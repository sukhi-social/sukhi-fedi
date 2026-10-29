# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Store.Adapter do
  @moduledoc """
  The `Ecto.Adapter` that `SukhiFedi.Repo` is built with. It owns no behaviour
  of its own: for every callback it asks `SukhiFedi.Store.kind/0` and hands
  the call to `Ecto.Adapters.Postgres` or to `SukhiFedi.Datalevin.Adapter`.

  That is what lets `SUKHI_STORE` be a runtime switch rather than a compile-time
  one: the release is built once. The repo's own metadata carries `:store`, so
  calls that arrive with it route on it; the few that arrive without (type
  loaders and dumpers, `prepare/2`) route on the global setting, which is the
  same value for the life of the node.

  Postgres calls pass through untouched, so with the default store this module
  changes nothing about how the repo behaves.
  """

  @behaviour Ecto.Adapter
  @behaviour Ecto.Adapter.Queryable
  @behaviour Ecto.Adapter.Schema
  @behaviour Ecto.Adapter.Transaction
  @behaviour Ecto.Adapter.Migration
  @behaviour Ecto.Adapter.Storage

  alias SukhiFedi.Datalevin.Adapter, as: D
  alias SukhiFedi.Store

  @pg Ecto.Adapters.Postgres

  # What `use Ecto.Adapters.SQL` would have defined on the repo (`query/3` …).
  @impl Ecto.Adapter
  defmacro __before_compile__(env), do: Ecto.Adapters.SQL.__before_compile__(:postgres, env)

  # Routed on the global setting: no adapter metadata in hand.
  @impl Ecto.Adapter
  def ensure_all_started(config, type), do: @pg.ensure_all_started(config, type)

  @impl Ecto.Adapter
  def init(config) do
    case Store.kind() do
      :datalevin -> D.init(config)
      :postgres -> @pg.init(config)
    end
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

  defp impl, do: if(Store.datalevin?(), do: D, else: @pg)
  defp impl(%{store: :datalevin}), do: D
  defp impl(_), do: @pg
end
