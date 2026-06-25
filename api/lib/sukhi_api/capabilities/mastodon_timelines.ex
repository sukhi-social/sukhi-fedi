# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiApi.Capabilities.MastodonTimelines do
  @moduledoc """
  Mastodon `/api/v1/timelines/*` capability.

      GET /api/v1/timelines/home          scope: read:statuses (authenticated)
      GET /api/v1/timelines/public        (public; `local=true` default)
      GET /api/v1/timelines/tag/:hashtag  (public)

  The list timeline (`/api/v1/timelines/list/:id`) lives with the
  list-management routes in `SukhiApi.Capabilities.MastodonLists`.

  ## Federated timeline

  sukhi is a small, calm box: it deliberately doesn't pour a federated
  firehose (every public post in the network) at third-party clients.
  A client's "Federated/Global" tab hits `/api/v1/timelines/public`
  with no `local` param — so that exact request returns a single guide
  post pointing the reader at the curated ご近所 (neighborhood) list
  instead. `?local=true` still serves the real local timeline, which is
  what sukhi's own web client always asks for.
  """

  use SukhiApi.Capability, addon: :mastodon_api

  alias SukhiApi.{GatewayRpc, Pagination, StatusHydration}
  alias SukhiApi.Views.MastodonStatus

  # A fixed, network-unique id for the synthetic guide post. Large enough
  # not to collide with our small bigserial note ids, and within the
  # signed-64 / JS-safe-integer range so Gson (Moshidon) and JS clients
  # (kaguya) parse it without choking.
  @guide_status_id 9_007_199_254_740_991
  @guide_created_at ~U[2026-06-01 00:00:00Z]

  # Same two languages the web client speaks (ja default, ko); the
  # reader's `Accept-Language` picks one, via `SukhiApi.Locale`. The list
  # name here matches the localized official-list title in MastodonLists.
  @guide_content %{
    ja: """
    <p>このサーバは、連合タイムライン（ネットワーク中のぜんぶの公開投稿が流れてくる濁流）を出していません。</p>
    <p>かわりに、リストから「ご近所」を追加すると、信頼しているご近所のサーバの公開投稿が、しずかに読めます。</p>
    """,
    ko: """
    <p>이 서버는 연합 타임라인(네트워크의 모든 공개 글이 흘러드는 급류)을 제공하지 않습니다.</p>
    <p>대신 목록에서 「이웃」을 추가하면, 신뢰하는 이웃 서버의 공개 글을 조용히 읽을 수 있어요.</p>
    """
  }

  @impl true
  def routes do
    [
      {:get, "/api/v1/timelines/home", &home/1, scope: "read:statuses"},
      {:get, "/api/v1/timelines/public", &public/1},
      {:get, "/api/v1/timelines/tag/:hashtag", &tag/1}
    ]
  end

  def home(req) do
    %{current_account: viewer} = req[:assigns]
    opts = Pagination.parse_opts(req[:query]) |> with_filters(req[:query])

    case viewer do
      nil ->
        ok(403, %{error: "this endpoint requires a user-bound token"})

      %{} = v ->
        case GatewayRpc.call(SukhiFedi.Timelines, :home, [v, Map.to_list(opts)]) do
          {:ok, notes} when is_list(notes) ->
            render_page(notes, "/api/v1/timelines/home", opts, v)

          {:error, :not_connected} ->
            ok(503, %{error: "gateway_not_connected"})

          {:error, {:badrpc, r}} ->
            ok(503, %{error: "gateway_rpc_failed", detail: inspect(r)})

          _ ->
            ok(500, %{error: "internal_error"})
        end
    end
  end

  def public(req) do
    base_opts = Pagination.parse_opts(req[:query])
    parsed = parse_query(req[:query])

    # `bubble=true` folds the ご近所 feed into the public route (one endpoint,
    # cleanest for client compat): public remote notes from the curated
    # allow-set only. A logged-in reader's id rides along so their own
    # blocks/mutes drop out, matching every other feed.
    if parsed["bubble"] in ["true", "1"] do
      viewer = req[:assigns][:current_account]
      opts = with_filters(base_opts, req[:query]) |> maybe_put_viewer(viewer)

      case GatewayRpc.call(SukhiFedi.Timelines, :bubble, [Map.to_list(opts)]) do
        {:ok, notes} when is_list(notes) ->
          render_page(notes, "/api/v1/timelines/public", opts, viewer)

        {:error, :not_connected} ->
          ok(503, %{error: "gateway_not_connected"})

        {:error, {:badrpc, r}} ->
          ok(503, %{error: "gateway_rpc_failed", detail: inspect(r)})

        _ ->
          ok(500, %{error: "internal_error"})
      end
    else
      # Mastodon's `public` route is the Local tab when `?local=true` and the
      # Federated tab otherwise. sukhi serves the real local feed for the
      # former and a single ご近所 guide for the latter (see @moduledoc).
      if parsed["local"] in ["true", "1"] do
        opts =
          base_opts
          |> with_filters(req[:query])
          |> Map.put(:local, true)
          |> Map.put(:remote, false)

        case GatewayRpc.call(SukhiFedi.Timelines, :public, [Map.to_list(opts)]) do
          {:ok, notes} when is_list(notes) ->
            render_page(notes, "/api/v1/timelines/public", opts)

          {:error, :not_connected} ->
            ok(503, %{error: "gateway_not_connected"})

          {:error, {:badrpc, r}} ->
            ok(503, %{error: "gateway_rpc_failed", detail: inspect(r)})

          _ ->
            ok(500, %{error: "internal_error"})
        end
      else
        federated_guide(req, base_opts)
      end
    end
  end

  # The Federated/Global tab. Rather than a firehose, hand back one guide
  # post — but only on the first page; a paginating client (`max_id`) gets
  # an empty page so the single post doesn't repeat forever as it scrolls.
  defp federated_guide(req, base_opts) do
    statuses =
      if Map.get(base_opts, :max_id),
        do: [],
        else: [guide_status(SukhiApi.Locale.from_req(req))]

    {:ok,
     %{
       status: 200,
       body: JSON.encode!(statuses),
       headers: [{"content-type", "application/json"}]
     }}
  end

  # A synthetic, server-authored Status. Rendered through the real status
  # view so its shape can't drift from every other post on the wire.
  defp guide_status(locale) do
    domain = SukhiApi.Config.domain!()

    account = %{
      id: 0,
      username: "sukhi",
      display_name: "sukhi",
      created_at: @guide_created_at,
      is_bot: true
    }

    note = %{
      id: @guide_status_id,
      created_at: @guide_created_at,
      content: @guide_content[locale] || @guide_content.ja,
      visibility: "public",
      account: account,
      ap_id: "https://#{domain}/notes/federated-guide"
    }

    MastodonStatus.render(note, %{})
  end

  def tag(req) do
    hashtag = req[:path_params]["hashtag"]
    base_opts = Pagination.parse_opts(req[:query])
    parsed = parse_query(req[:query])

    opts =
      base_opts
      |> with_filters(req[:query])
      |> Map.put(:local, parsed["local"] in ["true", "1", nil])

    case GatewayRpc.call(SukhiFedi.Timelines, :tag, [hashtag, Map.to_list(opts)]) do
      {:ok, notes} when is_list(notes) ->
        render_page(notes, "/api/v1/timelines/tag/#{hashtag}", opts)

      {:error, :not_connected} ->
        ok(503, %{error: "gateway_not_connected"})

      {:error, {:badrpc, r}} ->
        ok(503, %{error: "gateway_rpc_failed", detail: inspect(r)})

      _ ->
        ok(500, %{error: "internal_error"})
    end
  end

  defp render_page(notes, base_url, opts, viewer \\ nil) do
    body = StatusHydration.many(notes, viewer)
    headers = [{"content-type", "application/json"}]

    headers =
      case Pagination.link_header(base_url, notes, & &1.id, opts) do
        nil -> headers
        link -> [link | headers]
      end

    {:ok, %{status: 200, body: JSON.encode!(body), headers: headers}}
  end

  # only_media / hide_boosts / hide_sensitive をクエリから opts に畳む。
  # hide_boosts が効くのは home だけ(public/tag はブーストを混ぜない)。
  defp with_filters(opts, query) do
    parsed = parse_query(query)

    opts
    |> Map.put(:only_media, parsed["only_media"] in ["true", "1"])
    |> Map.put(:hide_boosts, parsed["hide_boosts"] in ["true", "1"])
    |> Map.put(:hide_sensitive, parsed["hide_sensitive"] in ["true", "1"])
  end

  defp maybe_put_viewer(opts, %{id: id}), do: Map.put(opts, :viewer_id, id)
  defp maybe_put_viewer(opts, _), do: opts

  defp parse_query(nil), do: %{}
  defp parse_query(""), do: %{}
  defp parse_query(q) when is_binary(q), do: URI.decode_query(q)

  defp ok(status, body) do
    {:ok,
     %{
       status: status,
       body: JSON.encode!(body),
       headers: [{"content-type", "application/json"}]
     }}
  end
end
