# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Web.PullFederationController do
  @moduledoc """
  HTTP for Pull Federation (docs/PULL_FEDERATION.md). Transport only
  (CODE_STYLE §1): parse, authenticate once through `Web.SignedRequest`,
  hand to `PullFederation.Notify` / `PullFederation.Serve`, map the outcome
  to a status. Both endpoints answer `404` when we do not advertise the
  capability, so a server that turned it off looks like one that never had it.
  """

  import Plug.Conn

  alias SukhiFedi.PullFederation.{Gate, Notify, Serve}
  alias SukhiFedi.Web.SignedRequest
  alias SukhiShared.{Capability, PullStats}

  @spec notify(Plug.Conn.t(), term()) :: Plug.Conn.t()
  def notify(conn, _opts) do
    with :ok <- enabled(conn),
         {:ok, signer} <- authenticate(conn, "POST"),
         {:ok, origin, heads} <-
           Notify.parse(conn.body_params) |> or_status(400, "bad notification"),
         :ok <- bound(signer, origin),
         :ok <- allowed(origin) do
      case Notify.accept(origin, heads) do
        {:ok, _n} ->
          SukhiFedi.PullFederation.Puller.wake()
          send_json(conn, 202, %{})

        {:dropped, :rate_floor} ->
          conn |> put_resp_header("retry-after", "1") |> send_json(429, %{error: "rate_limited"})

        {:dropped, :nothing_wanted} ->
          # Nothing there is for us (nobody here follows those actors, or we
          # already have it). Not an error: the sender did nothing wrong.
          send_json(conn, 202, %{})
      end
    else
      {:status, status, message} -> send_json(conn, status, %{error: message})
    end
  end

  @spec stream(Plug.Conn.t(), term()) :: Plug.Conn.t()
  def stream(conn, _opts) do
    with :ok <- enabled(conn),
         {:ok, signer} <- authenticate(conn, "GET"),
         :ok <- allowed(signer) do
      cursors = Serve.parse_cursors(conn.query_string)
      domain = Application.get_env(:sukhi_fedi, :domain) || conn.host
      started = System.monotonic_time(:millisecond)

      result = Gate.with_slot(fn -> Serve.page(signer, cursors, domain) end)

      case result do
        {:busy, retry_after} ->
          PullStats.bump("stream_declined", host: signer)

          conn
          |> put_resp_header("retry-after", Integer.to_string(retry_after))
          |> send_json(429, %{error: "busy", retry_after: retry_after})

        {:ok, page} ->
          PullStats.bump("stream_served",
            ms: System.monotonic_time(:millisecond) - started,
            host: signer
          )

          send_json(conn, 200, page)

        {:error, :denied} ->
          send_json(conn, 403, %{error: "no followers of the requested actors on this host"})
      end
    else
      {:status, status, message} -> send_json(conn, status, %{error: message})
    end
  end

  # ── gates, each in one place ─────────────────────────────────────────────

  defp enabled(_conn) do
    if Capability.advertised?(), do: :ok, else: {:status, 404, "not found"}
  end

  defp authenticate(conn, method) do
    sign_as = SukhiFedi.Accounts.signing_identity()

    case SignedRequest.verify(conn, method, sign_as) do
      {:ok, %{signer_host: host}} when is_binary(host) ->
        {:ok, host}

      {:ok, _} ->
        PullStats.bump("stream_denied")
        {:status, 401, "no signer"}

      :unverified ->
        PullStats.bump("stream_denied")
        {:status, 401, "signature verification failed"}

      {:error, reason} ->
        {:status, 400, inspect(reason)}
    end
  end

  # The notification names an origin; the key that signed it must be that
  # origin's. Otherwise any host could notify as any other.
  defp bound(signer, origin) do
    if signer == origin, do: :ok, else: {:status, 403, "signer is not the origin"}
  end

  # A suspended instance gets nothing, in either direction.
  defp allowed(host) do
    if SukhiFedi.Addons.Moderation.instance_policy(host) == :reject,
      do: {:status, 403, "forbidden"},
      else: :ok
  end

  defp or_status({:ok, _, _} = ok, _status, _message), do: ok
  defp or_status({:error, _}, status, message), do: {:status, status, message}

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, JSON.encode!(body))
  end
end
