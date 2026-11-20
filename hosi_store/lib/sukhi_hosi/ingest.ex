# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiHosi.Ingest do
  @moduledoc """
  What arrives from other servers. A remote post and the actor it names (if we have not met them)
  go in as one write; the IRIs are identities, so the same post arriving twice, or at the same
  moment on two connections, is made once and the others are told `:already`.

  Nothing here tells the relay: a remote post is not ours to deliver. There is also no copy kept
  beside another database: what is written here is the record.
  """

  alias SukhiHosi.{Actors, Notes}

  @doc "`post` is `%{id:, actor:, html:}` with the options `Notes.object_ops/5` takes (`:published`, `:visibility`, `:tags`, `:mentions`)."
  def object(db, %{id: iri, actor: actor_iri, html: html}, opts \\ [], tries \\ 2) do
    if Notes.find(db, iri) do
      :already
    else
      {author, actor_ops} =
        case Actors.find(db, actor_iri) do
          nil -> {[:tmp, 2], Actors.remote_ops(2, actor_iri)}
          id -> {id, []}
        end

      parent = if p = opts[:in_reply_to_iri], do: Notes.find(db, p)
      opts = opts |> Keyword.put(:db, db) |> Keyword.put(:local?, false) |> Keyword.put(:in_reply_to, parent)

      told = SukhiHosi.Notifications.mention_ops(db, 3, [:tmp, 1], iri, author, Keyword.get(opts, :mentions, []))

      case Hosi.write(db, actor_ops ++ Notes.object_ops(1, author, iri, html, opts) ++ told) do
        {:ok, %{temps: temps}} ->
          {:ok, temps |> Map.new(fn [n, id] -> {n, id} end) |> Map.fetch!(1)}

        {:error, {:app, _, _} = why} ->
          # someone else made the post, or the actor, between our look and our write
          cond do
            Notes.find(db, iri) -> :already
            tries > 1 -> object(db, %{id: iri, actor: actor_iri, html: html}, opts, tries - 1)
            true -> {:error, why}
          end
      end
    end
  end
end
