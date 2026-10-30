# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.AccountPorterParseTest do
  use ExUnit.Case, async: true

  alias SukhiFedi.AccountPorter

  test "reads the first column, skips the header and BOM, and dedups" do
    csv =
      "﻿Account address,Show boosts\r\n" <>
        "bob@remote.example,true\r\n" <>
        "@carol@other.example\n" <>
        "\"dave@remote.example\",false\n" <>
        "BOB@remote.example\n"

    assert {:ok, ["bob@remote.example", "carol@other.example", "dave@remote.example"], 0} =
             AccountPorter.parse(csv)
  end

  test "counts malformed rows instead of failing the whole import" do
    assert {:ok, ["ok@remote.example"], 2} =
             AccountPorter.parse("ok@remote.example\nnot an address\n=cmd|' /C calc'!A0\n")
  end

  test "refuses too many rows and too large a body" do
    many = 1..1_001 |> Enum.map_join("\n", &"u#{&1}@remote.example")
    assert {:error, :too_many} = AccountPorter.parse(many)

    assert {:error, :too_large} = AccountPorter.parse(String.duplicate("a", 256 * 1024 + 1))
  end
end
