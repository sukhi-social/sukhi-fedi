# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Integration.BubbleAdminTest do
  use SukhiFedi.IntegrationCase, async: false

  @moduletag :integration

  alias SukhiFedi.Addons.Moderation
  alias SukhiFedi.Schema.{Account, BubbleInstance}
  alias SukhiFedi.Web.Admin.Render

  defp remote!(username, domain),
    do:
      insert_account!(%Account{
        username: username,
        display_name: username,
        summary: "",
        domain: domain
      })

  test "known_domains lists distinct remote hosts and excludes local accounts" do
    remote!("a", "misskey.io")
    remote!("b", "misskey.io")
    remote!("c", "hackers.pub")
    insert_account!(%Account{username: "local", display_name: "local", summary: ""})

    all = Moderation.known_domains()

    assert "misskey.io" in all
    assert "hackers.pub" in all
    refute nil in all
    assert Enum.count(all, &(&1 == "misskey.io")) == 1
  end

  test "known_domains does a case-insensitive substring search" do
    remote!("d", "misskey.io")
    remote!("e", "hackers.pub")

    assert Moderation.known_domains("misskey") == ["misskey.io"]
    assert Moderation.known_domains("PUB") == ["hackers.pub"]
    assert Moderation.known_domains("nope.example") == []
  end

  test "known_domains treats LIKE wildcards as literals (no injection)" do
    remote!("f", "ab.example")
    # The `_` must match a literal underscore, not "any character" — so this
    # search for "a_b" must not match "ab.example".
    assert Moderation.known_domains("a_b") == []
    assert Moderation.known_domains("ab.example") == ["ab.example"]
  end

  test "list_bubble_instances returns rows newest-first" do
    Repo.insert!(%BubbleInstance{domain: "one.example"})
    Repo.insert!(%BubbleInstance{domain: "two.example"})

    assert Moderation.list_bubble_instances() |> Enum.map(& &1.domain) ==
             ["two.example", "one.example"]
  end

  test "the bubble admin template renders in every branch" do
    row = %BubbleInstance{domain: "neighbor.example", inserted_at: ~N[2026-06-20 00:00:00]}

    # searched, with suggestions
    html =
      Render.render_template("bubble_instances/index.html.eex",
        current: [row],
        suggestions: ["found.example"],
        q: "found",
        searched: true
      )

    assert html =~ "neighbor.example"
    assert html =~ "found.example"
    assert html =~ "Remove"

    # searched, no matches and empty bubble
    empty =
      Render.render_template("bubble_instances/index.html.eex",
        current: [],
        suggestions: [],
        q: "zzz",
        searched: true
      )

    assert empty =~ "No known hosts match"
    assert empty =~ "No hosts in the bubble yet."

    # not searched — no "no matches" line
    fresh =
      Render.render_template("bubble_instances/index.html.eex",
        current: [row],
        suggestions: [],
        q: "",
        searched: false
      )

    refute fresh =~ "No known hosts match"
  end
end
