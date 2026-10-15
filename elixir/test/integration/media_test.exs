# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Integration.MediaTest do
  @moduledoc """
  End-to-end tests for `SukhiFedi.Addons.Media` server-side upload +
  attach_to_note + update_media.

      docker compose -f docker-compose.test.yml up -d
      MIX_ENV=test mix ecto.migrate
      mix test --only integration
  """

  use SukhiFedi.IntegrationCase, async: false

  @moduletag :integration

  alias SukhiFedi.{Notes}
  alias SukhiFedi.Addons.Media, as: MediaCtx
  alias SukhiFedi.Schema.{Account, Media}

  setup do
    # Bucket は app boot 時の Bootstrap が作るが、test では Application.start
    # 前に書く順序になりがちなので明示的に ensure。失敗しても続行(rustfs が
    # 起きていなければ test 自体が落ちる)。
    _ = SukhiFedi.Addons.Media.Bootstrap.ensure_bucket()
    :ok
  end

  describe "create_from_upload/3" do
    @tag skip: s3_skip()
    test "writes object + inserts Media row" do
      a = create_account!("alice_upload")
      bytes = <<137, 80, 78, 71, 13, 10, 26, 10>> <> :binary.copy(<<0>>, 100)

      assert {:ok, %Media{} = m} =
               MediaCtx.create_from_upload(a.id, bytes, %{
                 "filename" => "kitten.png",
                 "content_type" => "image/png",
                 "description" => "a cute kitten"
               })

      assert m.account_id == a.id
      assert m.type == "image"
      assert m.description == "a cute kitten"
      assert m.size == byte_size(bytes)
      assert m.url =~ "/uploads/"

      key = String.replace_leading(URI.parse(m.url).path, "/uploads/", "")
      bucket = Application.get_env(:sukhi_fedi, :s3)[:bucket]
      assert {:ok, %{body: ^bytes}} = ExAws.S3.get_object(bucket, key) |> ExAws.request()
    end

    test "rejects empty upload" do
      a = create_account!("alice_empty")
      assert {:error, :empty_upload} = MediaCtx.create_from_upload(a.id, "", %{})
    end

    test "rejects oversize file (>8 MiB)" do
      a = create_account!("alice_big")
      huge = :binary.copy(<<0>>, 8 * 1024 * 1024 + 1)

      assert {:error, :file_too_large} = MediaCtx.create_from_upload(a.id, huge, %{})
    end

    @tag skip: s3_skip()
    test "infers type from content_type" do
      a = create_account!("alice_types")

      {:ok, vid} = MediaCtx.create_from_upload(a.id, "VIDEO", %{"content_type" => "video/mp4", "filename" => "v.mp4"})
      assert vid.type == "video"

      {:ok, aud} = MediaCtx.create_from_upload(a.id, "AUDIO", %{"content_type" => "audio/mpeg", "filename" => "a.mp3"})
      assert aud.type == "audio"

      {:ok, unk} = MediaCtx.create_from_upload(a.id, "BIN", %{"content_type" => "application/octet-stream", "filename" => "x.bin"})
      assert unk.type == "unknown"
    end
  end

  describe "get_media/2" do
    @tag skip: s3_skip()
    test "owner gets the row" do
      a = create_account!("alice_get")
      {:ok, m} = MediaCtx.create_from_upload(a.id, "X", %{"content_type" => "image/png", "filename" => "a.png"})

      assert {:ok, fetched} = MediaCtx.get_media(a.id, m.id)
      assert fetched.id == m.id
    end

    @tag skip: s3_skip()
    test "non-owner → :forbidden" do
      a = create_account!("alice_perm_g")
      b = create_account!("bob_perm_g")
      {:ok, m} = MediaCtx.create_from_upload(a.id, "X", %{"content_type" => "image/png", "filename" => "a.png"})

      assert {:error, :forbidden} = MediaCtx.get_media(b.id, m.id)
    end

    test "unknown id → :not_found" do
      a = create_account!("alice_404m")
      assert {:error, :not_found} = MediaCtx.get_media(a.id, 99_999_999)
    end
  end

  describe "update_media/3" do
    @tag skip: s3_skip()
    test "updates description while unattached" do
      a = create_account!("alice_upd")
      {:ok, m} = MediaCtx.create_from_upload(a.id, "X", %{"content_type" => "image/png", "filename" => "a.png"})

      assert {:ok, updated} = MediaCtx.update_media(a.id, m.id, %{"description" => "updated"})
      assert updated.description == "updated"
    end

    @tag skip: s3_skip()
    test "rejects update after attachment" do
      a = create_account!("alice_attached")
      {:ok, m} = MediaCtx.create_from_upload(a.id, "X", %{"content_type" => "image/png", "filename" => "a.png"})

      {:ok, _note} = Notes.create_status(a, %{"status" => "with media", "media_ids" => [to_string(m.id)]})

      assert {:error, :already_attached} =
               MediaCtx.update_media(a.id, m.id, %{"description" => "too late"})
    end
  end

  describe "attach_to_note via create_status pipeline" do
    @tag skip: s3_skip()
    test "stamps attached_at on the Media row" do
      a = create_account!("alice_stamp")
      {:ok, m} = MediaCtx.create_from_upload(a.id, "X", %{"content_type" => "image/png", "filename" => "a.png"})

      {:ok, _note} = Notes.create_status(a, %{"status" => "with media", "media_ids" => [to_string(m.id)]})

      reloaded = Repo.get!(Media, m.id)
      assert %DateTime{} = reloaded.attached_at
    end
  end

  defp create_account!(username) do
    %Account{username: username, display_name: username, summary: ""}
    |> Repo.insert!()
  end
end
