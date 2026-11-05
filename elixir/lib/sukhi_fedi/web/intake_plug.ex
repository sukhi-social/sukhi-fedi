# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Web.IntakePlug do
  @moduledoc """
  The one door for "are we taking anything new in?" on the HTTP side.

  While `SukhiShared.Intake` is closed, every request that could change
  something is refused here, before its body is read, with `503` and a
  `Retry-After`: Mastodon-style writes (`POST /api/v1/statuses`, …), logins,
  uploads, and the federation inboxes. The inbox answer matters most. A
  `202` would tell the sender the activity landed; a `5xx` makes a
  well-behaved server keep it and try again after the maintenance, so
  nothing is lost on the way.

  Only `GET`, `HEAD` and `OPTIONS` pass: reading stays open, which is what
  lets people see a read-only server rather than a dead one, and keeps
  CORS preflights answerable. The rule is the method, not a list of paths,
  so a write route added next year is gated without anyone remembering to
  add it here. The one thing the gate does not own is *which* GETs write
  (none are meant to; a GET that does is a bug of its own).

  It sits in the router after the rate limiter and before the body parser:
  a flood still meets `429`, and a refused request never has its body read.
  """

  import Plug.Conn

  alias SukhiShared.Intake

  @behaviour Plug

  @reads ~w(GET HEAD OPTIONS)

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{method: method} = conn, _opts) when method in @reads, do: conn

  def call(conn, _opts) do
    case Intake.closed?() do
      false -> conn
      true -> refuse(conn)
    end
  end

  defp refuse(conn) do
    retry_after = Intake.retry_after_s()

    conn
    |> put_resp_header("retry-after", Integer.to_string(retry_after))
    |> put_resp_header("x-sukhi-intake", "closed")
    |> put_resp_content_type("application/json")
    |> send_resp(503, JSON.encode!(%{error: "maintenance", retry_after: retry_after}))
    |> halt()
  end
end
