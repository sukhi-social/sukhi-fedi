# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiDelivery.Release do
  @moduledoc """
  Release task stub. The gateway release owns all database migrations
  (including the shared `outbox`, `delivery_receipts`, and `oban_jobs`
  tables). Delivery's entrypoint therefore does not invoke this.

  Reintroduce a body here the first time delivery ships its own table.
  """

  @app :sukhi_delivery

  def migrate_all do
    load_app()
    :ok
  end

  @doc """
  FEP-f799: tell the peers, from a running node (docs/DELIVERY_SUSPENSION.md).

      bin/sukhi_delivery rpc 'SukhiDelivery.Release.announce_suspension("/srv/sukhi/send/m1.create.json")'

  `path` is a pre-signed activity made by `mix sukhi.suspension.prepare`
  (`send/<slug>.create.json` when the resting starts, `held/<slug>.undo.json`
  when it ends). It is sent as it is, one inbox per remote host, a few a second.
  """
  @spec announce_suspension(Path.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def announce_suspension(path, opts \\ []) do
    with {:ok, activity} <- read_activity(path) do
      SukhiDelivery.Delivery.Announce.run(activity, opts)
    end
  end

  @doc false
  @spec read_activity(Path.t()) :: {:ok, map()} | {:error, term()}
  def read_activity(path) do
    with {:ok, body} <- File.read(path),
         {:ok, %{} = activity} <- JSON.decode(body) do
      {:ok, activity}
    else
      {:error, reason} -> {:error, {:unreadable, reason}}
      _ -> {:error, {:unreadable, :not_an_object}}
    end
  end

  defp load_app, do: Application.load(@app)
end
