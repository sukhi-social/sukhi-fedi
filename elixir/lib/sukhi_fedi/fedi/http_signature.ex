# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Fedi.HttpSignature do
  @moduledoc """
  HTTP Signatures, pure functions. Two specs, one module:

    * draft-cavage-http-signatures-12 — what the Mastodon-family
      fediverse runs on. The default for everything we send.
    * RFC 9421 — what Fedify-based servers (hackers.pub, Hollo) prefer;
      they send it first and accept it back. `verify/6` auto-detects by
      the `Signature-Input` header, exactly like fedify's
      `verifyRequest`; `sign_post/5` takes `spec: :rfc9421` for the
      per-host override the delivery worker carries.

  Cavage signing mirrors what the Bun service produced: the
  Mastodon-compatible minimal header set `(request-target) host date
  digest content-type`, so proxies (Cloudflare) rewriting `accept` /
  `user-agent` can't break verification on the receiving side. RFC 9421
  signing mirrors fedify's component set: `@method @target-uri
  @authority host date content-digest`.

  Verification mirrors fedify's policy, with one deliberate extra: a
  body-bearing request must have its digest *covered by the signature*
  (`digest` in cavage, `content-digest` in 9421) — fedify's 9421 path
  only checks the digest when the sender chose to sign it, which would
  let a peer sign an uncontested header set and swap the body. Every
  real sender covers the digest, so the strictness costs no interop.

  No IO here: callers fetch keys (`Fedi.Verifier`) and do the HTTP
  (`delivery`); this module only builds and checks strings.
  """

  alias SukhiFedi.Fedi.JWK

  @time_window_seconds 3600
  # :calendar counts from year 0; Unix time from 1970.
  @gregorian_epoch :calendar.datetime_to_gregorian_seconds({{1970, 1, 1}, {0, 0, 0}})

  # ── Signing ──────────────────────────────────────────────────────────────

  @doc """
  Signs an outbound POST. Returns exactly the headers the caller must
  put on the request (the signature header(s) plus everything covered).
  `spec:` is `:cavage` (default) or `:rfc9421`.
  """
  @spec sign_post(String.t(), binary(), JWK.rsa_private_key(), String.t(), keyword()) ::
          %{String.t() => String.t()}
  def sign_post(url, body, private_key, key_id, opts \\ []) do
    case Keyword.get(opts, :spec, :cavage) do
      :rfc9421 -> sign_post_rfc9421(url, body, private_key, key_id, opts)
      :cavage -> sign_post_cavage(url, body, private_key, key_id)
    end
  end

  @doc """
  Signs an outbound GET (authorized fetch, for Mastodon Secure Mode /
  Misskey auth-fetch peers). Cavage — every current peer accepts it.
  """
  @spec sign_get(String.t(), JWK.rsa_private_key(), String.t()) ::
          %{String.t() => String.t()}
  def sign_get(url, private_key, key_id) do
    uri = URI.parse(url)
    headers = %{"host" => uri.host, "date" => http_date()}
    names = ["(request-target)", "host", "date"]
    attach_cavage_signature(headers, names, "get", request_target(uri), private_key, key_id)
  end

  @doc "Extracts the signing `keyId` from the request headers, either spec."
  @spec key_id(%{String.t() => String.t()}) :: {:ok, String.t()} | {:error, atom()}
  def key_id(headers) do
    if headers["signature-input"] do
      with {:ok, [{_label, input} | _]} <- parse_signature_input(headers["signature-input"]) do
        {:ok, input.key_id}
      end
    else
      with {:ok, params} <- parse_cavage_header(headers["signature"]) do
        case params["keyId"] do
          key_id when is_binary(key_id) and key_id != "" -> {:ok, key_id}
          _ -> {:error, :no_key_id}
        end
      end
    end
  end

  # ── Verification ─────────────────────────────────────────────────────────

  @doc """
  Verifies an inbound signed request against an already-fetched public
  key. `url` is the full public URL the peer signed against; `headers`
  must have lowercase names; `body` is the raw bytes. The spec is
  auto-detected: a `Signature-Input` header means RFC 9421, otherwise
  draft-cavage. `opts` accepts `:now` (Unix seconds) to pin the clock.
  """
  @spec verify(
          String.t(),
          String.t(),
          %{String.t() => String.t()},
          binary(),
          JWK.rsa_public_key(),
          keyword()
        ) :: :ok | {:error, atom()}
  def verify(method, url, headers, body, public_key, opts \\ []) do
    if headers["signature-input"] do
      verify_rfc9421(method, url, headers, body, public_key, opts)
    else
      verify_cavage(method, url, headers, body, public_key, opts)
    end
  end

  # ── Cavage: signing ──────────────────────────────────────────────────────

  defp sign_post_cavage(url, body, private_key, key_id) do
    uri = URI.parse(url)

    headers = %{
      "host" => uri.host,
      "date" => http_date(),
      "digest" => "SHA-256=" <> Base.encode64(:crypto.hash(:sha256, body)),
      "content-type" => "application/activity+json"
    }

    names = ["(request-target)", "host", "date", "digest", "content-type"]
    attach_cavage_signature(headers, names, "post", request_target(uri), private_key, key_id)
  end

  defp attach_cavage_signature(headers, names, method, path, private_key, key_id) do
    message = cavage_signing_string(names, method, path, headers, %{})
    signature = :public_key.sign(message, :sha256, private_key) |> Base.encode64()

    Map.put(
      headers,
      "signature",
      ~s(keyId="#{key_id}",algorithm="rsa-sha256",headers="#{Enum.join(names, " ")}",signature="#{signature}")
    )
  end

  # The `(request-target)` of a request: path *and* query. A signed GET to
  # a paged collection (`/users/x/outbox?page=true`) covers the query. The
  # signing string that omitted it no longer matched what the peer built,
  # so it answered 403 — which is how a paged outbox fetch silently came
  # back empty.
  defp request_target(%URI{path: path, query: query}) do
    base = path || "/"
    if query, do: base <> "?" <> query, else: base
  end

  # The signing string is the same on both sides: one `name: value` line
  # per covered header, in the order the `headers` field lists them.
  defp cavage_signing_string(names, method, path, headers, params) do
    names
    |> Enum.map(fn
      "(request-target)" -> "(request-target): #{String.downcase(method)} #{path}"
      "(created)" -> "(created): #{params["created"]}"
      "(expires)" -> "(expires): #{params["expires"]}"
      name -> "#{name}: #{Map.get(headers, name, "")}"
    end)
    |> Enum.join("\n")
  end

  # ── Cavage: verification ─────────────────────────────────────────────────

  defp verify_cavage(method, url, headers, body, public_key, opts) do
    path = request_target(URI.parse(url))

    with {:ok, params} <- parse_cavage_header(headers["signature"]),
         :ok <- require_cavage_fields(params),
         :ok <- check_date(headers["date"], opts),
         {:ok, digest_checked?} <- check_cavage_digest(method, headers["digest"], body),
         names = String.split(params["headers"], ~r/\s+/, trim: true),
         :ok <- check_cavage_coverage(names, digest_checked?),
         {:ok, signature} <- decode_base64(params["signature"]) do
      message = cavage_signing_string(names, method, path, headers, params)

      if :public_key.verify(message, :sha256, signature, public_key) do
        :ok
      else
        {:error, :bad_signature}
      end
    end
  end

  defp parse_cavage_header(value) when is_binary(value) and value != "" do
    params =
      Regex.scan(~r/([A-Za-z]+)=(?:"([^"]*)"|(\d+))/, value)
      |> Map.new(fn
        [_, key, quoted] -> {key, quoted}
        [_, key, "", num] -> {key, num}
      end)

    {:ok, params}
  end

  defp parse_cavage_header(_), do: {:error, :no_signature}

  defp require_cavage_fields(params) do
    if params["keyId"] && params["headers"] && params["signature"] do
      :ok
    else
      {:error, :missing_signature_fields}
    end
  end

  defp check_date(date, opts) when is_binary(date) do
    case :httpd_util.convert_request_date(String.to_charlist(date)) do
      {{_, _, _}, {_, _, _}} = erl_dt ->
        sent = :calendar.datetime_to_gregorian_seconds(erl_dt) - @gregorian_epoch
        check_window(sent, opts, :date_out_of_window)

      _ ->
        {:error, :bad_date}
    end
  end

  defp check_date(_, _opts), do: {:error, :no_date}

  # GET/HEAD have no body to bind; anything else must carry a digest and
  # it must match. Returns whether a digest was actually checked so
  # check_cavage_coverage/2 can insist the signature covers it.
  defp check_cavage_digest(method, digest_header, body) do
    cond do
      method in ~w(GET HEAD get head) and digest_header in [nil, ""] ->
        {:ok, false}

      digest_header in [nil, ""] ->
        {:error, :no_digest}

      true ->
        matched? =
          digest_header
          |> String.split(",")
          |> Enum.any?(fn pair ->
            case String.split(pair, "=", parts: 2) do
              [algo, value] -> digest_matches?(String.downcase(String.trim(algo)), value, body)
              _ -> false
            end
          end)

        if matched?, do: {:ok, true}, else: {:error, :digest_mismatch}
    end
  end

  defp digest_matches?("sha-256", value, body),
    do: value == Base.encode64(:crypto.hash(:sha256, body))

  defp digest_matches?("sha-512", value, body),
    do: value == Base.encode64(:crypto.hash(:sha512, body))

  defp digest_matches?(_algo, _value, _body), do: false

  defp check_cavage_coverage(names, digest_checked?) do
    cond do
      "(request-target)" not in names -> {:error, :request_target_not_signed}
      "date" not in names -> {:error, :date_not_signed}
      digest_checked? and "digest" not in names -> {:error, :digest_not_signed}
      true -> :ok
    end
  end

  # ── RFC 9421: signing ────────────────────────────────────────────────────

  defp sign_post_rfc9421(url, body, private_key, key_id, opts) do
    created = Keyword.get_lazy(opts, :now, fn -> System.system_time(:second) end)

    headers = %{
      "host" => authority(url),
      "date" => http_date(),
      "content-digest" => "sha-256=:#{Base.encode64(:crypto.hash(:sha256, body))}:",
      "content-type" => "application/activity+json"
    }

    components = ~w(@method @target-uri @authority host date content-digest)

    # `;`-joined signature parameters, in fedify's emission order. The
    # keyId is SF-string-escaped (quotes/backslashes).
    params =
      ~s(alg="rsa-v1_5-sha256";keyid="#{sf_escape(key_id)}";created=#{created})

    inner_list = ~s[(#{Enum.map_join(components, " ", &~s("#{&1}"))});#{params}]

    base =
      rfc9421_base_lines("POST", url, headers, components) <>
        ~s("@signature-params": #{inner_list})

    signature = :public_key.sign(base, :sha256, private_key) |> Base.encode64()

    headers
    |> Map.put("signature-input", "sig1=#{inner_list}")
    |> Map.put("signature", "sig1=:#{signature}:")
  end

  # ── RFC 9421: verification ───────────────────────────────────────────────

  defp verify_rfc9421(method, url, headers, body, public_key, opts) do
    with {:ok, inputs} <- parse_signature_input(headers["signature-input"]),
         {:ok, signatures} <- parse_rfc9421_signatures(headers["signature"]),
         {:ok, {input, signature}} <- pick_signature(inputs, signatures),
         :ok <- check_window(input.created, opts, :created_out_of_window),
         :ok <- check_expires(input.expires, opts),
         {:ok, hash} <- rfc9421_hash(input.alg),
         :ok <- check_rfc9421_digest(method, input.components, headers, body),
         {:ok, lines} <- safe_base_lines(method, url, headers, input.components) do
      # The last line reuses the Signature-Input value verbatim, so the
      # base is byte-identical to the signer's regardless of how it
      # ordered or escaped its parameters.
      base = lines <> ~s("@signature-params": #{input.raw})

      if :public_key.verify(base, hash, signature, public_key) do
        :ok
      else
        {:error, :bad_signature}
      end
    end
  end

  # Parses `sig1=("@method" "host");alg="...";keyid="...";created=1`,
  # possibly several comma-separated labels. `raw` keeps the exact
  # `(...);params` substring for base reconstruction.
  defp parse_signature_input(value) when is_binary(value) and value != "" do
    entries =
      ~r/([A-Za-z0-9_-]+)=(\(([^)]*)\)((?:;[A-Za-z0-9_-]+=(?:"(?:[^"\\]|\\.)*"|[0-9]+))*))/
      |> Regex.scan(value)
      |> Enum.map(fn [_, label, raw, inner, params] ->
        {label,
         %{
           raw: raw,
           components: parse_components(inner),
           key_id: sf_param_string(params, "keyid"),
           alg: sf_param_string(params, "alg"),
           created: sf_param_int(params, "created"),
           expires: sf_param_int(params, "expires")
         }}
      end)
      |> Enum.filter(fn {_label, input} ->
        input.components != :invalid and is_binary(input.key_id) and is_integer(input.created)
      end)

    case entries do
      [] -> {:error, :no_valid_signature_input}
      entries -> {:ok, entries}
    end
  end

  defp parse_signature_input(_), do: {:error, :no_signature}

  # Component identifiers are SF strings; identifiers with parameters
  # (`"@query-param";name="id"`) are not used by fediverse senders and
  # would make verbatim base reconstruction ambiguous — reject them.
  defp parse_components(inner) do
    names = Regex.scan(~r/"([^"]*)"/, inner) |> Enum.map(fn [_, name] -> name end)
    leftover = String.replace(inner, ~r/"[^"]*"/, "") |> String.replace(~r/\s/, "")
    if leftover == "" and names != [], do: names, else: :invalid
  end

  defp sf_param_string(params, key) do
    case Regex.run(~r/;#{key}="((?:[^"\\]|\\.)*)"/, params) do
      [_, value] -> value |> String.replace("\\\"", "\"") |> String.replace("\\\\", "\\")
      _ -> nil
    end
  end

  defp sf_param_int(params, key) do
    case Regex.run(~r/;#{key}=([0-9]+)/, params) do
      [_, value] -> String.to_integer(value)
      _ -> nil
    end
  end

  # `Signature: sig1=:base64:, sig2=:base64:`
  defp parse_rfc9421_signatures(value) when is_binary(value) and value != "" do
    signatures =
      ~r/([A-Za-z0-9_-]+)=:([A-Za-z0-9+\/=]+):/
      |> Regex.scan(value)
      |> Map.new(fn [_, label, b64] -> {label, b64} end)

    if map_size(signatures) > 0, do: {:ok, signatures}, else: {:error, :no_signature}
  end

  defp parse_rfc9421_signatures(_), do: {:error, :no_signature}

  # First label that appears in both headers — senders emit exactly one.
  defp pick_signature(inputs, signatures) do
    Enum.find_value(inputs, {:error, :no_matching_signature}, fn {label, input} ->
      with b64 when is_binary(b64) <- signatures[label],
           {:ok, signature} <- decode_base64(b64) do
        {:ok, {input, signature}}
      else
        _ -> nil
      end
    end)
  end

  defp check_expires(nil, _opts), do: :ok

  defp check_expires(expires, opts) do
    now = Keyword.get_lazy(opts, :now, fn -> System.system_time(:second) end)
    if now <= expires, do: :ok, else: {:error, :signature_expired}
  end

  defp rfc9421_hash(nil), do: {:ok, :sha256}
  defp rfc9421_hash("rsa-v1_5-sha256"), do: {:ok, :sha256}
  defp rfc9421_hash("rsa-v1_5-sha512"), do: {:ok, :sha512}
  defp rfc9421_hash(_), do: {:error, :unsupported_algorithm}

  # Body-bearing requests must have a covered, matching Content-Digest.
  defp check_rfc9421_digest(method, components, headers, body) do
    cond do
      method in ~w(GET HEAD get head) ->
        :ok

      "content-digest" not in components ->
        {:error, :digest_not_signed}

      true ->
        matched? =
          (headers["content-digest"] || "")
          |> String.split(",")
          |> Enum.any?(fn item ->
            case Regex.run(~r/^\s*([a-zA-Z0-9-]+)=:([A-Za-z0-9+\/=]+):\s*$/, item) do
              [_, algo, value] -> digest_matches?(String.downcase(algo), value, body)
              _ -> false
            end
          end)

        if matched?, do: :ok, else: {:error, :digest_mismatch}
    end
  end

  defp safe_base_lines(method, url, headers, components) do
    {:ok, rfc9421_base_lines(method, url, headers, components)}
  rescue
    # A derived component we don't support or a missing header.
    error in [ArgumentError] -> {:error, String.to_atom(error.message)}
  end

  defp rfc9421_base_lines(method, url, headers, components) do
    Enum.map_join(components, fn name ->
      ~s("#{name}": #{component_value(name, method, url, headers)}\n)
    end)
  end

  defp component_value("@method", method, _url, _headers), do: String.upcase(method)
  defp component_value("@target-uri", _method, url, _headers), do: url
  defp component_value("@authority", _method, url, _headers), do: authority(url)
  defp component_value("@scheme", _method, url, _headers), do: URI.parse(url).scheme
  defp component_value("@path", _method, url, _headers), do: URI.parse(url).path || "/"

  defp component_value("@query", _method, url, _headers), do: URI.parse(url).query || ""

  defp component_value("@request-target", method, url, _headers) do
    "#{String.downcase(method)} #{request_target(URI.parse(url))}"
  end

  defp component_value("@" <> _ = name, _method, _url, _headers),
    do: raise(ArgumentError, "unsupported_component_#{name}")

  defp component_value(name, _method, _url, headers) do
    case Map.get(headers, name) do
      value when is_binary(value) -> value
      _ -> raise(ArgumentError, "missing_header_#{name}")
    end
  end

  # JS `url.host`: hostname plus port, default port omitted.
  defp authority(url) do
    uri = URI.parse(url)

    case {uri.scheme, uri.port} do
      {"https", 443} -> uri.host
      {"http", 80} -> uri.host
      {_, nil} -> uri.host
      {_, port} -> "#{uri.host}:#{port}"
    end
  end

  defp sf_escape(value) do
    value |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")
  end

  # ── Shared ───────────────────────────────────────────────────────────────

  defp check_window(sent, opts, error) do
    now = Keyword.get_lazy(opts, :now, fn -> System.system_time(:second) end)
    if abs(now - sent) <= @time_window_seconds, do: :ok, else: {:error, error}
  end

  defp decode_base64(value) do
    case Base.decode64(value) do
      {:ok, decoded} -> {:ok, decoded}
      :error -> {:error, :bad_signature_encoding}
    end
  end

  defp http_date do
    Calendar.strftime(DateTime.utc_now(), "%a, %d %b %Y %H:%M:%S GMT")
  end
end
