# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Web.Upstreams.Registry do
  @moduledoc """
  Keeps `SukhiFedi.Web.Upstreams`' table fresh.

  Reads `WEB_UPSTREAMS` / `WEB_ROUTES` once at boot, then fetches each
  upstream's `/.sukhi/web.json` and rebuilds the table. Compiling happens
  here, once per refresh; a request only reads the result.

  **A web that stops answering keeps its last good claims.** An upstream
  being down is a 503 for its pages (`Proxy`), not a hole that lets the
  next claimant, or the SPA shell, answer in its place. Until an upstream
  has answered once, it claims nothing and the next try comes quickly.

  Off (`:ignore`) when `WEB_UPSTREAMS` is unset — nothing changes then.
  """

  use GenServer
  require Logger

  alias SukhiFedi.Web.Upstreams

  @refresh_ms 30_000
  @retry_ms 3_000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Fetch now and wait (boot, tests, an operator's `rpc`)."
  def refresh, do: GenServer.call(__MODULE__, :refresh, 15_000)

  @impl true
  def init(opts) do
    config = SukhiShared.InstanceConfig.load()

    urls = Keyword.get(opts, :upstreams, SukhiShared.InstanceConfig.active_frontends(config))

    if map_size(urls) == 0 do
      :ignore
    else
      routes =
        Keyword.get_lazy(opts, :routes, fn ->
          config
          |> SukhiShared.InstanceConfig.routes()
          |> Enum.filter(fn row ->
            [_, frontend] = String.split(row, "=", parts: 2)
            Map.has_key?(urls, frontend)
          end)
          |> Enum.join(",")
          |> Upstreams.parse_routes()
        end)

      check_config(urls, routes)

      state = %{
        urls: urls,
        routes: routes,
        known: %{},
        refresh_ms: Keyword.get(opts, :refresh_ms, @refresh_ms),
        retry_ms: Keyword.get(opts, :retry_ms, @retry_ms)
      }

      {:ok, state, {:continue, :load}}
    end
  end

  @impl true
  def handle_continue(:load, state), do: {:noreply, load(state)}

  @impl true
  def handle_call(:refresh, _from, state) do
    state = load(state)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:tick, state), do: {:noreply, load(state)}

  defp load(state) do
    known =
      for {name, url} <- state.urls, into: %{} do
        {name, fetch(name, url, state.known[name])}
      end

    Upstreams.put(%{
      upstreams: known |> Enum.reject(fn {_, v} -> is_nil(v) end) |> Map.new(),
      routes: state.routes
    })

    pending? = Enum.any?(known, fn {_, v} -> is_nil(v) end)
    Process.send_after(self(), :tick, if(pending?, do: state.retry_ms, else: state.refresh_ms))
    %{state | known: known}
  end

  # An upstream with no answer yet is simply absent from the table.
  defp fetch(name, url, previous) do
    req = Finch.build(:get, url <> "/.sukhi/web.json")

    with {:ok, %Finch.Response{status: 200, body: body}} <-
           Finch.request(req, SukhiFedi.Finch, receive_timeout: 5_000),
         {:ok, parsed} <- Upstreams.parse_manifest(body) do
      Map.merge(%{name: name, url: url}, parsed)
    else
      other ->
        Logger.warning(
          "web upstream #{name}: no usable web.json (#{inspect(summary(other))})" <>
            if(previous, do: "; keeping the last one", else: "") <>
            "; check the configured URL #{url} and run " <>
            "`podman exec <gateway-container> wget -S -O - #{url}/.sukhi/web.json` " <>
            "as the sukhi user; existing data is untouched"
        )

        previous
    end
  rescue
    e ->
      Logger.warning(
        "web upstream #{name}: #{Exception.message(e)}; " <>
          "check URL #{url} as the sukhi user; existing data is untouched"
      )

      previous
  end

  defp summary({:ok, %Finch.Response{status: s}}), do: {:status, s}
  defp summary({:error, e}), do: e
  defp summary(other), do: other

  defp check_config(urls, routes) do
    for {_pat, name} <- routes, not Map.has_key?(urls, name) do
      Logger.warning(
        "instance config route names #{name}, which is not an active external frontend; that row is ignored"
      )
    end

    for {pat, name} <- Upstreams.shadowed_routes(routes) do
      Logger.warning(
        "instance config route for #{name} comes after a catch-all and is never reached (#{inspect(pat)})"
      )
    end
  end
end
