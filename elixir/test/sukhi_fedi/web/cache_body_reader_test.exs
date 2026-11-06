# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Web.CacheBodyReaderTest do
  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn

  alias SukhiFedi.Web.CacheBodyReader

  @parsers [
    parsers: [:json],
    json_decoder: Jason,
    body_reader: {CacheBodyReader, :read_body, []}
  ]

  defp parse(path, body, content_type \\ "application/activity+json") do
    conn(:post, path, body)
    |> put_req_header("content-type", content_type)
    |> Plug.Parsers.call(Plug.Parsers.init(@parsers))
  end

  defp nested(levels), do: String.duplicate("[", levels) <> String.duplicate("]", levels)

  test "an ordinary activity is parsed and its bytes are kept for the signature check" do
    body = ~s({"type":"Create","object":{"type":"Note","content":"hi"}})
    conn = parse("/users/alice/inbox", body)

    assert conn.body_params["type"] == "Create"
    assert conn.assigns.raw_body == body
  end

  test "a body nested past the ceiling is refused before Jason sees it" do
    assert_raise CacheBodyReader.TooDeepError, fn ->
      parse("/inbox", ~s({"a":) <> nested(100) <> "}")
    end
  end

  test "the same depth check covers every JSON body, not only the inbox" do
    assert_raise CacheBodyReader.TooDeepError, fn ->
      parse("/api/v1/statuses", ~s({"a":) <> nested(100) <> "}", "application/json")
    end
  end

  test "brackets inside strings are not levels" do
    body = ~s({"content":"#{String.duplicate("[", 200)}"})
    assert %{body_params: %{"content" => _}} = parse("/inbox", body)
  end

  test "a form body is not scanned for brackets" do
    conn =
      conn(:post, "/x", "a=" <> String.duplicate("[", 200))
      |> put_req_header("content-type", "application/x-www-form-urlencoded")
      |> Plug.Parsers.call(
        Plug.Parsers.init(
          parsers: [:urlencoded],
          body_reader: {CacheBodyReader, :read_body, []}
        )
      )

    assert conn.body_params["a"] == String.duplicate("[", 200)
  end

  test "an inbox body over 1 MiB is refused as too large, another path keeps the default" do
    big = ~s({"x":") <> String.duplicate("a", 1024 * 1024 + 10) <> ~s("})

    assert_raise Plug.Parsers.RequestTooLargeError, fn -> parse("/users/alice/inbox", big) end
    assert_raise Plug.Parsers.RequestTooLargeError, fn -> parse("/inbox", big) end
    assert %{body_params: %{"x" => _}} = parse("/api/v1/something", big, "application/json")
  end
end
