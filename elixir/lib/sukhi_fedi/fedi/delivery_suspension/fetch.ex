# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Fedi.DeliverySuspension.Fetch do
  @moduledoc """
  The one way FEP-f799 reads a document from another server: a notice, an
  actor, an inbox collection, a WebFinger answer. Built on `HttpFetch` (so the
  address is the one `UrlGuard` checked, and the body is capped while it
  streams), narrowed to what these documents are:

    * HTTPS only, every hop. A redirect is followed up to `max_redirects` times
      (the policy's 3), each target checked again; the answer says which URL it
      finally came from.
    * No signature. These are public documents; a server that answers only
      signed GETs is `:unauthorized`, which for f799 is the same as "could not
      read it".
    * 64 KiB and nesting 8 (the policy), 10 seconds a request.
    * `Accept` by kind, and a `Content-Type` of either form is taken: a static
      host answers `application/activity+json` whatever was asked.
    * Conditional with `etag:`. A `304` is `:not_modified` and nothing more:
      it says the bytes did not change, not that anyone may still speak for
      anything. Callers that need authority fetch without `etag:`.

  Failures are named by what they mean for f799, not by status:
  `:unauthorized` (401/403), `:gone` (404/410), `:unavailable` (anything else
  that is not an answer), `:too_large`, `:unsafe_target` (not HTTPS, or the
  host is not a public address), `:bad_document`. For f799 the first three are
  one thing (could not read it: neither a cancellation nor an extension); they
  are separate only so the log can tell them apart.

  Nothing here caches or joins requests: authority is read fresh every time.
  """

  alias SukhiFedi.Fedi.HttpFetch
  alias SukhiShared.DeliverySuspension.{Origin, Policy}

  @accept_activity ~s(application/activity+json, application/ld+json; profile="https://www.w3.org/ns/activitystreams")
  @accept_jrd "application/jrd+json, application/json;q=0.8"

  @type kind :: :activity | :webfinger
  @type failure ::
          :unauthorized | :gone | :unavailable | :too_large | :unsafe_target | :bad_document
  @type http :: (String.t(), [{String.t(), String.t()}] -> {:ok, map()} | {:error, term()})
  @type ok :: %{document: map(), etag: String.t() | nil, url: String.t()}

  @doc """
  GET `url`. Options: `:etag` (send `If-None-Match`), `:policy`, and `:http`,
  a function standing in for the transport (tests).
  """
  @spec get(String.t(), kind(), keyword()) :: {:ok, ok()} | :not_modified | {:error, failure()}
  def get(url, kind, opts \\ []) when kind in [:activity, :webfinger] do
    policy = Keyword.get(opts, :policy, Policy.default())
    http = Keyword.get(opts, :http) || default_http(policy)

    headers =
      [{"accept", accept(kind)}] ++
        case opts[:etag] do
          etag when is_binary(etag) -> [{"if-none-match", etag}]
          _ -> []
        end

    follow(url, headers, http, policy, policy.max_redirects)
  end

  defp accept(:activity), do: @accept_activity
  defp accept(:webfinger), do: @accept_jrd

  defp default_http(policy) do
    fn url, headers ->
      HttpFetch.capped_get(url,
        headers: headers,
        max_bytes: policy.notice_max_bytes,
        receive_timeout: policy.fetch_timeout_ms,
        connect_timeout: policy.fetch_timeout_ms
      )
    end
  end

  defp follow(url, headers, http, policy, hops_left) do
    with :ok <- https(url),
         {:ok, response} <- request(http, url, headers) do
      answer(response, url, headers, http, policy, hops_left)
    end
  end

  defp https(url) do
    case {URI.parse(url), Origin.of_delivery_url(url)} do
      {%URI{scheme: "https"}, {:ok, _origin}} -> :ok
      _ -> {:error, :unsafe_target}
    end
  end

  defp request(http, url, headers) do
    case http.(url, headers) do
      {:ok, %{status: _} = response} -> {:ok, response}
      {:error, :document_too_large} -> {:error, :too_large}
      {:error, reason} when reason in [:unsafe_address, :bad_url] -> {:error, :unsafe_target}
      {:error, _} -> {:error, :unavailable}
    end
  end

  defp answer(%{status: 200} = response, url, _headers, _http, policy, _hops_left) do
    with :ok <- content_type(response),
         {:ok, document} <- decode(response.body, policy) do
      {:ok, %{document: document, etag: header(response, "etag"), url: url}}
    end
  end

  defp answer(%{status: 304}, _url, headers, _http, _policy, _hops_left) do
    if List.keymember?(headers, "if-none-match", 0),
      do: :not_modified,
      else: {:error, :unavailable}
  end

  defp answer(%{status: status} = response, url, headers, http, policy, hops_left)
       when status in [301, 302, 303, 307, 308] do
    with true <- hops_left > 0,
         location when is_binary(location) <- header(response, "location") do
      follow(URI.merge(url, location) |> URI.to_string(), headers, http, policy, hops_left - 1)
    else
      _ -> {:error, :unavailable}
    end
  end

  defp answer(%{status: status}, _url, _headers, _http, _policy, _hops_left)
       when status in [401, 403],
       do: {:error, :unauthorized}

  defp answer(%{status: status}, _url, _headers, _http, _policy, _hops_left)
       when status in [404, 410],
       do: {:error, :gone}

  defp answer(%{status: _}, _url, _headers, _http, _policy, _hops_left),
    do: {:error, :unavailable}

  # The AS2 media types in either form, JRD, and plain JSON.
  defp content_type(response) do
    type =
      response
      |> header("content-type")
      |> to_string()
      |> String.downcase()
      |> String.split(";", parts: 2)
      |> hd()
      |> String.trim()

    if type in [
         "application/activity+json",
         "application/ld+json",
         "application/jrd+json",
         "application/json"
       ],
       do: :ok,
       else: {:error, :bad_document}
  end

  defp decode(body, policy) when is_binary(body) do
    with true <- byte_size(body) <= policy.notice_max_bytes,
         {:ok, %{} = document} <-
           HttpFetch.decode_json(body, max_depth: policy.notice_max_depth) do
      {:ok, document}
    else
      _ -> {:error, :bad_document}
    end
  end

  defp decode(_body, _policy), do: {:error, :bad_document}

  # Response headers are a map of lists (Req) or a list of pairs.
  defp header(%{headers: headers}, name) when is_map(headers) do
    case Map.get(headers, name) do
      [value | _] -> value
      value when is_binary(value) -> value
      _ -> nil
    end
  end

  defp header(%{headers: headers}, name) when is_list(headers) do
    Enum.find_value(headers, fn {k, v} -> if String.downcase(to_string(k)) == name, do: v end)
  end

  defp header(_response, _name), do: nil
end
