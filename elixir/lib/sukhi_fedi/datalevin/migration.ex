# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Datalevin.Migration do
  @moduledoc """
  One step that takes the data in a Datalevin store from how an older
  release left it to how this one reads it.

      defmodule SukhiFedi.Datalevin.Migrations.V20261105100000DropOldFlag do
        use SukhiFedi.Datalevin.Migration, version: 20261105100000, store: :main

        @impl true
        def up(ctx) do
          Ops.rename_attr!(ctx, :"accounts/locked", :"accounts/manually_approves")
          Ops.retract_attr!(ctx, :"accounts/legacy_flag")
        end
      end

  `mix sukhi.datalevin.gen.migration NAME` writes that skeleton.

  ## When one is needed

  The schema itself is derived (`Catalog`, `SchemaFile`), so **a new
  attribute needs no migration**: the store opens with it and rows that
  lack it read as `nil`. A migration is for what that does not cover:

    * an attribute removed or changed (`SchemaDiff.breaking/1`): its data
      has to go, move or be rewritten;
    * a value that must exist (a default for a column added `NOT NULL`);
    * a derived value that has to be filled in for old rows.

  `mix sukhi.datalevin.lock` refuses to accept a removed or changed
  attribute until a migration newer than the last lock exists.

  ## The contract

    * **Idempotent.** `up/1` can be stopped at any point (power loss, a
      timeout) and is then run again from the start, so a second run over
      half-migrated data must finish the job and change nothing else.
      `Ops` is written that way: it asks what is still to do.
    * **Single store.** `store: :main` is the Ecto-shaped database
      (`DATALEVIN_DIR`), `store: :graph` the graph (`DATALEVIN_DIR/graph`).
    * **Open with the old shape.** While `up/1` runs, the store is open with
      the schema it had *before* this release plus the new attributes, so a
      removed attribute can still be read. Say what else `up/1` needs in
      `c:schema/0`. Afterwards the store is opened with the current schema.
    * **Order.** By `version` (a timestamp, `YYYYMMDDHHMMSS`). A migration
      older than one already applied is refused, as Postgres is: rename it.
    * **Never edit a shipped migration.** Stores that ran it do not run it again.
  """

  alias SukhiFedi.Datalevin.Migration.Ctx

  @type store :: :main | :graph

  @doc "Do the work. Returns `:ok`; raise to stop."
  @callback up(Ctx.t()) :: :ok

  @doc "Attributes `up/1` touches that the current schema no longer defines, in wire form."
  @callback schema() :: %{String.t() => map()}

  @doc "One line for the journal and `status`."
  @callback description() :: String.t()

  @optional_callbacks schema: 0, description: 0

  defmacro __using__(opts) do
    version = Keyword.fetch!(opts, :version)
    store = Keyword.get(opts, :store, :main)

    unless is_integer(version) and version > 0,
      do: raise(ArgumentError, "migration version must be a positive integer, got #{inspect(version)}")

    unless store in [:main, :graph],
      do: raise(ArgumentError, "migration store must be :main or :graph, got #{inspect(store)}")

    quote do
      @behaviour SukhiFedi.Datalevin.Migration
      alias SukhiFedi.Datalevin.Migration.Ops, warn: false

      @doc false
      def __datalevin_migration__ do
        %{
          module: __MODULE__,
          version: unquote(version),
          store: unquote(store),
          description: description()
        }
      end

      @impl true
      def schema, do: %{}

      @impl true
      def description, do: __MODULE__ |> Module.split() |> List.last() |> Macro.underscore()

      defoverridable schema: 0, description: 0
    end
  end

  @doc "The module's descriptor, or `nil` when it is not a migration."
  @spec describe(module()) :: map() | nil
  def describe(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :__datalevin_migration__, 0),
      do: module.__datalevin_migration__(),
      else: nil
  end
end
