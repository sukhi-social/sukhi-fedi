# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Web.PluginPlug do
  @moduledoc """
  Forwards the current request to a plugin node via distributed Erlang.

  The plugin catalogue lives under `api/` as an independent mix project
  (`:sukhi_api`). Each capability in `api/lib/sukhi_api/capabilities/`
  declares its own routes; see `SukhiApi.Capability`. Adding a new
  HTTP endpoint means dropping a new file into that directory — no
  gateway change needed.

  Operationally:

    * plugin node list read from `config :sukhi_fedi, :plugin_nodes`
    * first reachable node wins; unreachable nodes are skipped
    * `:rpc.call/5` with a 5s timeout
    * if nothing is reachable or the call fails, 503 is returned to
      the client
  """

  import Plug.Conn
  require Logger

  @behaviour Plug

  @timeout 5_000
  # multipart body の上限。8 MiB inline upload + form fields の余白で
  # 16 MiB。これを超えるとき client は 413 を受ける。
  @max_raw_body 16 * 1024 * 1024

  @impl true
  def init(opts) do
    %{
      nodes: Keyword.get(opts, :nodes, :runtime),
      timeout: Keyword.get(opts, :timeout, @timeout),
      module: Keyword.get(opts, :module, SukhiApi.Router),
      function: Keyword.get(opts, :function, :handle)
    }
  end

  @impl true
  def call(conn, %{nodes: nodes_opt, timeout: timeout, module: mod, function: fun}) do
    nodes = resolve_nodes(nodes_opt)

    case reachable(nodes) do
      nil ->
        if nodes == [] do
          Logger.debug("PluginPlug: no plugin nodes configured")
        else
          Logger.warning("PluginPlug: no plugin nodes reachable (tried #{inspect(nodes)})")
        end

        send_err(conn, 503, "plugin_unavailable")

      node ->
        case build_request(conn) do
          {:ok, req, conn} ->
            forward(conn, node, mod, fun, req, timeout)

          {:error, :body_too_large, conn} ->
            send_err(conn, 413, "request_body_too_large")

          {:error, reason, conn} ->
            Logger.warning("PluginPlug: read_body failed #{inspect(reason)}")
            send_err(conn, 400, "bad_request_body")
        end
    end
  end

  defp forward(conn, node, mod, fun, req, timeout) do
    case :rpc.call(node, mod, fun, [req], timeout) do
      {:ok, resp} ->
        respond(conn, resp)

      {:badrpc, reason} ->
        Logger.warning("PluginPlug: badrpc #{inspect(reason)} from #{node}")
        send_err(conn, 503, "plugin_rpc_failed")

      other ->
        Logger.warning("PluginPlug: unexpected response #{inspect(other)} from #{node}")
        send_err(conn, 500, "plugin_unexpected_response")
    end
  end

  defp build_request(conn) do
    # JSON / urlencoded は Plug.Parsers が済ませているので body_params を
    # JSON で詰め直して送る。multipart は :pass で素通ししてあるので
    # body_params は Unfetched — そのときだけ raw を読んで転送する
    # (api 側で自前 parse)。
    case conn.body_params do
      %Plug.Conn.Unfetched{} ->
        case read_raw_body(conn, @max_raw_body) do
          {:ok, body, conn} ->
            {:ok, request_map(conn, body), conn}

          {:error, reason, conn} ->
            {:error, reason, conn}
        end

      %{} = m ->
        # Plug.Parsers consumed the original body (JSON or form-urlencoded).
        # Re-encode as JSON and normalise the Content-Type header so that
        # api-node capabilities always see consistent application/json here.
        conn = Plug.Conn.put_req_header(conn, "content-type", "application/json")
        {:ok, request_map(conn, JSON.encode!(m)), conn}

      other ->
        {:ok, request_map(conn, to_string(other)), conn}
    end
  end

  defp request_map(conn, body) do
    %{
      method: conn.method,
      path: conn.request_path,
      query: conn.query_string || "",
      headers: conn.req_headers,
      body: body
    }
  end

  defp read_raw_body(conn, limit) do
    do_read_raw(conn, limit, "")
  end

  defp do_read_raw(conn, limit, acc) do
    case Plug.Conn.read_body(conn, length: limit) do
      {:ok, chunk, conn} ->
        body = acc <> chunk

        if byte_size(body) > limit do
          {:error, :body_too_large, conn}
        else
          {:ok, body, conn}
        end

      {:more, chunk, conn} ->
        body = acc <> chunk

        if byte_size(body) > limit do
          {:error, :body_too_large, conn}
        else
          do_read_raw(conn, limit, body)
        end

      {:error, reason} ->
        {:error, reason, conn}
    end
  end

  defp resolve_nodes(:runtime),
    do: Application.get_env(:sukhi_fedi, :plugin_nodes, [])

  defp resolve_nodes(list) when is_list(list), do: list

  defp reachable(nodes) do
    Enum.find(nodes, fn node ->
      node in Node.list() or Node.connect(node) == true
    end)
  end

  # public (not `defp`) so a test can drive it directly without a real
  # cross-node RPC round trip — the header-merging logic is the part worth
  # covering in isolation.
  @doc false
  def respond(conn, %{status: status, body: body, headers: headers}) do
    conn =
      Enum.reduce(headers || [], conn, fn {k, v}, c ->
        key = String.downcase(k)

        # put_resp_header/3 *replaces* same-key headers (List.keystore) — fine
        # for everything except set-cookie, where a capability legitimately
        # needs to set more than one cookie in the same response (the OAuth
        # multi-account picker sets session_token + session_tokens together).
        # A second set-cookie from put_resp_header would silently clobber the
        # first instead of adding a second Set-Cookie line.
        if key == "set-cookie" do
          prepend_resp_headers(c, [{key, v}])
        else
          put_resp_header(c, key, v)
        end
      end)

    conn
    |> send_resp(status, body)
    |> halt()
  end

  def respond(conn, other) do
    Logger.warning("PluginPlug: malformed response #{inspect(other)}")
    send_err(conn, 500, "plugin_response_malformed")
  end

  defp send_err(conn, status, code) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, JSON.encode!(%{error: code}))
    |> halt()
  end
end
