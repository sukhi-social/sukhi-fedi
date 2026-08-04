# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.WebPushDeliverableTest do
  @moduledoc """
  The one predicate that decides whether a pocket buzzes.

  These are not really crypto or plumbing tests — they are the calm
  contract written down where it can fail loudly. The line that matters
  most in `docs/WEBPUSH.md` is that the ambient tier never wakes anybody,
  and it is one `in` away from being untrue.
  """
  use ExUnit.Case, async: true

  # Pure, no DB; the runner filters to `--only integration`.
  @moduletag :integration

  alias SukhiFedi.Addons.WebPush

  @now ~U[2026-08-04 12:00:00Z]

  defp awake, do: %{quiet_until: nil, now: @now}
  defp all_on, do: %{"mention" => true, "follow_request" => true, "favourite" => true}

  describe "the calm contract" do
    test "a mention may interrupt" do
      assert WebPush.deliverable?("mention", all_on(), awake())
    end

    test "a follow request may interrupt" do
      assert WebPush.deliverable?("follow_request", all_on(), awake())
    end

    test "**the ambient tier never wakes anybody**" do
      # This is the single most important assertion in the file. A phone
      # that buzzes for a favourite is the FOMO regression the two-tier
      # model exists to prevent — and it would take one word added to
      # @direct_types. Even with the user's own switch on, even wide awake.
      for type <- ~w(favourite reblog follow status poll update) do
        refute WebPush.deliverable?(type, all_on(), awake()),
               "#{type} must never reach a push transport"
      end
    end

    test "and a type nobody has heard of does not, either" do
      refute WebPush.deliverable?("some_future_type", all_on(), awake())
    end
  end

  describe "the user's own switch" do
    test "a direct type they turned off is not pushed" do
      refute WebPush.deliverable?("mention", %{"mention" => false}, awake())
    end

    test "absence is not consent — a key the client never sent is off" do
      refute WebPush.deliverable?("mention", %{}, awake())
    end

    test "and neither is a truthy-looking string from the wire" do
      # The alerts map arrived as client JSON; `== true` normalizes that
      # once, strictly, at the edge.
      refute WebPush.deliverable?("mention", %{"mention" => "true"}, awake())
      refute WebPush.deliverable?("mention", %{"mention" => 1}, awake())
    end

    test "a broken alerts map is treated as off, not as a crash" do
      refute WebPush.deliverable?("mention", nil, awake())
    end
  end

  describe "おやすみ" do
    test "nothing leaves while it is on" do
      quiet = %{quiet_until: ~U[2026-08-04 18:00:00Z], now: @now}
      refute WebPush.deliverable?("mention", all_on(), quiet)
    end

    test "and everything resumes the moment it lapses" do
      lapsed = %{quiet_until: ~U[2026-08-04 06:00:00Z], now: @now}
      assert WebPush.deliverable?("mention", all_on(), lapsed)
    end

    test "the exact instant it ends counts as over" do
      assert WebPush.deliverable?("mention", all_on(), %{quiet_until: @now, now: @now})
    end

    test "it does not resurrect a type the tier forbids" do
      # おやすみ ending is not permission to buzz for a favourite.
      lapsed = %{quiet_until: ~U[2026-08-04 06:00:00Z], now: @now}
      refute WebPush.deliverable?("favourite", all_on(), lapsed)
    end
  end

  describe "the Topic that collapses a burst" do
    # A push service replaces a *pending* message carrying the same topic,
    # so ten messages from one person while a phone sleeps become one buzz.
    # Everything here is about what counts as "the same knock".
    defp sub(auth \\ "auth-secret-1"), do: %{auth_key: auth}

    defp notif(type, from), do: %SukhiFedi.Schema.Notification{type: type, from_account_id: from}

    test "a burst from one person collapses into one knock" do
      assert WebPush.topic_for(sub(), notif("mention", 7)) ==
               WebPush.topic_for(sub(), notif("mention", 7))
    end

    test "a different person does not fold into it" do
      refute WebPush.topic_for(sub(), notif("mention", 7)) ==
               WebPush.topic_for(sub(), notif("mention", 8))
    end

    test "and neither does a different kind of knock" do
      # A follow request arriving during a conversation is its own thing;
      # swallowing it into the mention topic would lose it silently.
      refute WebPush.topic_for(sub(), notif("mention", 7)) ==
               WebPush.topic_for(sub(), notif("follow_request", 7))
    end

    test "two devices get different topics for the same event" do
      # The topic rides as a plain header. Keying it with each
      # subscription's own secret means a push service can't line the two
      # up and learn that one person is behind both.
      refute WebPush.topic_for(sub("auth-a"), notif("mention", 7)) ==
               WebPush.topic_for(sub("auth-b"), notif("mention", 7))
    end

    test "it says nothing legible about who is knocking" do
      topic = WebPush.topic_for(sub(), notif("mention", 7))
      refute topic =~ "mention"
      refute topic =~ "7"
    end

    test "it fits where RFC 8030 says a Topic fits" do
      topic = WebPush.topic_for(sub(), notif("mention", 7))
      assert byte_size(topic) <= 32
      # url-safe base64: no +, /, or padding.
      assert topic =~ ~r/^[A-Za-z0-9_-]+$/
    end

    test "a subscription with no auth secret still produces one" do
      # Shouldn't happen, but a crash in the fan-out would drop the push
      # entirely — and a knock lost to a nil is the worst trade here.
      assert is_binary(WebPush.topic_for(%{auth_key: nil}, notif("mention", 7)))
    end
  end

  describe "the list the client reads" do
    test "is the same one the predicate gates on" do
      # The web client takes its DIRECT_TYPES from here rather than
      # keeping a second copy — two literals would drift, and the drift
      # would be a silent breach of the contract above.
      assert WebPush.direct_types() == ["mention", "follow_request"]

      for type <- WebPush.direct_types() do
        assert WebPush.deliverable?(type, all_on(), awake())
      end
    end
  end
end
