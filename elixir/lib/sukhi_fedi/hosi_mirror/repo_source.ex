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
    alias SukhiFedi.Schema.{Account, Note}

    @account [:id, :username, :domain, :actor_uri]
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
  end
end
