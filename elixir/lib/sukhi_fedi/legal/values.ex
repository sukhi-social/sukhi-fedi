# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Legal.Values do
  @moduledoc """
  The values that differ from one operator to the next in `/terms` and
  `/privacy`, and the one place that puts them into the text.

  The Markdown in `priv/legal/` carries `{{contact_email}}` and
  `{{contact_activitypub}}` where an operator's own address belongs. The
  documents are rendered at compile time, so the values are filled in at
  request time, from `"legal"` in the instance config
  (`SukhiShared.InstanceConfig.legal/1`, shape-checked when the config is
  loaded). The words around them are not configurable: they are the policy.

  A key left out of the config falls back to the flavor's own address, so an
  instance that has not set anything yet reads exactly as it did before the
  setting existed. `source/0` says which of the two is in effect, and boot
  logs it.
  """

  @keys [:contact_email, :contact_activitypub]

  @defaults %{
    sukhi: %{
      contact_email: "f3liz-dev@proton.me",
      contact_activitypub: "@kuro_admin@sukhi.f3liz.casa"
    },
    natadeco: %{
      contact_email: "admin@natadeco.com",
      contact_activitypub: "@admin@natadeco.com"
    }
  }

  @doc "The values in effect for `flavor`: configured ones over the flavor's defaults."
  @spec resolve(atom(), SukhiShared.InstanceConfig.t()) :: %{atom() => String.t()}
  def resolve(flavor, instance_config) do
    Map.merge(Map.fetch!(@defaults, flavor), SukhiShared.InstanceConfig.legal(instance_config))
  end

  @doc "`:configured` when every value comes from the instance config, else `:flavor_default`."
  @spec source(SukhiShared.InstanceConfig.t()) :: :configured | :flavor_default
  def source(instance_config) do
    if Enum.all?(@keys, &Map.has_key?(SukhiShared.InstanceConfig.legal(instance_config), &1)),
      do: :configured,
      else: :flavor_default
  end

  @doc """
  Replace each `{{key}}` in the baked HTML with its value, HTML-escaped.
  A placeholder with no value is left as written, so a typo in the Markdown
  shows up on the page instead of vanishing.
  """
  @spec fill(String.t(), %{atom() => String.t()}) :: String.t()
  def fill(html, values) do
    Enum.reduce(values, html, fn {key, value}, acc ->
      String.replace(acc, "{{#{key}}}", Plug.HTML.html_escape(value))
    end)
  end
end
