# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Integration.OutboundArchiveTest do
  @moduledoc """
  End-to-end tests for `SukhiFedi.Federation.OutboundArchive`: archive the
  bytes actually delivered to a remote inbox to the `outbound` bucket and
  index them. The mirror of `inbound_archive_test.exs`.

      docker compose -f docker-compose.test.yml up -d
      MIX_ENV=test mix ecto.migrate
      mix test --only integration

  The delivery node enqueues this worker cross-node by string; here we drive
  `perform/1` directly with the args it would receive.
  """

  use SukhiFedi.IntegrationCase, async: false

  import Ecto.Query

  @moduletag :integration
  # Writes the body to S3 (MinIO); PGlite alone has none. See docs/TESTING.md.
  @moduletag skip: s3_skip()

  alias SukhiFedi.Federation.OutboundArchive
  alias SukhiFedi.Schema.OutboundEvent

  setup do
    _ = SukhiFedi.Addons.Media.Bootstrap.ensure_bucket()
    :ok
  end

  defp job(args), do: %Oban.Job{args: args}

  defp args(overrides) do
    %{
      "body" => ~s({"type":"Create","id":"https://localhost:4000/act/1"}),
      "activity_id" => "https://localhost:4000/act/1",
      "inbox_url" => "https://remote.example/users/bob/inbox",
      "actor_uri" => "https://localhost:4000/users/potato",
      "status" => "delivered",
      "response_status" => 202,
      "delivered_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }
    |> Map.merge(overrides)
  end

  describe "perform/1" do
    test "archives the delivered body to S3 (zstd) and indexes it" do
      a = args(%{})
      body = a["body"]

      assert :ok = OutboundArchive.perform(job(a))

      sha = :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
      ev = Repo.get_by!(OutboundEvent, body_sha256: sha)

      assert ev.activity_id == "https://localhost:4000/act/1"
      assert ev.inbox_url == "https://remote.example/users/bob/inbox"
      assert ev.actor_uri == "https://localhost:4000/users/potato"
      assert ev.status == "delivered"
      assert ev.response_status == 202
      assert ev.object_key =~ ~r"^outbound/\d{4}/\d{2}/\d{2}/#{sha}\.json\.zst$"

      bucket = Application.get_env(:sukhi_fedi, :s3)[:outbound_bucket]

      assert {:ok, %{body: compressed}} =
               ExAws.S3.get_object(bucket, ev.object_key) |> ExAws.request()

      assert :ezstd.decompress(compressed) == body
    end

    test "is idempotent on (activity_id, inbox_url)" do
      a = args(%{"activity_id" => "https://localhost:4000/like/9"})

      assert :ok = OutboundArchive.perform(job(a))
      assert :ok = OutboundArchive.perform(job(a))

      assert Repo.aggregate(
               from(e in OutboundEvent, where: e.activity_id == "https://localhost:4000/like/9"),
               :count
             ) == 1
    end

    test "records a failed delivery with a null response_status" do
      a =
        args(%{
          "activity_id" => "https://localhost:4000/act/2",
          "inbox_url" => "https://down.example/inbox",
          "status" => "failed",
          "response_status" => nil
        })

      assert :ok = OutboundArchive.perform(job(a))

      ev = Repo.get_by!(OutboundEvent, activity_id: "https://localhost:4000/act/2")
      assert ev.status == "failed"
      assert ev.response_status == nil
    end
  end
end
