# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.MapPeers do
  @moduledoc """
  「連合の宇宙図」（公開ページ `/map` の星図）に名前を載せてよい
  インスタンスの allow-list。空のままなら星図には何も載らない＝
  管理人が選んだ星だけが公開される、ホワイトリスト式。

  bubble（ご近所タイムライン）とは独立した表。ご近所に居ても地図に
  載せたくない、はあり得るし、その逆もある。
  """

  import Ecto.Query

  alias SukhiFedi.Repo
  alias SukhiFedi.Schema.{MapPeer, Note}

  @spec list() :: [%MapPeer{}]
  def list do
    Repo.all(from(p in MapPeer, order_by: p.domain))
  end

  @spec domains() :: [String.t()]
  def domains do
    Repo.all(from(p in MapPeer, order_by: p.domain, select: p.domain))
  end

  @spec add(String.t(), integer()) :: {:ok, %MapPeer{}} | {:error, term()}
  def add(domain, created_by_id) when is_binary(domain) and is_integer(created_by_id) do
    %MapPeer{domain: domain, created_by_id: created_by_id}
    |> Repo.insert(on_conflict: :nothing, conflict_target: :domain)
  end

  @spec remove(String.t()) :: {:ok, %MapPeer{}} | {:error, :not_found}
  def remove(domain) when is_binary(domain) do
    case Repo.get_by(MapPeer, domain: domain) do
      nil -> {:error, :not_found}
      peer -> Repo.delete(peer)
    end
  end

  @doc """
  もう連合している host を、通信数（そこから届いて保存された note の数）の
  多い順で返す。admin の「どの星を地図に載せるか」選びの下敷き。
  `query` は domain の部分一致（大文字小文字は見ない）。
  """
  @spec known_hosts(keyword()) :: [%{domain: String.t(), notes: non_neg_integer()}]
  def known_hosts(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    query = Keyword.get(opts, :query)

    base =
      from n in Note,
        where: not is_nil(n.domain),
        group_by: n.domain,
        select: %{domain: n.domain, notes: count(n.id)},
        order_by: [desc: count(n.id), asc: n.domain],
        limit: ^limit

    case query && String.trim(query) do
      q when q in [nil, ""] -> base
      q -> from n in base, where: ilike(n.domain, ^("%" <> escape_like(q) <> "%"))
    end
    |> Repo.all()
  end

  defp escape_like(s) do
    s
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end
end
