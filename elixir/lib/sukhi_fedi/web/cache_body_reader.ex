# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Web.CacheBodyReader do
  @moduledoc """
  Body reader for `Plug.Parsers` that stashes the unparsed bytes in
  `conn.assigns.raw_body` so downstream handlers (HTTP-Signature
  verification) can see exactly what the remote server signed.

  It is also where **an inbound JSON body is bounded before any decoder runs**
  (CODE_STYLE §0: the one place). `Plug.Parsers` hands the bytes to Jason as
  soon as this returns, so a refusal has to happen here:

    * a JSON body nested deeper than `HttpFetch`'s ceiling is refused with
      `400` (`TooDeepError`) — the same byte scan the fetch side uses, so
      "how deep may a document nest" has one answer for what we fetch and
      what is pushed to us;
    * a request to an inbox (`…/inbox`) may carry at most `@inbox_max_bytes`.
      The router's default is 8 MB, which is for uploads and API bodies; an
      ActivityPub activity is a few KiB, and the inbox is open to anyone who
      can sign a request. Over the cap is `413`, from `Plug.Parsers` itself.
  """

  require Logger

  alias SukhiFedi.Fedi.HttpFetch

  # The same ceiling the fetch side has for one document.
  @inbox_max_bytes 1024 * 1024

  defmodule TooDeepError do
    @moduledoc "A JSON body nests deeper than we decode. Answered as `400`."
    defexception message: "JSON nesting too deep", plug_status: 400
  end

  def read_body(conn, opts) do
    case Plug.Conn.read_body(conn, limit(conn, opts)) do
      {:ok, body, conn} ->
        check_depth!(conn, body)
        conn = update_in(conn.assigns[:raw_body], fn prev -> (prev || "") <> body end)
        {:ok, body, conn}

      # Over the cap, or a transport error: Plug.Parsers turns these into 413 / 400.
      other ->
        other
    end
  end

  defp limit(conn, opts) do
    if inbox?(conn),
      do: Keyword.update(opts, :length, @inbox_max_bytes, &min(&1, @inbox_max_bytes)),
      else: opts
  end

  defp inbox?(%Plug.Conn{request_path: path}), do: String.ends_with?(path, "/inbox")

  defp check_depth!(conn, body) do
    if json?(conn) and not HttpFetch.json_depth_ok?(body) do
      Logger.warning("inbound JSON refused: nesting too deep (#{conn.request_path})")
      raise TooDeepError
    end

    :ok
  end

  # `application/json`, `application/activity+json`, `…ld+json; profile=…`:
  # whatever `Plug.Parsers.JSON` would hand to the decoder.
  defp json?(conn) do
    conn
    |> Plug.Conn.get_req_header("content-type")
    |> Enum.any?(fn type -> type |> String.downcase() |> String.contains?("json") end)
  end
end
