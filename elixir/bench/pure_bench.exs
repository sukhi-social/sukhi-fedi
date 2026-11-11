# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Benchmarks for the pure paths: no DB, no NATS, no network. The inputs are
# fixed, so each run does the same work.
#
#   cd elixir && mix run --no-start bench/pure_bench.exs
#
# Outside CodSpeed this is plain Benchee (the console table). Under CodSpeed
# (`codspeed run -m walltime -- mix run --no-start bench/pure_bench.exs`) the
# same script also writes the results file and marks each scenario for the
# profiler. See .github/workflows/codspeed.yml.

alias SukhiFedi.Fedi.Canon
alias SukhiShared.{HttpSignature, JWK}

# ── HTTP signatures ────────────────────────────────────────────────────────

b64 = fn int -> int |> :binary.encode_unsigned() |> Base.url_encode64(padding: false) end

# A fresh key each run. Signing time does not depend on the key's value.
{:RSAPrivateKey, _, n, e, d, p, q, dp, dq, qi, _} = :public_key.generate_key({:rsa, 2048, 65_537})

jwk = %{
  "kty" => "RSA",
  "n" => b64.(n),
  "e" => b64.(e),
  "d" => b64.(d),
  "p" => b64.(p),
  "q" => b64.(q),
  "dp" => b64.(dp),
  "dq" => b64.(dq),
  "qi" => b64.(qi)
}

{:ok, private_key} = JWK.private_key(jwk)
public_key = {:RSAPublicKey, n, e}

url = "https://remote.example/inbox"
key_id = "https://sukhi.example/users/alice#main-key"

note = %{
  "@context" => [
    "https://www.w3.org/ns/activitystreams",
    "https://w3id.org/security/v1"
  ],
  "id" => "https://sukhi.example/users/alice/statuses/1/activity",
  "type" => "Create",
  "actor" => "https://sukhi.example/users/alice",
  "published" => "2026-11-11T14:32:08Z",
  "to" => ["https://www.w3.org/ns/activitystreams#Public"],
  "cc" => ["https://sukhi.example/users/alice/followers"],
  "object" => %{
    "id" => "https://sukhi.example/users/alice/statuses/1",
    "type" => "Note",
    "attributedTo" => "https://sukhi.example/users/alice",
    "content" => "<p>こんにちは、<a href=\"https://sukhi.example/tags/sukhi\">#sukhi</a></p>",
    "published" => "2026-11-11T14:32:08Z",
    "to" => ["https://www.w3.org/ns/activitystreams#Public"],
    "cc" => ["https://sukhi.example/users/alice/followers"]
  }
}

body = JSON.encode!(note)

signed =
  Map.new(
    for spec <- [:cavage, :rfc9421],
        do: {spec, HttpSignature.sign_post(url, body, private_key, key_id, spec: spec)}
  )

# A verify that fails would measure the early return, not the check.
for {_spec, headers} <- signed do
  :ok = HttpSignature.verify("post", url, headers, body, public_key)
end

# ── Markdown → sanitised HTML ──────────────────────────────────────────────

short_text = "こんにちは @alice さん！ #sukhi の **はじめて** の投稿です。"

long_text =
  """
  # きょうのこと

  朝、@alice と @bob に会いました。 #散歩 #sukhi

  - 一つめ: <b>太字</b>と `code` と [リンク](https://example.com/a?b=c&d=e)
  - 二つめ: x<y、List<String> は文字のまま残る
  - 三つめ: <script>alert(1)</script> は落ちる

  > 引用のなか。
  > つづき。

  ```elixir
  Enum.map(1..10, & &1 * 2)
  ```
  """
  |> String.duplicate(4)

# The real lookup reads the DB; this one answers from memory.
lookup = fn handle ->
  %{acct: handle, url: "https://sukhi.example/@" <> handle}
end

# ── Run ────────────────────────────────────────────────────────────────────

Benchee.Codspeed.run(
  %{
    "sign_post cavage" => fn ->
      HttpSignature.sign_post(url, body, private_key, key_id)
    end,
    "sign_post rfc9421" => fn ->
      HttpSignature.sign_post(url, body, private_key, key_id, spec: :rfc9421)
    end,
    "verify cavage" => fn ->
      HttpSignature.verify("post", url, signed.cavage, body, public_key)
    end,
    "verify rfc9421" => fn ->
      HttpSignature.verify("post", url, signed.rfc9421, body, public_key)
    end
  },
  file: "elixir/bench/pure_bench.exs",
  group: "HttpSignature",
  warmup: 1,
  time: 3
)

Benchee.Codspeed.run(
  %{
    "jcs_hash (Create Note)" => fn -> Canon.jcs_hash(note) end
  },
  file: "elixir/bench/pure_bench.exs",
  group: "Canon",
  warmup: 1,
  time: 3
)

Benchee.Codspeed.run(
  %{
    "to_html (short)" => fn -> SukhiFedi.Markdown.to_html(short_text, lookup) end,
    "to_html (long)" => fn -> SukhiFedi.Markdown.to_html(long_text, lookup) end,
    "sanitize (long)" => fn ->
      SukhiFedi.HTML.sanitize(
        "<p>" <>
          String.duplicate("<a href=\"https://example.com/\">link</a> <b>b</b> text ", 40) <>
          "</p>"
      )
    end
  },
  file: "elixir/bench/pure_bench.exs",
  group: "Markdown",
  warmup: 1,
  time: 3
)
