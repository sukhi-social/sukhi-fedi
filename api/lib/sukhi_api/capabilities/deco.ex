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
      {:post, "/api/v1/deco/posts/:id/replies", &reply/1, scope: "write:statuses"},
      {:get, "/api/v1/deco/:slug", &show/1},
      {:delete, "/api/v1/deco/:slug", &delete_deco/1, scope: "write:statuses"},
      {:get, "/api/v1/deco/:slug/posts", &list_posts/1},
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
        [admin, take(body, ["slug", "name", "description", "name_i18n", "description_i18n"])],
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

    call(:list_posts, [req[:path_params]["slug"], opts], &ok(200, &1))
  end

  def show_post(req) do
    call(:get_post, [req[:path_params]["id"]], &ok(200, &1))
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

  # ── 配線 ─────────────────────────────────────────────────────────────

  # gateway の返りは三通り（生の値／{:ok, _}／{:error, _}）。掲示板の
  # 読みは生の list を返すので、両方をここで受ける。
  defp call(fun, args, on_ok) do
    case GatewayRpc.call(@gateway, fun, args) do
      {:ok, {:ok, value}} -> on_ok.(value)
      {:ok, {:error, :not_found}} -> ok(404, %{error: "not_found"})
      {:ok, {:error, {:validation, errors}}} -> ok(422, %{error: "validation", detail: errors})
      {:ok, {:error, reason}} -> ok(422, %{error: to_string(reason)})
      {:ok, value} when is_list(value) -> on_ok.(value)
      {:error, :not_connected} -> ok(503, %{error: "gateway_not_connected"})
      {:error, {:badrpc, reason}} -> ok(503, %{error: "gateway_rpc_failed", detail: inspect(reason)})
      _ -> ok(500, %{error: "internal_error"})
    end
  end

  defp viewer(req), do: (req[:assigns] || %{})[:current_account]

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
