# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiApi.Capabilities.DecoTest do
  @moduledoc """
  natadeco の板の口。gateway は差し替えて、ここで見るのは
  「どの道が、どの呼び出しに落ちるか」と「返る形」だけ。
  """

  use ExUnit.Case, async: false

  alias SukhiApi.Router

  defmodule FakeRpc do
    def call(mod, fun, args), do: call(mod, fun, args, 5_000)

    def call(SukhiFedi.Addons.Deco, fun, args, _t) do
      table = Application.get_env(:sukhi_api, :fake_deco, %{})

      case Map.get(table, {fun, args}, :not_configured) do
        :not_configured ->
          # どの呼び出しが来たのか、落ちたときに分かるように残す。
          Application.put_env(:sukhi_api, :deco_last_call, {fun, args})
          {:error, :not_connected}

        v ->
          {:ok, v}
      end
    end

    def call(SukhiFedi.OAuth, fun, _args, _t) do
      table = Application.get_env(:sukhi_api, :fake_oauth, %{})

      case Map.get(table, fun, :not_configured) do
        :not_configured -> {:error, :not_connected}
        v -> {:ok, v}
      end
    end

    def call(_, _, _, _), do: {:error, :not_connected}
  end

  @viewer %{id: 7, username: "alice", display_name: "A", summary: ""}

  @deco %{id: 1, slug: "hinata", name: "ひなた板", description: nil, post_count: 2}
  @post %{
    id: 42,
    deco_id: 1,
    title: "はじめまして",
    content_html: "<p>こんにちは</p>",
    author: %{
      username: "alice",
      acct: "alice",
      display_name: "アリス",
      avatar_url: nil
    },
    reply_count: 0
  }

  setup do
    prev = %{
      rpc: Application.get_env(:sukhi_api, :gateway_rpc_impl),
      addons: Application.get_env(:sukhi_api, :enabled_addons),
      deco: Application.get_env(:sukhi_api, :fake_deco),
      oauth: Application.get_env(:sukhi_api, :fake_oauth)
    }

    Application.put_env(:sukhi_api, :gateway_rpc_impl, FakeRpc)
    Application.put_env(:sukhi_api, :enabled_addons, :all)
    Application.put_env(:sukhi_api, :fake_deco, %{})

    Application.put_env(:sukhi_api, :fake_oauth, %{
      verify_bearer:
        {:ok,
         %{
           account: @viewer,
           app: %{id: 1, name: "x"},
           scopes: ["read:statuses", "write:statuses"]
         }}
    })

    on_exit(fn ->
      restore(:gateway_rpc_impl, prev.rpc)
      restore(:enabled_addons, prev.addons)
      restore(:fake_deco, prev.deco)
      restore(:fake_oauth, prev.oauth)
      Application.delete_env(:sukhi_api, :deco_last_call)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:sukhi_api, key)
  defp restore(key, v), do: Application.put_env(:sukhi_api, key, v)

  defp get(path) do
    [p, q] =
      case String.split(path, "?", parts: 2) do
        [p] -> [p, nil]
        [p, q] -> [p, q]
      end

    Router.handle(%{method: "GET", path: p, query: q, headers: []})
  end

  defp post(path, body) do
    Router.handle(%{
      method: "POST",
      path: path,
      headers: [{"authorization", "Bearer t"}, {"content-type", "application/json"}],
      body: JSON.encode!(body)
    })
  end

  defp stub(pairs), do: Application.put_env(:sukhi_api, :fake_deco, Map.new(pairs))

  describe "読む（誰でも）" do
    test "板の一覧はトークン無しで読める" do
      stub([{{:list_decos, []}, [@deco]}])

      {:ok, resp} = get("/api/v1/deco")
      assert resp.status == 200
      assert [%{"slug" => "hinata"}] = JSON.decode!(resp.body)
    end

    test "板一枚" do
      stub([{{:get_deco, ["hinata"]}, {:ok, @deco}}])

      {:ok, resp} = get("/api/v1/deco/hinata")
      assert resp.status == 200
      assert %{"name" => "ひなた板"} = JSON.decode!(resp.body)
    end

    test "無い板は 404" do
      stub([{{:get_deco, ["nowhere"]}, {:error, :not_found}}])

      {:ok, resp} = get("/api/v1/deco/nowhere")
      assert resp.status == 404
    end

    test "板の投稿一覧" do
      stub([{{:list_posts, ["hinata", []]}, {:ok, [@post]}}])

      {:ok, resp} = get("/api/v1/deco/hinata/posts")
      assert resp.status == 200
      assert [%{"id" => 42}] = JSON.decode!(resp.body)
    end

    test "before_id と limit は、数として渡る（ゴミは落とす）" do
      stub([{{:list_posts, ["hinata", [before_id: 99, limit: 10]]}, {:ok, []}}])
      {:ok, resp} = get("/api/v1/deco/hinata/posts?limit=10&before_id=99")
      assert resp.status == 200

      stub([{{:list_posts, ["hinata", []]}, {:ok, []}}])
      {:ok, resp} = get("/api/v1/deco/hinata/posts?limit=あ&before_id=")
      assert resp.status == 200
    end

    # ここが取り違えやすいところ。`posts` を板の名前と読んでしまうと、
    # 一件を開く道が板の道に吸われる。
    test "/deco/posts/:id は、slug が posts の板とは読まれない" do
      stub([{{:get_post, ["42"]}, {:ok, @post}}])

      {:ok, resp} = get("/api/v1/deco/posts/42")
      assert resp.status == 200
      assert %{"author" => %{"acct" => "alice"}} = JSON.decode!(resp.body)
    end
  end

  describe "書く（ログインしている人）" do
    test "板に一件" do
      stub([{{:post, [@viewer, "hinata", %{"title" => "題", "status" => "本文"}]}, {:ok, @post}}])

      {:ok, resp} = post("/api/v1/deco/hinata/posts", %{title: "題", status: "本文"})
      assert resp.status == 201
    end

    test "ぶら下げる" do
      stub([{{:reply, [@viewer, "42", %{"status" => "うんうん"}]}, {:ok, @post}}])

      {:ok, resp} = post("/api/v1/deco/posts/42/replies", %{status: "うんうん"})
      assert resp.status == 201
    end

    test "板を立てる" do
      stub([
        {{:create_deco, [@viewer, %{"slug" => "hinata", "name" => "ひなた板"}]}, {:ok, @deco}}
      ])

      {:ok, resp} = post("/api/v1/deco", %{slug: "hinata", name: "ひなた板"})
      assert resp.status == 201
    end

    test "名前が使えなければ 422（どこが駄目かも返す）" do
      stub([
        {{:create_deco, [@viewer, %{"slug" => "posts", "name" => "板"}]},
         {:error, {:validation, %{slug: ["は予約されています"]}}}}
      ])

      {:ok, resp} = post("/api/v1/deco", %{slug: "posts", name: "板"})
      assert resp.status == 422
      assert %{"error" => "validation", "detail" => %{"slug" => _}} = JSON.decode!(resp.body)
    end

    test "トークン無しでは書けない" do
      {:ok, resp} =
        Router.handle(%{
          method: "POST",
          path: "/api/v1/deco/hinata/posts",
          headers: [{"content-type", "application/json"}],
          body: JSON.encode!(%{status: "本文"})
        })

      assert resp.status == 401
    end
  end

  describe "板の上に、書いた人が出る" do
    test "表示名と acct が、そのまま返る" do
      stub([{{:get_post, ["42"]}, {:ok, @post}}])

      {:ok, resp} = get("/api/v1/deco/posts/42")
      body = JSON.decode!(resp.body)

      assert %{"display_name" => "アリス", "acct" => "alice"} = body["author"]
    end
  end
end
