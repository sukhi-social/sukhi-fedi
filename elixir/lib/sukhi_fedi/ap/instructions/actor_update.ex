# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.AP.Instructions.ActorUpdate do
  @moduledoc """
  Inbound `Update(Person)` (and Service / Application / Group /
  Organization): a remote actor changed its profile — avatar, header,
  name, bio, fields. We already hold a shadow `accounts` row for them,
  and nothing else would ever refresh it.

  The embedded body is only a *signal*. The sender's own server vouched
  for it (`Instructions.execute/3` has already matched the HTTP-signature
  host to the activity's `actor`), but we do not ingest it: we drop the
  cached actor document, fetch it again from its origin, and run that
  through `RemoteAccounts.upsert_from_actor_json/2` — the one place that
  checks the id's host and decides what may overwrite what.

  Acted on only when:

    * `object.id` is exactly the activity's `actor` (an actor may update
      only itself);
    * the actor is not on our own host;
    * we already have a remote row for it. An actor we have never met is
      ignored — it is ingested on first contact (follow, mention, …).
  """

  import Ecto.Query

  alias SukhiFedi.AP.Instructions.Extract
  alias SukhiFedi.Federation.{ActorFetcher, RemoteAccounts}
  alias SukhiFedi.Repo
  alias SukhiFedi.Schema.Account

  @actor_types ["Person", "Service", "Application", "Group", "Organization"]

  @doc """
  `fetch` is the re-fetch step (defaults to `ActorFetcher.refresh/1`); a
  parameter so tests do not need a network.
  """
  @spec maybe_handle(map(), (String.t() -> {:ok, map()} | {:error, term()})) :: :ok
  def maybe_handle(activity, fetch \\ &ActorFetcher.refresh/1)

  def maybe_handle(
        %{"type" => "Update", "actor" => actor_uri, "object" => %{"type" => type, "id" => actor_uri}},
        fetch
      )
      when is_binary(actor_uri) and type in @actor_types do
    with false <- Extract.own_host?(actor_uri),
         true <- remote_row?(actor_uri),
         {:ok, json} <- fetch.(actor_uri) do
      _ = RemoteAccounts.upsert_from_actor_json(json, actor_uri)
    end

    :ok
  end

  def maybe_handle(_, _), do: :ok

  defp remote_row?(actor_uri) do
    Repo.exists?(from(a in Account, where: a.actor_uri == ^actor_uri and not is_nil(a.domain)))
  end
end
