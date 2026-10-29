# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Graph.Actor do
  @moduledoc """
  Actors in the graph. A remote actor is written from its document (the raw
  JSON goes through `SukhiFedi.RawStore`: signature checks and forwarding
  need the original); a local one is written from the account, so rules like
  "a local actor liked it" have something to match.

  Remote actors are never removed by cleanup (`Graph.Sweep`).
  """

  alias SukhiFedi.{Graph, RawStore}

  @actor_types ~w(Person Service Application Group Organization)

  @spec actor_type?(term()) :: boolean()
  def actor_type?(type), do: type in @actor_types

  @doc "Upsert a remote actor from its document. Options: `:raw` (required), `:now`, `:raw_config`."
  @spec ingest(map(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def ingest(%{"id" => iri, "type" => type} = doc, opts) when is_binary(iri) do
    if actor_type?(type) do
      now = Keyword.get_lazy(opts, :now, &Graph.now/0)
      raw_config = Keyword.get_lazy(opts, :raw_config, &RawStore.Config.current/0)

      with {:ok, raw_attrs} <- RawStore.put("actor", Keyword.fetch!(opts, :raw), raw_config) do
        host = URI.parse(iri).host

        actor =
          %{
            ":db/id" => -1,
            ":actor/id" => iri,
            ":actor/local?" => false,
            ":actor/username" => doc["preferredUsername"],
            ":actor/host" => host,
            ":actor/name" => doc["name"],
            ":actor/summary" => doc["summary"],
            ":actor/avatar" => image(doc["icon"]),
            ":actor/banner" => image(doc["image"]),
            ":actor/bot?" => type in ~w(Service Application),
            ":actor/inbox" => doc["inbox"],
            ":actor/outbox" => doc["outbox"],
            ":actor/shared-inbox" => get_in(doc, ["endpoints", "sharedInbox"]),
            ":actor/fetched-at" => now
          }
          |> Map.merge(Map.new(raw_attrs, fn {k, v} -> {":" <> Atom.to_string(k), v} end))
          |> compact()

        tx = [actor] ++ key(doc["publicKey"], iri)

        Graph.exclusive(fn -> with {:ok, _} <- Graph.transact(tx), do: {:ok, iri} end)
      end
    else
      {:error, :not_an_actor}
    end
  end

  def ingest(_doc, _opts), do: {:error, :invalid_actor}

  @doc """
  Upsert a local actor. `attrs`: `:iri`, `:username`, `:name`, `:summary`,
  `:sid` (the account's API id), `:admin?`.
  """
  @spec upsert_local(map()) :: {:ok, String.t()} | {:error, term()}
  def upsert_local(%{iri: iri, username: username} = attrs) do
    actor =
      compact(%{
        ":db/id" => -1,
        ":actor/id" => iri,
        ":actor/local?" => true,
        ":actor/username" => username,
        ":actor/name" => attrs[:name],
        ":actor/summary" => attrs[:summary],
        ":actor/sid" => attrs[:sid]
      })

    user = compact(%{":user/actor" => -1, ":user/admin?" => attrs[:admin?]})

    Graph.exclusive(fn ->
      with {:ok, _} <- Graph.transact([actor, user]), do: {:ok, iri}
    end)
  end

  defp key(%{"id" => id, "publicKeyPem" => pem}, _owner) when is_binary(id) and is_binary(pem) do
    [
      %{
        ":key/id" => id,
        ":key/actor" => -1,
        ":key/type" => ":RsaVerificationKey2018",
        ":key/public" => pem
      }
    ]
  end

  defp key(_, _), do: []

  defp image(%{"url" => url}) when is_binary(url), do: url
  defp image(url) when is_binary(url), do: url
  defp image(_), do: nil

  defp compact(map), do: map |> Enum.reject(fn {_, v} -> is_nil(v) or v == "" end) |> Map.new()
end
