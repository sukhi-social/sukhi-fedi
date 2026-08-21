# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Web.ActorController do
  import Plug.Conn

  # natadeco の板(デコ)の Group actor は `{slug}-deco` という名前で
  # 同じ `/users/:name` に居る ── 個人アカウントの username はハイフンを
  # 使えないので、この suffix で名前空間がぶつからない。
  @deco_suffix "-deco"

  def show(conn, _opts) do
    name = conn.path_params["name"]

    # deco addon が無効なインスタンス(decos テーブルが無い)では、
    # `-deco` 名を素通りさせず先に 404 にする ── 無いテーブルを
    # クエリして落ちないように。
    if String.ends_with?(name, @deco_suffix) and
         SukhiFedi.Addon.Registry.enabled?(:deco) do
      show_deco(conn, String.trim_trailing(name, @deco_suffix))
    else
      show_person(conn, name)
    end
  end

  defp show_deco(conn, slug) do
    case SukhiFedi.Addons.Deco.get_deco_record(slug) do
      {:error, :not_found} ->
        send_resp(conn, 404, JSON.encode!(%{error: "not found"}))

      {:ok, deco} ->
        actor = SukhiFedi.AP.GroupJson.build_group(deco)

        conn
        |> put_resp_content_type("application/activity+json")
        |> send_resp(200, JSON.encode!(actor))
    end
  end

  defp show_person(conn, username) do
    case SukhiFedi.Accounts.by_local_username(username) do
      nil ->
        send_resp(conn, 404, JSON.encode!(%{error: "not found"}))

      account ->
        # Use the single source of truth so icon / image / endpoints /
        # publicKey stay in lockstep with the Update(Person) body that
        # delivery fans out. Before this collapse, the inline map here
        # was missing icon/image entirely and avatars never federated.
        actor = SukhiFedi.AP.ActorJson.build_person(account)

        conn
        |> put_resp_content_type("application/activity+json")
        |> send_resp(200, JSON.encode!(actor))
    end
  end
end
