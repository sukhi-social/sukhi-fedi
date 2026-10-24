# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiShared.Capability do
  @moduledoc """
  FEP-844e capability discovery: what we say we implement, and how we read
  what a peer says.

  An actor carries `generator: {type: "Application", implements: [{href,
  name}]}`. This module is the one place that shape is written
  (`generator/0`, used by `SukhiShared.ActorJson`) and the one place it is
  read (`hrefs/1`, `declares?/2`). Nothing else looks inside a remote
  actor's `generator`.

  Pull Federation is the capability `pull_federation/0`. Whether we
  advertise it is `advertised?/0` (config `:sukhi_shared, :pull_federation`,
  default on): turning it off removes the entry from every actor, and peers
  stop sending us notifications once their copy of our actor expires.
  """

  @context "https://w3id.org/fep/844e"

  @pull_federation "https://github.com/sukhi-social/sukhi-fedi/blob/main/docs/PULL_FEDERATION.md"

  @doc "The JSON-LD context URI FEP-844e asks actors to carry."
  @spec context() :: String.t()
  def context, do: @context

  @doc "The identifier of the Pull Federation capability."
  @spec pull_federation() :: String.t()
  def pull_federation, do: @pull_federation

  @doc "Whether this server advertises (and so must implement) Pull Federation."
  @spec advertised?() :: boolean()
  def advertised?, do: Application.get_env(:sukhi_shared, :pull_federation, true) == true

  @doc """
  The `implements` entries we advertise. Empty when nothing is on.
  """
  @spec implements() :: [map()]
  def implements do
    if advertised?(),
      do: [%{"href" => @pull_federation, "name" => "Pull Federation (notify, then pull)"}],
      else: []
  end

  @doc """
  The `generator` value for an actor document, or `nil` when we advertise
  nothing (a bare actor stays bare).
  """
  @spec generator() :: map() | nil
  def generator do
    case implements() do
      [] -> nil
      list -> %{"type" => "Application", "implements" => list}
    end
  end

  @doc """
  Every capability `href` a remote actor document declares, deduplicated.
  Tolerant of what peers send: `generator` may be a map or a one-element
  list, `implements` a list or a single map, an entry may be a bare string,
  and anything malformed is skipped rather than raising. Input comes from
  an untrusted host, so the result is capped.
  """
  @spec hrefs(term()) :: [String.t()]
  def hrefs(%{"generator" => generator}) do
    generator
    |> List.wrap()
    |> Enum.flat_map(fn
      %{"implements" => impl} -> List.wrap(impl)
      _ -> []
    end)
    |> Enum.flat_map(fn
      %{"href" => href} when is_binary(href) -> [href]
      href when is_binary(href) -> [href]
      _ -> []
    end)
    |> Enum.filter(&(byte_size(&1) <= 512))
    |> Enum.uniq()
    |> Enum.take(64)
  end

  def hrefs(_), do: []

  @doc "Does this remote actor document declare `href`?"
  @spec declares?(term(), String.t()) :: boolean()
  def declares?(actor, href), do: href in hrefs(actor)
end
