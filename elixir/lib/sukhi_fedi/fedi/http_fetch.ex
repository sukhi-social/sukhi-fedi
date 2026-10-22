# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Fedi.HttpFetch do
  @moduledoc """
  Body-size cap for outbound federation document fetches (AP documents,
  WebFinger JRD, NodeInfo).

  These documents are tiny, but a hostile or buggy peer can stream a
  multi-GB response into BEAM memory before we ever decode it. `capped_get/2`
  wraps `Req.get/2` with a streaming collector that stops downloading past
  `@max_bytes` and turns an over-limit response into
  `{:error, :document_too_large}`.

  The cap predicate lives here only (CODE_STYLE §0): every document fetch
  path routes through `capped_get/2` instead of calling `Req.get/2`
  directly, so the limit can't be forgotten at one call site. The media
  proxy keeps its own, much larger cap — it streams real media, not
  documents.

  The caller passes its own request options (headers, `redirect: false`,
  timeouts, finch); this only adds the cap. Because the body is streamed
  through the collector, the response `body` is always the raw binary
  (Req does not auto-decode JSON under `into:`), so callers decode it
  themselves.
  """

  @max_bytes 1024 * 1024

  @doc """
  Like `Req.get/2` but caps the response body at `@max_bytes`. Returns the
  `Req.Response` on success, `{:error, :document_too_large}` when the peer
  sent more than the cap, or whatever `Req.get/2` would return otherwise.
  """
  @spec capped_get(String.t(), keyword()) :: {:ok, Req.Response.t()} | {:error, term()}
  def capped_get(url, opts) when is_binary(url) and is_list(opts), do: capped(:get, url, opts)

  @doc """
  Like `capped_get/2` for a POST — for the few read-only JSON APIs that only
  answer POST (Misskey's `users/show`). Same cap, same return shape.
  """
  @spec capped_post(String.t(), keyword()) :: {:ok, Req.Response.t()} | {:error, term()}
  def capped_post(url, opts) when is_binary(url) and is_list(opts), do: capped(:post, url, opts)

  defp capped(method, url, opts) do
    opts = Keyword.merge([method: method, url: url, decode_body: false, into: &cap_body/2], opts)

    case Req.request(opts) do
      {:ok, %Req.Response{body: :too_large}} -> {:error, :document_too_large}
      other -> other
    end
  end

  # @max_bytes を超えたら降ろすのをやめ、body を :too_large に差し替える。
  # capped_get/2 がそれを {:error, :document_too_large} に翻訳する。
  defp cap_body({:data, data}, {req, resp}) do
    body = resp.body <> data

    if byte_size(body) > @max_bytes do
      {:halt, {req, %{resp | body: :too_large}}}
    else
      {:cont, {req, %{resp | body: body}}}
    end
  end
end
