# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Addons.Media.PresignTest do
  # Touches application env and System env: not async.
  use ExUnit.Case, async: false

  alias SukhiFedi.Addons.Media

  setup do
    saved = %{
      ex_aws: Application.get_all_env(:ex_aws),
      s3: Application.get_env(:sukhi_fedi, :s3),
      endpoint: System.get_env("S3_ENDPOINT")
    }

    on_exit(fn ->
      for {k, v} <- saved.ex_aws, do: Application.put_env(:ex_aws, k, v)

      for k <- [:access_key_id, :secret_access_key, :s3],
          not Keyword.has_key?(saved.ex_aws, k),
          do: Application.delete_env(:ex_aws, k)

      if saved.s3,
        do: Application.put_env(:sukhi_fedi, :s3, saved.s3),
        else: Application.delete_env(:sukhi_fedi, :s3)

      if saved.endpoint,
        do: System.put_env("S3_ENDPOINT", saved.endpoint),
        else: System.delete_env("S3_ENDPOINT")
    end)
  end

  test "the presigned URL is signed with the credentials runtime.exs configured (S3_ACCESS_KEY_ID / S3_SECRET_ACCESS_KEY)" do
    System.put_env("S3_ENDPOINT", "https://s3.example.test")
    Application.put_env(:ex_aws, :access_key_id, "AKIDCONFIGURED")
    Application.put_env(:ex_aws, :secret_access_key, "secret")
    Application.put_env(:ex_aws, :s3, region: "us-east-1")
    Application.put_env(:sukhi_fedi, :s3, bucket: "mybucket", enabled: true)

    {:ok, %{upload_url: url}} = Media.generate_upload_url(1, "a.png", "image/png")

    assert url =~ "https://s3.example.test/mybucket/1/"
    assert url =~ "X-Amz-Credential=AKIDCONFIGURED%2F"
    assert url =~ "%2Fus-east-1%2Fs3%2Faws4_request"
    assert url =~ "X-Amz-Signature="
  end

  test "without configured credentials it falls back to the local /uploads path" do
    System.put_env("S3_ENDPOINT", "https://s3.example.test")
    Application.delete_env(:ex_aws, :access_key_id)
    Application.delete_env(:ex_aws, :secret_access_key)

    {:ok, %{upload_url: url, key: key}} = Media.generate_upload_url(1, "a.png", "image/png")
    assert url == "/uploads/#{key}"
  end
end
