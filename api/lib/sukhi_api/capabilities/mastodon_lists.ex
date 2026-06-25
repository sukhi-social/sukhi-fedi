# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiApi.Capabilities.MastodonLists do
  @moduledoc """
  Mastodon lists surface.

      GET    /api/v1/lists                      read:lists
      POST   /api/v1/lists                      write:lists
      GET    /api/v1/lists/:id                  read:lists
      PUT    /api/v1/lists/:id                  write:lists
      DELETE /api/v1/lists/:id                  write:lists
      GET    /api/v1/lists/:id/accounts         read:lists
      POST   /api/v1/lists/:id/accounts         write:lists
      DELETE /api/v1/lists/:id/accounts         write:lists

      GET    /api/v1/timelines/list/:list_id    read:lists
  """

  use SukhiApi.Capability, addon: :mastodon_api

  alias SukhiApi.{GatewayRpc, Pagination, StatusHydration}
  alias SukhiApi.Views.{MastodonAccount, MastodonList}

  # The server-provided ご近所 (neighborhood) list. It isn't a row in the
  # lists table — it's a curated view exposed as an official list so a
  # Mastodon client can reach the bubble feed the same way it opens any
  # other list. Its id is a reserved string; real lists are decimal ids,
  # so there's no collision. The list is read-only (no membership edits).
  @bubble_list_id "bubble"

  @impl true
  def routes do
    [
      {:get, "/api/v1/lists", &index/1, scope: "read:lists"},
      {:post, "/api/v1/lists", &create/1, scope: "write:lists"},
      {:get, "/api/v1/lists/:id", &show/1, scope: "read:lists"},
      {:put, "/api/v1/lists/:id", &update/1, scope: "write:lists"},
      {:delete, "/api/v1/lists/:id", &delete/1, scope: "write:lists"},
      {:get, "/api/v1/lists/:id/accounts", &accounts/1, scope: "read:lists"},
      {:post, "/api/v1/lists/:id/accounts", &add_accounts/1, scope: "write:lists"},
      {:delete, "/api/v1/lists/:id/accounts", &remove_accounts/1, scope: "write:lists"},
      {:get, "/api/v1/timelines/list/:list_id", &timeline/1, scope: "read:lists"}
    ]
  end

  def index(req) do
    with_viewer(req, fn v ->
      case GatewayRpc.call(SukhiFedi.Lists, :list_for, [v.id]) do
        # ご近所 rides at the front, ahead of the reader's own lists.
        {:ok, lists} when is_list(lists) ->
          ok(200, [bubble_list_json(SukhiApi.Locale.from_req(req)) | MastodonList.render_list(lists)])

        e ->
          rpc_error(e)
      end
    end)
  end

  def show(req) do
    with_viewer(req, fn v ->
      id = req[:path_params]["id"]

      if id == @bubble_list_id do
        ok(200, bubble_list_json(SukhiApi.Locale.from_req(req)))
      else
        case GatewayRpc.call(SukhiFedi.Lists, :get, [v.id, id]) do
          {:ok, {:ok, list}} -> ok(200, MastodonList.render(list))
          {:ok, {:error, :not_found}} -> ok(404, %{error: "not_found"})
          e -> rpc_error(e)
        end
      end
    end)
  end

  def create(req) do
    with_viewer(req, fn v ->
      body = decode_body(req)
      title = body["title"]
      replies_policy = body["replies_policy"]
      exclusive = body["exclusive"]

      attrs =
        %{title: title}
        |> Map.merge(if replies_policy, do: %{replies_policy: replies_policy}, else: %{})
        |> Map.merge(if is_boolean(exclusive), do: %{exclusive: exclusive}, else: %{})

      case GatewayRpc.call(SukhiFedi.Lists, :create, [v.id, attrs]) do
        {:ok, {:ok, list}} -> ok(200, MastodonList.render(list))
        {:ok, {:error, %{} = cs}} -> ok(422, %{error: "validation_failed", detail: cs_errors(cs)})
        e -> rpc_error(e)
      end
    end)
  end

  def update(req) do
    with_viewer(req, fn v ->
      id = req[:path_params]["id"]

      if id == @bubble_list_id do
        official_readonly()
      else
        body = decode_body(req)

        case GatewayRpc.call(SukhiFedi.Lists, :update, [v.id, id, body]) do
          {:ok, {:ok, list}} -> ok(200, MastodonList.render(list))
          {:ok, {:error, :not_found}} -> ok(404, %{error: "not_found"})
          {:ok, {:error, %{} = cs}} -> ok(422, %{error: "validation_failed", detail: cs_errors(cs)})
          e -> rpc_error(e)
        end
      end
    end)
  end

  def delete(req) do
    with_viewer(req, fn v ->
      id = req[:path_params]["id"]

      if id == @bubble_list_id do
        official_readonly()
      else
        case GatewayRpc.call(SukhiFedi.Lists, :delete, [v.id, id]) do
          {:ok, {:ok, _}} -> ok(200, %{})
          {:ok, {:error, :not_found}} -> ok(404, %{error: "not_found"})
          e -> rpc_error(e)
        end
      end
    end)
  end

  def accounts(req) do
    with_viewer(req, fn v ->
      id = req[:path_params]["id"]

      # ご近所's membership is the server's curated allow-set, not a roster
      # the reader manages, so it has no per-account members to list.
      if id == @bubble_list_id do
        ok(200, [])
      else
        case GatewayRpc.call(SukhiFedi.Lists, :list_accounts, [v.id, id]) do
          {:ok, {:ok, accounts}} ->
            ok(200, Enum.map(accounts, &MastodonAccount.render(&1, %{})))

          {:ok, {:error, :not_found}} ->
            ok(404, %{error: "not_found"})

          e ->
            rpc_error(e)
        end
      end
    end)
  end

  def add_accounts(req), do: membership_op(req, :add_accounts)
  def remove_accounts(req), do: membership_op(req, :remove_accounts)

  defp membership_op(req, fun) do
    with_viewer(req, fn v ->
      id = req[:path_params]["id"]

      if id == @bubble_list_id do
        official_readonly()
      else
        body = decode_body(req)
        ids = body["account_ids"] || body["account_ids[]"] || []
        ids = List.wrap(ids)

        case GatewayRpc.call(SukhiFedi.Lists, fun, [v.id, id, ids]) do
          {:ok, :ok} -> ok(200, %{})
          {:ok, {:error, :not_found}} -> ok(404, %{error: "not_found"})
          e -> rpc_error(e)
        end
      end
    end)
  end

  def timeline(req) do
    with_viewer(req, fn v ->
      q = parse_query(req[:query])

      opts =
        req[:query]
        |> Pagination.parse_opts()
        |> Map.put(:only_media, q["only_media"] in ["true", "1"])
        |> Map.put(:hide_sensitive, q["hide_sensitive"] in ["true", "1"])

      id = req[:path_params]["list_id"]

      if id == @bubble_list_id do
        bubble_timeline(v, opts)
      else
        list_timeline(v, id, opts)
      end
    end)
  end

  # The ご近所 list timeline is the curated bubble feed. The viewer's id
  # rides along so their own blocks/mutes drop out, matching every feed.
  defp bubble_timeline(v, opts) do
    opts = Map.put(opts, :viewer_id, v.id)

    case GatewayRpc.call(SukhiFedi.Timelines, :bubble, [Map.to_list(opts)]) do
      {:ok, notes} when is_list(notes) ->
        render_notes(notes, v, "/api/v1/timelines/list/#{@bubble_list_id}", opts)

      e ->
        rpc_error(e)
    end
  end

  defp list_timeline(v, id, opts) do
    case GatewayRpc.call(SukhiFedi.Lists, :timeline, [v.id, id, Map.to_list(opts)]) do
      {:ok, {:ok, notes}} when is_list(notes) ->
        render_notes(notes, v, "/api/v1/timelines/list/#{id}", opts)

      {:ok, {:error, :not_found}} ->
        ok(404, %{error: "not_found"})

      e ->
        rpc_error(e)
    end
  end

  defp render_notes(notes, viewer, base_url, opts) do
    body = StatusHydration.many(notes, viewer)
    headers = [{"content-type", "application/json"}]

    headers =
      case Pagination.link_header(base_url, notes, & &1.id, opts) do
        nil -> headers
        link -> [link | headers]
      end

    {:ok, %{status: 200, body: JSON.encode!(body), headers: headers}}
  end

  defp with_viewer(req, fun) do
    %{current_account: viewer} = req[:assigns]

    case viewer do
      nil -> ok(403, %{error: "this endpoint requires a user-bound token"})
      %{} = v -> fun.(v)
    end
  end

  defp decode_body(req) do
    case req[:body] do
      nil -> %{}
      "" -> %{}
      body when is_binary(body) ->
        case JSON.decode(body) do
          {:ok, m} when is_map(m) -> m
          _ -> URI.decode_query(body)
        end

      body when is_map(body) ->
        body
    end
  end

  defp parse_query(nil), do: %{}
  defp parse_query(""), do: %{}
  defp parse_query(q) when is_binary(q), do: URI.decode_query(q)

  # The ご近所 entry, shaped like any other Mastodon list row. Its title
  # speaks the reader's language, the same two the web client offers.
  defp bubble_list_title(:ko), do: "이웃"
  defp bubble_list_title(_), do: "ご近所"

  defp bubble_list_json(locale) do
    %{
      id: @bubble_list_id,
      title: bubble_list_title(locale),
      replies_policy: "list",
      exclusive: false,
      filter_only_media: false,
      filter_hide_boosts: false,
      filter_hide_sensitive: false,
      filter_keyword: "",
      filter_replies: "all"
    }
  end

  defp official_readonly do
    ok(403, %{error: "forbidden", detail: "ご近所 is provided by the server and can't be edited."})
  end

  defp cs_errors(%{errors: errors}) do
    Map.new(errors, fn {k, {msg, _}} -> {k, msg} end)
  end

  defp cs_errors(_), do: %{}

  defp rpc_error({:error, :not_connected}), do: ok(503, %{error: "gateway_not_connected"})

  defp rpc_error({:error, {:badrpc, r}}),
    do: ok(503, %{error: "gateway_rpc_failed", detail: inspect(r)})

  defp rpc_error(_), do: ok(500, %{error: "internal_error"})

  defp ok(status, body) do
    {:ok,
     %{
       status: status,
       body: JSON.encode!(body),
       headers: [{"content-type", "application/json"}]
     }}
  end
end
