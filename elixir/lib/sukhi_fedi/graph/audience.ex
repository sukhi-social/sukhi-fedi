# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Graph.Audience do
  @moduledoc """
  Who an ActivityPub object is addressed to, and the visibility that follows.

  `visibility/3` is the one place `to`/`cc` become `:public | :unlisted |
  :followers | :direct`; the `object/visibility` attribute is only a written
  copy of its answer, kept so a timeline can range over it.
  """

  @public "https://www.w3.org/ns/activitystreams#Public"
  @public_aliases [@public, "as:Public", "Public"]

  @type visibility :: :public | :unlisted | :followers | :direct

  @spec public() :: String.t()
  def public, do: @public

  @spec public?(String.t()) :: boolean()
  def public?(iri), do: iri in @public_aliases

  @doc """
  `followers` is the author's followers collection IRI (`nil` when unknown).

  Public in `to` → `:public`; public only in `cc` → `:unlisted`; the
  followers collection among the addressees → `:followers`; otherwise `:direct`.
  """
  @spec visibility([String.t()], [String.t()], String.t() | nil) :: visibility()
  def visibility(to, cc, followers) do
    cond do
      Enum.any?(to, &public?/1) -> :public
      Enum.any?(cc, &public?/1) -> :unlisted
      followers != nil and followers in (to ++ cc) -> :followers
      true -> :direct
    end
  end

  @doc "Every IRI in an `to`/`cc` value, whatever shape it came in (string, list, map with `id`)."
  @spec iris(term()) :: [String.t()]
  def iris(nil), do: []
  def iris(iri) when is_binary(iri), do: [iri]
  def iris(%{"id" => iri}) when is_binary(iri), do: [iri]
  def iris(list) when is_list(list), do: list |> Enum.flat_map(&iris/1) |> Enum.uniq()
  def iris(_), do: []
end
