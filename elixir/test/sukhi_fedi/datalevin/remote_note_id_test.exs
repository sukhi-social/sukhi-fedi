# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Datalevin.RemoteNoteIdTest do
  @moduledoc """
  On Datalevin there is no `notes_remote_id_from_published` trigger, so the
  writer mints the id of a remote note from its `created_at` (the origin
  `published`) — otherwise a followed account's back-filled posts all get
  "just fetched" ids and sort above everything newer.
  """
  use ExUnit.Case, async: true

  alias SukhiFedi.Datalevin.Writer
  alias SukhiFedi.Snowflake

  @published ~U[2026-01-02 03:04:05Z]
  @published_us DateTime.to_unix(@published, :microsecond)

  test "a remote note's id encodes created_at" do
    id = Writer.snowflake("notes", %{ap_id: "https://r.example/n/1", created_at: @published_us})
    assert Snowflake.to_datetime(id) == @published
  end

  test "a local note (no ap_id) keeps the insert clock" do
    before = System.os_time(:millisecond)
    id = Writer.snowflake("notes", %{ap_id: nil, created_at: @published_us})
    assert Snowflake.to_unix_ms(id) >= before
  end

  test "other tables keep the insert clock" do
    before = System.os_time(:millisecond)
    id = Writer.snowflake("reactions", %{ap_id: "x", created_at: @published_us})
    assert Snowflake.to_unix_ms(id) >= before
  end

  test "older published sorts below newer published" do
    older = Writer.snowflake("notes", %{ap_id: "a", created_at: @published_us})
    newer = Writer.snowflake("notes", %{ap_id: "b", created_at: @published_us + 86_400_000_000})
    assert older < newer
  end
end
