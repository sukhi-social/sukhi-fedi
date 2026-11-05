# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiApi.Views.MastodonAccountTest do
  use ExUnit.Case, async: true

  alias SukhiApi.Views.MastodonAccount

  # test config の domain は localhost:4000 (config.exs)

  defp account(attrs) do
    Map.merge(%{id: 3, username: "kuro", domain: nil, avatar_url: nil, banner_url: nil}, attrs)
  end

  describe "remote profile images go through the proxy" do
    test "avatar and header are rewritten with a ?v= cache buster" do
      out =
        MastodonAccount.render(
          account(%{
            domain: "remote.example",
            avatar_url: "https://remote.example/a.png",
            banner_url: "https://remote.example/b.png"
          })
        )

      assert out.avatar =~ ~r"^https://localhost:4000/proxy/avatar/3\.png\?v=\d+$"
      assert out.header =~ ~r"^https://localhost:4000/proxy/header/3\.png\?v=\d+$"
      assert out.avatar_static == out.avatar

      # 元 URL が変われば ?v= も変わる ─ edge cache が自然に外れる
      moved =
        MastodonAccount.render(
          account(%{domain: "remote.example", avatar_url: "https://remote.example/a2.png"})
        )

      refute moved.avatar == out.avatar
    end

    test "local avatars stay on /uploads, missing images keep the placeholder" do
      local = MastodonAccount.render(account(%{avatar_url: "/uploads/1/me.png"}))
      assert local.avatar == "/uploads/1/me.png"

      missing = MastodonAccount.render(account(%{domain: "remote.example"}))
      assert missing.avatar == "https://localhost:4000/static/avatar-default.svg"
    end
  end

  describe "avatar decorations" do
    test "remote ones go through /proxy/deco, in order; none renders as []" do
      out =
        MastodonAccount.render(
          account(%{
            domain: "remote.example",
            avatar_decorations: [
              %{"url" => "https://remote.example/files/a.webp", "offset_x" => -0.075, "offset_y" => 0.075}
            ]
          })
        )

      assert [%{url: url, angle: 0.0, flip_h: false, offset_x: -0.075, offset_y: 0.075}] =
               out.avatar_decorations

      assert url =~ ~r"^https://localhost:4000/proxy/deco/3/0\.webp\?v=\d+$"
      assert MastodonAccount.render(account(%{})).avatar_decorations == []
    end
  end

  describe "url is the profile page a person opens; uri stays the actor id" do
    test "a local account's url is /@name" do
      out = MastodonAccount.render(account(%{}))
      assert out.url == "https://localhost:4000/@kuro"
      assert out.uri == "https://localhost:4000/users/kuro"
    end

    test "a remote account keeps its stored actor_uri for both" do
      out =
        MastodonAccount.render(
          account(%{domain: "remote.example", actor_uri: "https://remote.example/users/kuro"})
        )

      assert out.url == "https://remote.example/users/kuro"
      assert out.uri == "https://remote.example/users/kuro"
    end
  end

  describe "render_credential/3 translation settings" do
    test "shows the languages and the engine, and only the last four characters of a key" do
      out =
        MastodonAccount.render_credential(
          account(%{
            translate_reads: "ja,en",
            translate_learns: "ko",
            translate_engine: "deepl",
            translate_auto: true,
            translate_deepl_key_hint: "e4f5"
          }),
          %{},
          ["read"]
        )

      assert %{translate_reads: ["ja", "en"], translate_learns: ["ko"], translate_engine: "deepl", translate_auto: true, translate_deepl_key_hint: "e4f5"} = out.source
      refute Map.has_key?(out.source, :translate_deepl_key)
    end

    test "an account that never chose is on the server's translator, reads and learns nothing, and has no key" do
      out = MastodonAccount.render_credential(account(%{}), %{}, ["read"])

      assert %{translate_reads: [], translate_learns: [], translate_engine: "libre", translate_auto: false, translate_deepl_key_hint: nil} = out.source
    end

    test "a sealed key that somehow reached the view is not rendered" do
      out = MastodonAccount.render_credential(account(%{translate_deepl_key: "SEALED-BYTES"}), %{}, ["read"])
      refute JSON.encode!(out) =~ "SEALED-BYTES"
    end
  end
end

