# SPDX-License-Identifier: AGPL-3.0-or-later
if Code.ensure_loaded?(SukhiHosi.Source) do
  defmodule SukhiFedi.HosiMirror.RepoSource do
    @moduledoc """
    `SukhiHosi.Source` over `SukhiFedi.Repo`: the same Ecto queries answer whether the store is
    PostgreSQL or Datalevin (`SUKHI_STORE`). Used as `{RepoSource, nil}`.
    """

    @behaviour SukhiHosi.Source

    import Ecto.Query

    alias SukhiFedi.Repo
    alias SukhiFedi.Schema.{Account, Note, Reaction}

    @account [:id, :username, :domain, :actor_uri]
    @like [:id, :account_id, :note_id]
    @note [:id, :account_id, :ap_id, :content, :content_html, :visibility, :domain, :created_at, :in_reply_to_ap_id]

    @impl true
    def accounts_after(_arg, after_id, limit),
      do: Repo.all(from a in Account, where: a.id > ^after_id, order_by: a.id, limit: ^limit) |> Enum.map(&Map.take(&1, @account))

    @impl true
    def accounts_by_ids(_arg, []), do: []

    def accounts_by_ids(_arg, ids),
      do: Repo.all(from a in Account, where: a.id in ^ids, order_by: a.id) |> Enum.map(&Map.take(&1, @account))

    @impl true
    def notes_after(_arg, after_id, limit),
      do: Repo.all(from n in Note, where: n.id > ^after_id, order_by: n.id, limit: ^limit) |> Enum.map(&Map.take(&1, @note))

    @impl true
    def notes_by_ids(_arg, []), do: []

    def notes_by_ids(_arg, ids),
      do: Repo.all(from n in Note, where: n.id in ^ids, order_by: n.id) |> Enum.map(&Map.take(&1, @note))

    @impl true
    def likes_after(_arg, after_id, limit, emoji) do
      Repo.all(from r in Reaction, where: r.id > ^after_id and r.emoji == ^emoji, order_by: r.id, limit: ^limit)
      |> Enum.map(&Map.take(&1, @like))
    end
  end
end
