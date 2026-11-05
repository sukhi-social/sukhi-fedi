# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Web.LegalControllerConfigTest do
  # Changes application env, so it cannot share a run with the async tests.
  use ExUnit.Case, async: false

  @moduletag :integration

  import Plug.Test

  alias SukhiFedi.Web.LegalController

  @pages ~w(/terms /terms?lang=ko /privacy /privacy?lang=ko)

  setup do
    previous = Application.get_env(:sukhi_fedi, :instance_config)
    flavor = Application.get_env(:sukhi_fedi, :legal_flavor)

    on_exit(fn ->
      Application.put_env(:sukhi_fedi, :instance_config, previous)
      Application.put_env(:sukhi_fedi, :legal_flavor, flavor)
    end)
  end

  defp page(path) do
    conn = conn(:get, path) |> Plug.Conn.fetch_query_params()

    conn =
      if String.starts_with?(path, "/terms"),
        do: LegalController.terms(conn),
        else: LegalController.privacy(conn)

    conn.resp_body
  end

  test "the configured contact is printed in place of the flavor's, on every page" do
    Application.put_env(:sukhi_fedi, :instance_config, %{
      "legal" => %{
        "contact_email" => "ops@example.org",
        "contact_activitypub" => "@ops@example.org"
      }
    })

    for flavor <- [:sukhi, :natadeco], path <- @pages do
      Application.put_env(:sukhi_fedi, :legal_flavor, flavor)
      body = page(path)

      assert body =~ "ops@example.org", "#{flavor} #{path}"
      assert body =~ "@ops@example.org", "#{flavor} #{path}"
      refute body =~ "f3liz-dev@proton.me", "#{flavor} #{path}"
      refute body =~ "{{", "#{flavor} #{path}"
    end
  end

  test "nothing configured: each flavor keeps printing its own address" do
    Application.put_env(:sukhi_fedi, :instance_config, %{})

    Application.put_env(:sukhi_fedi, :legal_flavor, :sukhi)
    assert page("/privacy") =~ "f3liz-dev@proton.me"
    assert page("/terms?lang=ko") =~ "@kuro_admin@sukhi.f3liz.casa"

    Application.put_env(:sukhi_fedi, :legal_flavor, :natadeco)
    assert page("/privacy") =~ "admin@natadeco.com"
    assert page("/terms") =~ "@admin@natadeco.com"
  end

  test "every placeholder in the baked documents is one Values knows" do
    Application.put_env(:sukhi_fedi, :instance_config, %{})

    for flavor <- [:sukhi, :natadeco], path <- @pages do
      Application.put_env(:sukhi_fedi, :legal_flavor, flavor)
      refute page(path) =~ "{{", "#{flavor} #{path} has an unfilled placeholder"
    end
  end
end
