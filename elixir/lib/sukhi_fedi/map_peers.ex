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
  alias SukhiFedi.Schema.MapPeer

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
end
