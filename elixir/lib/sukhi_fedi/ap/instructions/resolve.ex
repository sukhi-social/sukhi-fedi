# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.AP.Instructions.Resolve do
  @moduledoc """
  Resolving inbound AP references to local rows: actors (with shadow
  ingest on first contact) and target notes.
  """

  alias SukhiFedi.Accounts
  alias SukhiFedi.AP.Instructions.Extract
  alias SukhiFedi.Repo
  alias SukhiFedi.Schema.{Account, Note}

  @doc """
  Look up an existing shadow Account by actor_uri, otherwise fetch +
  upsert via the federation client. Local actor URIs (host == ours)
  are matched by username.
  """
  def resolve_or_ingest_actor(actor_uri) do
    domain = SukhiFedi.Config.domain!()

    cond do
      String.contains?(actor_uri, domain) ->
        username =
          Extract.actor_username(actor_uri)

        case SukhiFedi.Accounts.by_local_username(username) do
          %Account{} = a -> {:ok, a}
          nil -> {:error, :no_local_actor}
        end

      true ->
        case Accounts.by_actor_uri(actor_uri) do
          %Account{} = a ->
            {:ok, a}

          nil ->
            with {:ok, json} <- SukhiFedi.Federation.ActorFetcher.fetch(actor_uri),
                 {:ok, %Account{} = a} <-
                   SukhiFedi.Federation.RemoteAccounts.upsert_from_actor_json(json, actor_uri) do
              {:ok, a}
            else
              _ -> {:error, :ingest_failed}
            end
        end
    end
  end

  @doc """
  Resolve the Note an inbound activity targets. Local notes are
  addressed by their synthesized AP id (`…/users/<name>/notes/<id>`,
  see `NoteController`) and carry no `ap_id` column, so the trailing
  path segment is the row id. Remote (mirrored) notes are matched by
  their stored `ap_id`.
  """
  def resolve_target_note(object) do
    case Extract.extract_object_id(object) do
      uri when is_binary(uri) ->
        if String.contains?(uri, SukhiFedi.Config.domain!()) do
          last = (URI.parse(uri).path || "") |> String.split("/") |> List.last()

          case Integer.parse(last || "") do
            {id, ""} -> Repo.get(Note, id)
            _ -> nil
          end
        else
          Repo.get_by(Note, ap_id: uri)
        end

      _ ->
        nil
    end
  end

  def local_account_id_from_uri(uri) when is_binary(uri) do
    domain = SukhiFedi.Config.domain!()

    if String.contains?(uri, domain) do
      username = Extract.actor_username(uri)

      case SukhiFedi.Accounts.by_local_username(username) do
        nil -> nil
        account -> account.id
      end
    end
  end
end
