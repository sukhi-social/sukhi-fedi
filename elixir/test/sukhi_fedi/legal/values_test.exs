# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Legal.ValuesTest do
  use ExUnit.Case, async: true

  alias SukhiFedi.Legal.Values

  test "unset keys fall back to the flavor's own address" do
    assert Values.resolve(:sukhi, %{}) == %{
             contact_email: "f3liz-dev@proton.me",
             contact_activitypub: "@kuro_admin@sukhi.f3liz.casa"
           }

    assert Values.resolve(:natadeco, %{}).contact_email == "admin@natadeco.com"
    assert Values.source(%{}) == :flavor_default
  end

  test "configured keys win, one at a time" do
    config = %{"legal" => %{"contact_email" => "ops@example.org"}}

    assert %{
             contact_email: "ops@example.org",
             contact_activitypub: "@kuro_admin@sukhi.f3liz.casa"
           } =
             Values.resolve(:sukhi, config)

    assert Values.source(config) == :flavor_default

    full = %{
      "legal" => %{
        "contact_email" => "ops@example.org",
        "contact_activitypub" => "@ops@example.org"
      }
    }

    assert Values.source(full) == :configured
  end

  test "an ActivityPub handle is shown with its leading @ whether or not it was written" do
    config = %{"legal" => %{"contact_activitypub" => "ops@example.org"}}
    assert Values.resolve(:sukhi, config).contact_activitypub == "@ops@example.org"
  end

  test "fill replaces every occurrence, escapes, and leaves unknown placeholders visible" do
    html = "<p>{{contact_email}} / {{contact_email}} / {{nope}}</p>"
    out = Values.fill(html, %{contact_email: "a&b@example.org"})
    assert out == "<p>a&amp;b@example.org / a&amp;b@example.org / {{nope}}</p>"
  end
end
