# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Federation.CollectionFetcherTest do
  @moduledoc """
  外のコレクションを引く道具の、入口の条件。

  相手の URL はこちらの入力から来る（ベランダに handle を打つ人）ので、
  内向きのアドレスへ行かせないところが要になる。辿りと上限の中身は
  fedify(NATS)越しの取得が要るので、ここでは見ない。
  """

  use ExUnit.Case, async: true

  alias SukhiFedi.Federation.CollectionFetcher

  test "内向きのアドレスへは行かない" do
    for uri <- [
          "http://127.0.0.1/outbox",
          "https://localhost/outbox",
          "https://10.0.0.1/outbox",
          "https://192.168.1.1/outbox",
          "ftp://example.test/outbox"
        ] do
      assert {:error, :unsafe_url} = CollectionFetcher.fetch(uri), "#{uri} が通ってしまった"
    end
  end
end
