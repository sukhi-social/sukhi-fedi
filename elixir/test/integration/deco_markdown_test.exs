# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Integration.DecoMarkdownTest do
  @moduledoc """
  natadeco の `/posts/:id`。ブラウザ以外(LLM のクローラ等)には、空の SPA
  shell ではなく投稿そのものを Markdown で返す。

      podman compose -f docker-compose.test.yml up -d postgres nats nats-bootstrap
      MIX_ENV=test mix sukhi.migrate
      mix test --only integration test/integration/deco_markdown_test.exs
  """

  use SukhiFedi.IntegrationCase, async: false

  @moduletag :integration

  import Plug.Conn
  import Plug.Test

  alias SukhiFedi.Addons.Deco
  alias SukhiFedi.LocalAccounts
  alias SukhiFedi.Schema.Account
  alias SukhiFedi.Web.Router

  @opts Router.init([])

  setup do
    n = System.unique_integer([:positive])
    {:ok, author} = LocalAccounts.create_admin("md_#{n}", "long-enough-pass")
    # 新規アカウントの投稿ペース制限に、この author を使う他のテストが
    # 巻き込まれないように、古参として作る(deco_test.exs と同じ理由)。
    author = age_account(author)
    {:ok, deco} = Deco.create_deco(author, %{"slug" => "shiro#{n}", "name" => "しろい板"})
    %{author: author, deco: deco}
  end

  defp age_account(%Account{} = account) do
    old = DateTime.add(DateTime.utc_now(), -48, :hour) |> DateTime.truncate(:second)

    account
    |> Ecto.Changeset.change(created_at: old)
    |> SukhiFedi.Repo.update!()
  end

  defp get(path, headers \\ []) do
    Enum.reduce(headers, conn(:get, path), fn {k, v}, c -> put_req_header(c, k, v) end)
    |> Router.call(@opts)
  end

  test "Accept が無い(curl 等)と Markdown が返る", %{author: author, deco: deco} do
    {:ok, post} =
      Deco.post(author, deco.slug, %{"title" => "はじめまして", "status" => "こんにちは、みなさん"})

    conn = get("/posts/#{post.id}")

    assert conn.status == 200
    assert conn |> get_resp_header("content-type") |> hd() =~ "text/markdown"
    assert conn.resp_body =~ "# はじめまして"
    assert conn.resp_body =~ "こんにちは、みなさん"
    assert conn.resp_body =~ "@#{author.username}"
  end

  test "Accept: text/html を積むブラウザ相当のリクエストには Markdown を返さない",
       %{author: author, deco: deco} do
    {:ok, post} = Deco.post(author, deco.slug, %{"title" => "ブラウザ向け", "status" => "…"})

    conn = get("/posts/#{post.id}", [{"accept", "text/html,application/xhtml+xml"}])

    refute conn |> get_resp_header("content-type") |> List.first() |> to_string() =~ "text/markdown"
  end

  test "text/markdown を text/html より先に積む Accept(実測: Claude Code の WebFetch)は Markdown 優先とみなす",
       %{author: author, deco: deco} do
    {:ok, post} = Deco.post(author, deco.slug, %{"title" => "WebFetch向け", "status" => "…"})

    conn =
      get("/posts/#{post.id}", [
        {"accept", "text/markdown, text/html, */*"},
        {"user-agent", "Claude-User (claude-code/2.1.238; +https://support.anthropic.com/)"}
      ])

    assert conn.status == 200
    assert conn |> get_resp_header("content-type") |> hd() =~ "text/markdown"
  end

  test "既知の LLM クローラの User-Agent なら、Accept が html でも Markdown を返す",
       %{author: author, deco: deco} do
    {:ok, post} = Deco.post(author, deco.slug, %{"title" => "クローラ向け", "status" => "…"})

    conn =
      get("/posts/#{post.id}", [
        {"accept", "text/html,application/xhtml+xml"},
        {"user-agent", "Mozilla/5.0 (compatible; ClaudeBot/1.0; +https://anthropic.com)"}
      ])

    assert conn.status == 200
    assert conn |> get_resp_header("content-type") |> hd() =~ "text/markdown"
    assert conn.resp_body =~ "# クローラ向け"
  end

  test "レスも Markdown に区切りつきで並ぶ", %{author: author, deco: deco} do
    {:ok, post} = Deco.post(author, deco.slug, %{"title" => "おはなし", "status" => "本文です"})
    {:ok, _} = Deco.reply(author, post.id, %{"status" => "うんうん、そうだね"})

    conn = get("/posts/#{post.id}")

    assert conn.resp_body =~ "本文です"
    assert conn.resp_body =~ "---"
    assert conn.resp_body =~ "うんうん、そうだね"
  end

  test "無い投稿は 404", do: assert(get("/posts/999999999").status == 404)
end
