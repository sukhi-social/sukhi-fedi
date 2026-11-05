# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Datalevin.ManifestTest do
  use ExUnit.Case, async: true

  alias SukhiFedi.Datalevin.{Config, Manifest}

  test "expected manifest identifies the catalog and restore directory" do
    config = %Config{dir: "/tmp/sukhi-datalevin"}
    manifest = Manifest.expected(config)

    assert manifest["format"] == 1
    assert manifest["store"] == "datalevin"
    assert manifest["data_dir"] == config.dir
    assert manifest["catalog_sha256"] =~ ~r/^[0-9a-f]{64}$/
  end

  test "manifest path is inside the data directory" do
    assert Manifest.path(%Config{dir: "/var/lib/sukhi/datalevin"}) ==
             "/var/lib/sukhi/datalevin/.sukhi-store.json"
  end
end
