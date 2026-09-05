# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiApi.Config do
  @moduledoc false

  @spec domain!() :: String.t()
  def domain!, do: Application.fetch_env!(:sukhi_api, :domain)

  @doc "Same rule as the gateway's `SukhiFedi.Config.cookie_domain/0` — see there."
  @spec cookie_domain() :: String.t() | nil
  def cookie_domain do
    host = domain!() |> String.split(":", parts: 2) |> hd()
    if String.contains?(host, "."), do: "." <> host, else: nil
  end
end
