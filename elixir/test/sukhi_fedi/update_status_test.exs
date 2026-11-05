# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.UpdateStatusTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  alias SukhiFedi.UpdateStatus
  alias SukhiFedi.Web.Admin.Render

  @now ~U[2026-11-05 05:00:00Z]

  setup do
    path = Path.join(System.tmp_dir!(), "status-#{System.unique_integer([:positive])}.json")
    prev = Application.get_env(:sukhi_fedi, :gitops_status_path)
    Application.put_env(:sukhi_fedi, :gitops_status_path, path)

    on_exit(fn ->
      File.rm(path)
      Application.put_env(:sukhi_fedi, :gitops_status_path, prev)
    end)

    %{path: path}
  end

  defp write(path, overrides \\ %{}) do
    doc =
      Map.merge(
        %{
          "schema" => 1,
          "env" => "dev",
          "checked_at" => "2026-11-05T04:58:00Z",
          "state" => "update_available",
          "applied" => %{"commit" => "a", "version" => "sha-a81329d"},
          "available" => %{"commit" => "b", "version" => "sha-3f9e0a1", "verified" => true},
          "last_error" => nil
        },
        overrides
      )

    File.write!(path, Jason.encode!(doc))
  end

  test "absent file hides the section (local dev)" do
    assert UpdateStatus.read(@now) == nil
  end

  test "garbage and unknown schema are treated as absent", %{path: path} do
    File.write!(path, "not json")
    assert UpdateStatus.read(@now) == nil
    File.write!(path, ~s({"schema":2}))
    assert UpdateStatus.read(@now) == nil
  end

  test "reads a fresh update_available document", %{path: path} do
    write(path)
    st = UpdateStatus.read(@now)
    assert st.state == :update_available
    assert st.available["version"] == "sha-3f9e0a1"
    assert st.applied["version"] == "sha-a81329d"
  end

  test "an old checked_at becomes :stale whatever the file says", %{path: path} do
    write(path, %{"state" => "up_to_date", "checked_at" => "2026-11-05T04:30:00Z"})
    assert UpdateStatus.read(@now).state == :stale
  end

  test "an unknown state is shown as :error, not trusted", %{path: path} do
    write(path, %{"state" => "bogus"})
    assert UpdateStatus.read(@now).state == :error
  end

  test "the template escapes last_error and shows rejected state", %{path: path} do
    write(path, %{"state" => "rejected", "last_error" => "<script>x</script>"})
    html = Render.render_template("system/update.html.eex", update: UpdateStatus.read(@now))
    assert html =~ "見送り中"
    assert html =~ "&lt;script&gt;"
    refute html =~ "<script>"
  end
end
