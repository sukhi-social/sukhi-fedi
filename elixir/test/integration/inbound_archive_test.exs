# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Integration.InboundArchiveTest do
  @moduledoc """
  End-to-end tests for `SukhiFedi.Federation.InboundArchive` (Q10 stage 1):
  archive a verified inbound original to the `inbound` bucket and index it.

      docker compose -f docker-compose.test.yml up -d
      MIX_ENV=test mix ecto.migrate
      mix test --only integration

  Oban runs `testing: :inline` in the test env, so `enqueue/4` performs
  the archive synchronously inside the test process.
  """

  use SukhiFedi.IntegrationCase, async: false

  import Ecto.Query

  @moduletag :integration
  # Writes the body to S3 (MinIO); PGlite alone has none. See docs/TESTING.md.
  @moduletag skip: s3_skip()

  alias SukhiFedi.Federation.InboundArchive
  alias SukhiFedi.Schema.InboundEvent

  setup do
    _ = SukhiFedi.Addons.Media.Bootstrap.ensure_bucket()
    :ok
  end

  describe "enqueue/4" do
    test "archives the original to S3 (zstd) and indexes it in inbound_events" do
      body =
        ~s({"type":"Follow","actor":"https://social.example/users/bob","id":"https://social.example/act/1","object":"https://localhost:4000/users/potato"})

      raw_json = JSON.decode!(body)
      headers = %{"date" => "Fri, 29 May 2026 01:24:12 GMT", "digest" => "SHA-256=abc"}

      assert {:ok, _job} = InboundArchive.enqueue(body, raw_json, headers, "shared")

      sha = :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
      ev = Repo.get_by!(InboundEvent, body_sha256: sha)

      assert ev.activity_type == "Follow"
      assert ev.actor_uri == "https://social.example/users/bob"
      assert ev.activity_id == "https://social.example/act/1"
      assert ev.inbox == "shared"
      assert ev.object_key =~ ~r"^inbound/\d{4}/\d{2}/\d{2}/#{sha}\.json\.zst$"

      bucket = Application.get_env(:sukhi_fedi, :s3)[:inbound_bucket]

      assert {:ok, %{body: compressed}} =
               ExAws.S3.get_object(bucket, ev.object_key) |> ExAws.request()

      assert compressed |> :zstd.decompress() |> IO.iodata_to_binary() == body
    end

    test "is idempotent — a re-sent activity does not duplicate the index row" do
      body =
        ~s({"type":"Like","actor":"https://social.example/users/carol","id":"https://social.example/like/9"})

      raw_json = JSON.decode!(body)

      assert {:ok, _} = InboundArchive.enqueue(body, raw_json, %{}, "shared")
      assert {:ok, _} = InboundArchive.enqueue(body, raw_json, %{}, "shared")

      sha = :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
      assert Repo.aggregate(from(e in InboundEvent, where: e.body_sha256 == ^sha), :count) == 1
    end
  end
end
