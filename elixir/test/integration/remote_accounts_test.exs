# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Integration.RemoteAccountsTest do
  @moduledoc """
  A re-fetch of a remote actor must not let a degraded/partial document null a
  good shadow row. Identity + freshness are always written; everything else is
  merged only when the fetched value is present.
  """

  use SukhiFedi.IntegrationCase, async: false

  @moduletag :integration

  alias SukhiFedi.Federation.RemoteAccounts
  alias SukhiFedi.Repo
  alias SukhiFedi.Schema.Account

  @uri "https://remote.example/users/bob"

  defp full_actor do
    %{
      "id" => @uri,
      "preferredUsername" => "bob",
      "name" => "Bob Full",
      "summary" => "a rich bio",
      "inbox" => "https://remote.example/users/bob/inbox",
      "publicKey" => %{"id" => "#{@uri}#main-key", "publicKeyPem" => "PEMDATA"},
      "icon" => %{"url" => "https://remote.example/avatar.png"},
      "image" => %{"url" => "https://remote.example/banner.png"}
    }
  end

  test "a partial refetch does not clobber richer stored profile fields" do
    {:ok, full} = RemoteAccounts.upsert_from_actor_json(full_actor())
    assert full.summary == "a rich bio"
    assert full.avatar_url == "https://remote.example/avatar.png"

    # A degraded re-fetch: just the identity, no icon/image/summary/inbox/key.
    sparse = %{"id" => @uri, "preferredUsername" => "bob"}
    {:ok, refetched} = RemoteAccounts.upsert_from_actor_json(sparse)

    # Same row, updated in place — and every richer field survives.
    assert refetched.id == full.id
    assert refetched.display_name == "Bob Full"
    assert refetched.summary == "a rich bio"
    assert refetched.avatar_url == "https://remote.example/avatar.png"
    assert refetched.banner_url == "https://remote.example/banner.png"
    assert refetched.inbox_url == "https://remote.example/users/bob/inbox"
    assert refetched.public_key_pem == "PEMDATA"
  end

  test "a remote bio is sanitized HTML and its emoji tags are mirrored" do
    actor =
      full_actor()
      |> Map.put("summary", "<p>hi <script>alert(1)</script><br>:blobcat:</p>")
      |> Map.put("tag", [
        %{
          "type" => "Emoji",
          "name" => ":blobcat:",
          "icon" => %{"type" => "Image", "url" => "https://remote.example/blobcat.png"}
        }
      ])

    {:ok, a} = RemoteAccounts.upsert_from_actor_json(actor)

    refute a.summary =~ "<script"
    assert a.summary =~ "<br"
    assert [%{"shortcode" => "blobcat", "url" => "https://remote.example/blobcat.png"}] = a.emojis
  end

  test "a refetch still applies a genuinely-changed field" do
    {:ok, _} = RemoteAccounts.upsert_from_actor_json(full_actor())

    changed = Map.put(full_actor(), "summary", "a new bio")
    {:ok, refetched} = RemoteAccounts.upsert_from_actor_json(changed)
    assert refetched.summary == "a new bio"
  end

  test "incoming attachment PropertyValue rows become sanitized, capped fields" do
    actor =
      full_actor()
      |> Map.put("attachment", [
        %{"type" => "PropertyValue", "name" => "site", "value" => "<a href=\"https://x\">x</a>"},
        # A non-PropertyValue attachment (some servers attach images) is ignored.
        %{"type" => "Image", "url" => "https://remote.example/pic.png"},
        # Scripts in the value are scrubbed by the same bio scrubber.
        %{"type" => "PropertyValue", "name" => "bio", "value" => "<script>evil()</script>safe"}
      ])

    {:ok, acct} = RemoteAccounts.upsert_from_actor_json(actor)

    assert [%{"name" => "site", "value" => site}, %{"name" => "bio", "value" => bio}] = acct.fields
    assert site == "<a href=\"https://x\">x</a>"
    refute bio =~ "script"
    assert bio =~ "safe"
  end

  test "a remote actor keeps up to 16 profile rows, not our own 4" do
    rows =
      for n <- 1..20,
          do: %{"type" => "PropertyValue", "name" => "row#{n}", "value" => "v#{n}"}

    {:ok, acct} = RemoteAccounts.upsert_from_actor_json(Map.put(full_actor(), "attachment", rows))

    assert length(acct.fields) == 16
  end

  test "a brand-new sparse actor still gets the handle as display_name" do
    {:ok, acct} =
      RemoteAccounts.upsert_from_actor_json(%{
        "id" => "https://remote.example/users/nameless",
        "preferredUsername" => "nameless"
      })

    assert acct.display_name == "nameless"
    # Ecto's cast treats "" as empty and skips it, so a blank summary lands as
    # nil (same as the original code's `summary: ... || ""`); the point here is
    # the handle fallback for display_name.
    assert acct.summary in [nil, ""]
    assert Repo.get(Account, acct.id)
  end
end
