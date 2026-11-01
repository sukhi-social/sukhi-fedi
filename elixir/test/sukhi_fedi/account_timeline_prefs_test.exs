# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.AccountTimelinePrefsTest do
  use ExUnit.Case, async: true

  alias SukhiFedi.Schema.Account

  defp change(attrs), do: Account.changeset_credentials(%Account{}, attrs)

  test "home_filter keeps only known tokens, sorted and de-duplicated" do
    cs = change(%{"home_filter" => "only_media, nope,hide_boosts,only_media"})
    assert cs.valid?
    assert cs.changes.home_filter == "hide_boosts,only_media"
  end

  test "an empty or all-unknown home_filter means no default" do
    assert change(%{"home_filter" => ""}).changes[:home_filter] == nil
    assert change(%{"home_filter" => "nope"}).changes[:home_filter] == nil
  end

  test "boost_hide_name casts a form string" do
    assert change(%{"boost_hide_name" => "true"}).changes.boost_hide_name == true
  end
end
