# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule MentionsTest do
  use ExUnit.Case, async: false
  @moduletag :needs_dtlv

  alias SukhiHosi.{Actors, Mentions, Notes, Notifications}

  setup do
    {db, _dir} = TestDb.open()
    alice = Actors.create_local(db, "alice")
    bob = Actors.create_local(db, "bob")
    {:ok, %{temps: [[1, zed]]}} = Hosi.write(db, Actors.remote_ops(1, "https://far.test/users/zed"))
    %{db: db, alice: alice, bob: bob, zed: zed}
  end

  test "ours by @name, theirs by @name@host; each once, in the order they are named", c do
    assert [c.bob, c.zed, c.alice] == Mentions.extract(c.db, "@bob hi @zed@far.test, @bob again, and @alice")
  end

  test "our own host is us; another host with the same name is not", c do
    assert [c.bob] == Mentions.extract(c.db, "@bob@local.test")
    assert [] == Mentions.extract(c.db, "@bob@far.test")
    assert [] == Mentions.extract(c.db, "@zed")
  end

  test "an address, a link, a second @ and an unknown name are not mentions", c do
    assert [] == Mentions.extract(c.db, "write to bob@local.test or see https://x.test/@bob and @@bob and @nobody")
  end

  test "a mark of punctuation after the handle is not part of it; case is forgiven", c do
    assert [c.bob, c.zed] == Mentions.extract(c.db, "hey (@Bob), and @zed@FAR.test.")
  end

  test "it is what Notes.post takes: the ones here are told, the remote one is not", c do
    text = "hi @bob and @zed@far.test"
    {:ok, n} = Notes.post(c.db, c.alice, "https://x/n/1", text, mentions: Mentions.extract(c.db, text))
    assert [%{type: :mention, note: ^n}] = Notifications.list(c.db, c.bob)
    assert [] = Notifications.list(c.db, c.zed)
  end

  test "no handle, no one", c do
    assert [] == Mentions.extract(c.db, "just words")
    assert [] == Mentions.extract(c.db, "")
  end
end
