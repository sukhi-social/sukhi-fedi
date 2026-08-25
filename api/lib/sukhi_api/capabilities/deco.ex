# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiApi.Capabilities.Deco do
  @moduledoc """
  natadeco の掲示板。板一枚が「デコ」。

      GET  /api/v1/deco                    板の一覧（誰でも）
      POST /api/v1/deco                    板を立てる            write:statuses + admin
      GET  /api/v1/deco/:slug              板一枚
      DELETE /api/v1/deco/:slug            板を畳む(中の投稿も)   write:statuses + admin
      GET  /api/v1/deco/:slug/posts        その板の投稿（親だけ）
      POST /api/v1/deco/:slug/posts        書く                  write:statuses
      GET  /api/v1/deco/posts/:id          一件＋ぶら下がり
      PATCH /api/v1/deco/posts/:id         直す(自分のだけ)      write:statuses
      DELETE /api/v1/deco/posts/:id        消す(自分のだけ)      write:statuses
      POST /api/v1/deco/posts/:id/replies  ぶら下げる            write:statuses

  投稿には書いた人がついてくる（`author`: 表示名・acct・アイコン）。
  note.com と同じで、板の上でも隠れない。

  `/api/v1/deco/posts/:id` と `/api/v1/deco/:slug` は段の数が違うので
  取り違えない。ただし `posts` という名前の板だけは隠れてしまうので、
  gateway 側の `Deco.changeset/2` がその slug を断る。
  """

  use SukhiApi.Capability, addon: :deco

  alias SukhiApi.{AdminAuth, GatewayRpc}

  @gateway SukhiFedi.Addons.Deco

  @impl true
  def routes do
    [
      {:get, "/api/v1/deco", &index/1},
      {:post, "/api/v1/deco", &create_deco/1, scope: "write:statuses"},
      {:get, "/api/v1/deco/posts/:id", &show_post/1},
      {:patch, "/api/v1/deco/posts/:id", &update_post/1, scope: "write:statuses"},
      {:delete, "/api/v1/deco/posts/:id", &delete_post/1, scope: "write:statuses"},
      {:post, "/api/v1/deco/posts/:id/replies", &reply/1, scope: "write:statuses"},
      {:get, "/api/v1/deco/:slug", &show/1},
      {:delete, "/api/v1/deco/:slug", &delete_deco/1, scope: "write:statuses"},
      {:get, "/api/v1/deco/:slug/posts", &list_posts/1},
      {:get, "/api/v1/deco/:slug/flow", &list_flow/1},
      {:post, "/api/v1/deco/:slug/posts", &post/1, scope: "write:statuses"}
    ]
  end

  def index(_req), do: call(:list_decos, [], &ok(200, &1))

  def show(req) do
    call(:get_deco, [req[:path_params]["slug"]], &ok(200, &1))
  end

  # 板を立てるのは admin だけ ── natadeco が小さいうちは、板の数を
  # 誰かが見て決める場所にしておく。読む・書くは誰でも、のまま。
  def create_deco(req) do
    with {:ok, admin} <- AdminAuth.require_admin(req) do
      body = decode_body(req)
      call(
        :create_deco,
        [admin, take(body, [
          "slug",
          "name",
          "description",
          "name_i18n",
          "description_i18n",
          "local_only",
          "has_actor"
        ])],
        &ok(201, &1)
      )
    else
      {:error, :forbidden} -> ok(403, %{error: "admin_required"})
    end
  end

  # 板を畳むのも admin だけ ── 立てるのと対称。取り消せない。
  def delete_deco(req) do
    with {:ok, _admin} <- AdminAuth.require_admin(req) do
      case GatewayRpc.call(@gateway, :delete_deco, [req[:path_params]["slug"]]) do
        {:ok, :ok} -> ok(204, %{})
        {:ok, {:error, :not_found}} -> ok(404, %{error: "not_found"})
        {:error, :not_connected} -> ok(503, %{error: "gateway_not_connected"})
        _ -> ok(500, %{error: "internal_error"})
      end
    else
      {:error, :forbidden} -> ok(403, %{error: "admin_required"})
    end
  end

  def list_posts(req) do
    q = parse_query(req[:query])

    opts =
      []
      |> put_int(:limit, q["limit"])
      |> put_int(:before_id, q["before_id"])
      |> put_datetime(:before_activity_at, q["before_activity_at"])

    # 読むのは誰でも(viewer は無くていい)。居るときだけ渡すのは、
    # リアクションの `me` を立てるため。
    opts = put_viewer(opts, viewer(req))

    call(:list_posts, [req[:path_params]["slug"], opts], &ok(200, &1))
  end

  # 話す板の流れ。平らに、書かれた順。板の一覧と同じで、読むのは誰でも
  # ── viewer は反応の `me` を立てるためだけに渡す。
  def list_flow(req) do
    q = parse_query(req[:query])

    opts =
      []
      |> put_int(:limit, q["limit"])
      |> put_int(:before_id, q["before_id"])
      |> put_int(:since_id, q["since_id"])
      |> put_viewer(viewer(req))

    call(:list_flow, [req[:path_params]["slug"], opts], &ok(200, &1))
  end

  def show_post(req) do
    call(:get_post, [req[:path_params]["id"], viewer_id(req)], &ok(200, &1))
  end

  def post(req) do
    with %{} = viewer <- viewer(req) do
      body = decode_body(req)
      call(
        :post,
        [
          viewer,
          req[:path_params]["slug"],
          take(body, ["title", "status", "title_i18n", "content_i18n", "visibility"])
        ],
        &ok(201, &1)
      )
    else
      _ -> ok(403, %{error: "this endpoint requires a user-bound token"})
    end
  end

  def reply(req) do
    with %{} = viewer <- viewer(req) do
      body = decode_body(req)
      call(
        :reply,
        [viewer, req[:path_params]["id"], take(body, ["status", "content_i18n", "visibility"])],
        &ok(201, &1)
      )
    else
      _ -> ok(403, %{error: "this endpoint requires a user-bound token"})
    end
  end

  # 自分の投稿・レスだけ直せる ── 他人のものは gateway が :forbidden を
  # 返すので、下の call/3 が 403 に変える。
  def update_post(req) do
    with %{} = viewer <- viewer(req) do
      body = decode_body(req)

      call(
        :update_post,
        [viewer, req[:path_params]["id"], take(body, ["title", "status", "title_i18n", "content_i18n"])],
        &ok(200, &1)
      )
    else
      _ -> ok(403, %{error: "this endpoint requires a user-bound token"})
    end
  end

  # 自分の投稿・レスだけ消せる ── 取り消せない。delete_deco と同じ形
  # (裸の :ok/:error を返す gateway 関数なので、下の call/3 は使わない)。
  def delete_post(req) do
    with %{} = viewer <- viewer(req) do
      case GatewayRpc.call(@gateway, :delete_post, [viewer, req[:path_params]["id"]]) do
        {:ok, :ok} -> ok(204, %{})
        {:ok, {:error, :not_found}} -> ok(404, %{error: "not_found"})
        {:ok, {:error, :forbidden}} -> ok(403, %{error: "forbidden"})
        {:error, :not_connected} -> ok(503, %{error: "gateway_not_connected"})
        _ -> ok(500, %{error: "internal_error"})
      end
    else
      _ -> ok(403, %{error: "this endpoint requires a user-bound token"})
    end
  end

  # ── 配線 ─────────────────────────────────────────────────────────────

  # gateway の返りは三通り（生の値／{:ok, _}／{:error, _}）。掲示板の
  # 読みは生の list を返すので、両方をここで受ける。
  defp call(fun, args, on_ok) do
    case GatewayRpc.call(@gateway, fun, args) do
      {:ok, {:ok, value}} -> on_ok.(value)
      {:ok, {:error, :not_found}} -> ok(404, %{error: "not_found"})
      {:ok, {:error, :forbidden}} -> ok(403, %{error: "forbidden"})
      {:ok, {:error, {:validation, errors}}} -> ok(422, %{error: "validation", detail: errors})
      {:ok, {:error, reason}} -> ok(422, %{error: to_string(reason)})
      {:ok, value} when is_list(value) -> on_ok.(value)
      {:error, :not_connected} -> ok(503, %{error: "gateway_not_connected"})
      {:error, {:badrpc, reason}} -> ok(503, %{error: "gateway_rpc_failed", detail: inspect(reason)})
      _ -> ok(500, %{error: "internal_error"})
    end
  end

  defp viewer(req), do: (req[:assigns] || %{})[:current_account]

  defp viewer_id(req) do
    case viewer(req) do
      %{id: id} -> id
      _ -> nil
    end
  end

  defp put_viewer(opts, %{id: id}), do: Keyword.put(opts, :viewer_id, id)
  defp put_viewer(opts, _), do: opts

  defp take(body, keys), do: Map.take(body, keys)

  defp put_int(opts, _key, nil), do: opts

  defp put_int(opts, key, raw) do
    case Integer.parse(to_string(raw)) do
      {n, _} when n > 0 -> Keyword.put(opts, key, n)
      _ -> opts
    end
  end

  defp put_datetime(opts, _key, nil), do: opts
  defp put_datetime(opts, _key, ""), do: opts

  defp put_datetime(opts, key, raw) do
    case DateTime.from_iso8601(to_string(raw)) do
      {:ok, dt, _offset} -> Keyword.put(opts, key, dt)
      _ -> opts
    end
  end

  defp parse_query(nil), do: %{}
  defp parse_query(""), do: %{}
  defp parse_query(q) when is_binary(q), do: URI.decode_query(q)

  defp decode_body(req) do
    ct =
      Enum.find_value(req[:headers] || [], "", fn {k, v} ->
        if String.downcase(to_string(k)) == "content-type", do: to_string(v), else: nil
      end)

    cond do
      String.contains?(ct, "application/json") ->
        case JSON.decode(req[:body] || "") do
          {:ok, %{} = m} -> m
          _ -> %{}
        end

      String.contains?(ct, "application/x-www-form-urlencoded") ->
        URI.decode_query(req[:body] || "")

      true ->
        %{}
    end
  end

  defp ok(status, body) do
    {:ok,
     %{
       status: status,
       body: JSON.encode!(body),
       headers: [{"content-type", "application/json"}]
     }}
  end
end
