# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.TokenizerTest do
  use ExUnit.Case, async: true

  alias SukhiFedi.Tokenizer
  alias SukhiFedi.Tokenizer.{Sudachi, Whitespace}

  defp fake(tokens), do: fn _url, _body, _timeout -> {:ok, %{"tokens" => tokens}} end

  defp opts(request),
    do: [engines: %{"ja" => Sudachi}, engine_opts: [url: "http://s", request: request]]

  test "Japanese goes through Sudachi and comes back space-separated" do
    assert {:ok, "日本語 の 猫"} = Tokenizer.segment("日本語の猫", "ja", opts(fake(["日本語", "の", "", "猫"])))
  end

  test "the language tag is reduced to its primary subtag" do
    assert {:ok, "a b"} = Tokenizer.segment("ab", "JA-jp", opts(fake(["a", "b"])))
  end

  test "an unknown language is left as written" do
    assert {:ok, "안녕하세요"} = Tokenizer.segment("안녕하세요", "ko", opts(fake(["x"])))
    assert {:ok, "plain"} = Tokenizer.segment("plain", nil, opts(fake(["x"])))
  end

  test "a down service degrades to the written text instead of failing the write" do
    down = fn _, _, _ -> {:error, :econnrefused} end
    assert {:degraded, "日本語の猫"} = Tokenizer.segment("日本語の猫", "ja", opts(down))

    assert {:degraded, "x"} =
             Tokenizer.segment("x", "ja",
               engines: %{"ja" => Sudachi},
               engine_opts: [url: nil, request: down]
             )
  end

  test "a malformed answer is an error, not tokens" do
    assert {:degraded, "t"} =
             Tokenizer.segment("t", "ja", opts(fn _, _, _ -> {:ok, %{"tokens" => [1]}} end))

    assert {:error, :bad_response} =
             Sudachi.segment("t", url: "http://s", request: fn _, _, _ -> {:ok, %{}} end)
  end

  test "the request carries mode A by default" do
    parent = self()
    req = fn url, body, _ -> send(parent, {url, body}) && {:ok, %{"tokens" => ["a"]}} end
    Sudachi.segment("t", url: "http://s/", request: req)
    assert_received {"http://s/segment", %{"text" => "t", "mode" => "A"}}
  end

  test "Whitespace is the identity" do
    assert {:ok, "a b"} = Whitespace.segment("a b", [])
  end
end
