# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Fedi.HttpFetch do
  @moduledoc """
  The one door for outbound federation **document** fetches (AP documents,
  WebFinger JRD, NodeInfo, link-preview HTML, Misskey's read-only JSON API).
  Three properties live here and nowhere else (CODE_STYLE §0):

    * **The address is the one we checked.** The host is resolved once by
      `SukhiShared.UrlGuard.public_addrs/1`, which refuses a name if any of
      its addresses is internal, and the connection goes to *those* addresses
      — not to whatever the name resolves to a moment later. That closes the
      DNS-rebinding window between "is this host public?" and "connect".
      TLS still verifies the certificate against the host name (`:hostname`),
      so connecting to an IP does not weaken it.
    * **The body is capped** at `@max_bytes` while it streams in, so a hostile
      peer cannot push gigabytes into BEAM memory before we decode anything.
    * **JSON is bounded in depth**, checked on the raw bytes before a
      decoder allocates anything (`decode_json/1`).

  A fetch is one HTTP/1.1 request on its own connection: no redirect is
  followed (the caller re-checks every hop and re-signs), no hidden retry
  (a `429` / `503` + `Retry-After` is the caller's to act on), and no pool —
  a pool is keyed by host *name*, which is exactly what pinning must not
  trust. Documents are cached upstream, so the extra handshake is paid
  rarely. The media proxy keeps its own transport and its much larger cap:
  it streams real media, not documents.

  The caller passes only what a fetch needs (see `t:opts/0`); an option this
  module does not act on is an `ArgumentError`, not silently ignored.

  The two limits are ceilings a caller may **lower**, never raise: a small
  document (a delivery-suspension notice is 64 KiB, nesting 8) asks for
  `max_bytes:` / `max_depth:` below the defaults, and a value above them is
  clamped to them. The ceilings stay in this one file.
  """

  alias SukhiShared.UrlGuard

  @max_bytes 1024 * 1024
  # A JSON-LD AP document nests a handful of levels (activity → object →
  # attachment → …). 32 leaves room for that and for extension vocabularies,
  # and refuses the `[[[[…` that costs a megabyte of input and a lot of heap.
  @max_json_depth 32
  # The per-read timeout is the caller's `receive_timeout`; this bounds the
  # whole response, so a peer dribbling a byte at a time cannot hold us.
  @total_timeout_ms 30_000
  @default_timeout_ms 15_000

  @type opts :: [
          headers: [{String.t(), String.t()}] | %{optional(String.t()) => String.t()},
          json: term(),
          receive_timeout: pos_integer(),
          connect_timeout: pos_integer(),
          max_bytes: pos_integer()
        ]

  @doc """
  GET `url`. Returns the `Req.Response` (raw binary body), or
  `{:error, :document_too_large}`, `{:error, :unsafe_address}` (the host
  resolves to nothing, or to an internal address), `{:error, :bad_url}`, or
  `{:error, %Req.TransportError{}}`.
  """
  @spec capped_get(String.t(), opts()) :: {:ok, Req.Response.t()} | {:error, term()}
  def capped_get(url, opts \\ []) when is_binary(url) and is_list(opts),
    do: request("GET", url, opts)

  @doc """
  POST (`json:` is encoded as the body) — for the few read-only JSON APIs
  that only answer POST (Misskey's `users/show`). Same pin, same cap.
  """
  @spec capped_post(String.t(), opts()) :: {:ok, Req.Response.t()} | {:error, term()}
  def capped_post(url, opts \\ []) when is_binary(url) and is_list(opts),
    do: request("POST", url, opts)

  @doc """
  Decode a fetched JSON document. The nesting depth is checked on the bytes
  first (`json_depth_ok?/2`); only a body that passes reaches the decoder.
  Returns `{:error, :json_too_deep}` for one that does not.

  `max_depth:` lowers the limit for a caller whose documents are small (it is
  clamped to the ceiling, see the moduledoc).
  """
  @spec decode_json(binary(), keyword()) :: {:ok, term()} | {:error, term()}
  def decode_json(body, opts \\ []) when is_binary(body) and is_list(opts) do
    if json_depth_ok?(body, opts), do: JSON.decode(body), else: {:error, :json_too_deep}
  end

  @doc """
  True when `body` never nests arrays/objects deeper than the limit. A single
  pass over the bytes that knows about strings and escapes, so a `[` inside a
  string is not a level. It does not validate JSON — the decoder does that —
  it only decides whether the decoder may run.
  """
  @spec json_depth_ok?(binary(), keyword()) :: boolean()
  def json_depth_ok?(body, opts \\ []) when is_binary(body) and is_list(opts) do
    limit = opts |> Keyword.get(:max_depth, @max_json_depth) |> min(@max_json_depth)
    depth_ok?(body, 0, limit, false, false)
  end

  defp depth_ok?(<<>>, _depth, _limit, _in_string, _escaped), do: true

  # inside a string: an escaped byte is skipped, a bare quote ends it
  defp depth_ok?(<<_, rest::binary>>, depth, limit, true, true),
    do: depth_ok?(rest, depth, limit, true, false)

  defp depth_ok?(<<?\\, rest::binary>>, depth, limit, true, false),
    do: depth_ok?(rest, depth, limit, true, true)

  defp depth_ok?(<<?", rest::binary>>, depth, limit, true, false),
    do: depth_ok?(rest, depth, limit, false, false)

  defp depth_ok?(<<_, rest::binary>>, depth, limit, true, false),
    do: depth_ok?(rest, depth, limit, true, false)

  # outside a string
  defp depth_ok?(<<?", rest::binary>>, depth, limit, false, _),
    do: depth_ok?(rest, depth, limit, true, false)

  defp depth_ok?(<<open, rest::binary>>, depth, limit, false, _) when open in [?[, ?{] do
    depth + 1 <= limit and depth_ok?(rest, depth + 1, limit, false, false)
  end

  defp depth_ok?(<<close, rest::binary>>, depth, limit, false, _) when close in [?], ?}],
    do: depth_ok?(rest, max(depth - 1, 0), limit, false, false)

  defp depth_ok?(<<_, rest::binary>>, depth, limit, false, _),
    do: depth_ok?(rest, depth, limit, false, false)

  # ── transport ────────────────────────────────────────────────────────────

  defp request(method, url, opts) do
    opts =
      Keyword.validate!(opts, [
        :json,
        headers: [],
        receive_timeout: @default_timeout_ms,
        connect_timeout: @default_timeout_ms,
        max_bytes: @max_bytes
      ])

    with {:ok, %URI{scheme: scheme, host: host} = uri} when scheme in ["http", "https"] <-
           parse(url),
         {:ok, addrs} <- addresses(host) do
      deadline = System.monotonic_time(:millisecond) + @total_timeout_ms
      {headers, body} = build(opts)

      connect_and_send(addrs, uri, method, headers, body, opts, deadline)
    else
      {:ok, %URI{}} -> {:error, :bad_url}
      {:error, _} = error -> error
    end
  end

  defp parse(url) do
    case URI.parse(url) do
      %URI{host: host} = uri when is_binary(host) and host != "" -> {:ok, uri}
      %URI{} -> {:error, :bad_url}
    end
  end

  defp addresses(host) do
    case UrlGuard.public_addrs(host) do
      {:ok, addrs} -> {:ok, addrs}
      :error -> {:error, :unsafe_address}
    end
  end

  defp build(opts) do
    headers =
      opts
      |> Keyword.fetch!(:headers)
      |> Enum.map(fn {k, v} -> {String.downcase(to_string(k)), to_string(v)} end)

    case Keyword.fetch(opts, :json) do
      {:ok, term} ->
        {[{"content-type", "application/json"} | headers],
         IO.iodata_to_binary(JSON.encode_to_iodata!(term))}

      :error ->
        {headers, nil}
    end
  end

  # Try each checked address in turn (v4 first, as `UrlGuard` lists them): a
  # host with a dead AAAA record must not make the document unreachable.
  defp connect_and_send([addr | rest], uri, method, headers, body, opts, deadline) do
    case connect(addr, uri, opts) do
      {:ok, conn} ->
        exchange(conn, uri, method, headers, body, opts, deadline)

      {:error, reason} when rest == [] ->
        {:error, %Req.TransportError{reason: transport_reason(reason)}}

      {:error, _} ->
        connect_and_send(rest, uri, method, headers, body, opts, deadline)
    end
  end

  defp connect(addr, %URI{scheme: scheme, host: host} = uri, opts) do
    scheme = String.to_existing_atom(scheme)
    port = uri.port || if(scheme == :https, do: 443, else: 80)

    transport_opts =
      [timeout: Keyword.fetch!(opts, :connect_timeout)] ++
        if(tuple_size(addr) == 8, do: [inet6: true], else: [])

    Mint.HTTP.connect(scheme, addr |> :inet.ntoa() |> to_string(), port,
      hostname: host,
      mode: :passive,
      protocols: [:http1],
      transport_opts: transport_opts
    )
  end

  defp exchange(conn, uri, method, headers, body, opts, deadline) do
    target = (uri.path || "/") <> if(uri.query, do: "?" <> uri.query, else: "")

    result =
      with {:ok, conn, ref} <- Mint.HTTP.request(conn, method, target, headers, body),
           {:ok, conn, response} <-
             read(conn, ref, %{status: nil, headers: [], body: ""}, opts, deadline) do
        _ = Mint.HTTP.close(conn)
        {:ok, response}
      else
        {:error, conn, reason} when is_struct(conn) -> close_with(conn, reason)
        {:error, reason} -> {:error, reason}
      end

    case result do
      {:ok, %{status: status, headers: headers, body: body}} ->
        {:ok, Req.Response.new(status: status, headers: headers, body: body)}

      {:error, :document_too_large} = too_large ->
        too_large

      {:error, reason} ->
        {:error, %Req.TransportError{reason: transport_reason(reason)}}
    end
  end

  defp close_with(conn, reason) do
    _ = Mint.HTTP.close(conn)
    {:error, reason}
  end

  defp read(conn, ref, acc, opts, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)
    timeout = min(Keyword.fetch!(opts, :receive_timeout), max(remaining, 0))

    if remaining <= 0 do
      close_with(conn, :timeout)
    else
      case Mint.HTTP.recv(conn, 0, timeout) do
        {:ok, conn, responses} -> fold(responses, conn, ref, acc, opts, deadline)
        {:error, conn, reason, _responses} -> close_with(conn, reason)
      end
    end
  end

  defp fold([], conn, ref, acc, opts, deadline), do: read(conn, ref, acc, opts, deadline)

  defp fold([{:status, ref, status} | rest], conn, ref, acc, opts, deadline),
    do: fold(rest, conn, ref, %{acc | status: status}, opts, deadline)

  defp fold([{:headers, ref, headers} | rest], conn, ref, acc, opts, deadline),
    do: fold(rest, conn, ref, %{acc | headers: acc.headers ++ headers}, opts, deadline)

  defp fold([{:data, ref, data} | rest], conn, ref, acc, opts, deadline) do
    body = acc.body <> data

    if byte_size(body) > min(Keyword.fetch!(opts, :max_bytes), @max_bytes) do
      close_with(conn, :document_too_large)
    else
      fold(rest, conn, ref, %{acc | body: body}, opts, deadline)
    end
  end

  defp fold([{:done, ref} | _], conn, ref, acc, _opts, _deadline), do: {:ok, conn, acc}

  defp fold([{:error, ref, reason} | _], conn, ref, _acc, _opts, _deadline),
    do: close_with(conn, reason)

  defp transport_reason(%{reason: reason}), do: transport_reason(reason)
  defp transport_reason(reason), do: reason
end
