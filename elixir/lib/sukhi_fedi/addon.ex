# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Addon do
  @moduledoc """
  Behaviour for gateway addon modules.

  An addon is a toggleable feature bundle (supervision children, NATS
  subscriptions, migrations). Discovery is via a persistent module
  attribute — no explicit wiring needed (`SukhiFedi.Addon.Registry`).

  ## Authoring

      defmodule SukhiFedi.Addons.Streaming do
        use SukhiFedi.Addon, id: :streaming

        @impl true
        def supervision_children,
          do: [SukhiFedi.Addons.Streaming.Registry, SukhiFedi.Addons.Streaming.NatsListener]
      end

  All callbacks except `id/0` have sensible defaults; override only what
  the addon actually contributes.

  ## ABI

  `abi_version/0` declares the core contract version the addon was built
  against. Major-version mismatch with the running core is a boot-time
  failure — see `SukhiFedi.Addon.Registry.verify_abi!/0`.
  """

  @type id :: atom()
  @type subject :: String.t()
  @type nats_sub :: {subject(), {module(), atom()}}

  @callback id() :: id()
  @callback abi_version() :: String.t()
  @callback depends_on() :: [id()]
  @callback supervision_children() :: [Supervisor.child_spec() | module() | {module(), term()}]
  @callback nats_subscriptions() :: [nats_sub()]
  @callback env_schema() :: [{atom(), :required | :optional, String.t()}]

  defmacro __using__(opts) do
    id = Keyword.fetch!(opts, :id)
    abi = Keyword.get(opts, :abi_version, "1.0")

    quote do
      @behaviour SukhiFedi.Addon
      Module.register_attribute(__MODULE__, :sukhi_fedi_addon, persist: true)
      @sukhi_fedi_addon true

      @impl true
      def id, do: unquote(id)

      @impl true
      def abi_version, do: unquote(abi)

      @impl true
      def depends_on, do: []

      @impl true
      def supervision_children, do: []

      @impl true
      def nats_subscriptions, do: []

      @impl true
      def env_schema, do: []

      defoverridable id: 0,
                     abi_version: 0,
                     depends_on: 0,
                     supervision_children: 0,
                     nats_subscriptions: 0,
                     env_schema: 0
    end
  end
end
