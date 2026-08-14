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
end
