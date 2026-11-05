# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiShared.InstanceConfigTest do
  use ExUnit.Case, async: false

  test "loads structured instance settings and converts routes" do
    path = temp_path()

    File.write!(
      path,
      JSON.encode!(%{
        "site_name" => "Example",
        "frontends" => %{
          "relay" => %{"type" => "builtin"},
          "web-next" => %{"url" => "http://web:3000"}
        },
        "routes" => [%{"pattern" => "/**", "frontend" => "web-next"}]
      })
    )

    System.put_env("SUKHI_INSTANCE_CONFIG", path)

    on_exit(fn ->
      System.delete_env("SUKHI_INSTANCE_CONFIG")
      File.rm(path)
    end)

    config = SukhiShared.InstanceConfig.load()
    assert config["site_name"] == "Example"
    assert SukhiShared.InstanceConfig.frontends(config) == %{"web-next" => "http://web:3000"}

    assert SukhiShared.InstanceConfig.active_frontends(config) == %{
             "web-next" => "http://web:3000"
           }

    assert SukhiShared.InstanceConfig.routes(config) == ["/**=web-next"]
  end

  test "rejects a route pointing at an undeclared upstream" do
    path = temp_path()

    File.write!(
      path,
      JSON.encode!(%{
        "frontends" => %{"web-next" => %{"url" => "http://web:3000"}},
        "routes" => [%{"pattern" => "/**", "frontend" => "missing"}]
      })
    )

    System.put_env("SUKHI_INSTANCE_CONFIG", path)

    on_exit(fn ->
      System.delete_env("SUKHI_INSTANCE_CONFIG")
      File.rm(path)
    end)

    assert_raise ArgumentError, ~r/declared frontend/, &SukhiShared.InstanceConfig.load/0
  end

  describe "legal" do
    test "reads the operator's contact and puts the @ on a bare handle" do
      config =
        load_with(%{
          "legal" => %{
            "contact_email" => "ops@example.org",
            "contact_activitypub" => "ops@example.org"
          }
        })

      assert SukhiShared.InstanceConfig.legal(config) == %{
               contact_email: "ops@example.org",
               contact_activitypub: "@ops@example.org"
             }
    end

    test "is empty when the section is absent" do
      assert SukhiShared.InstanceConfig.legal(load_with(%{})) == %{}
    end

    test "refuses values that are not an address, an unknown key, or a non-object" do
      for legal <- [
            %{"contact_email" => "not an address"},
            %{"contact_email" => "<b>x</b>@example.org"},
            %{"contact_activitypub" => "ops"},
            %{"contact_phone" => "0"},
            %{"contact_email" => 1},
            "ops@example.org"
          ] do
        assert_raise ArgumentError, ~r/legal/, fn -> load_with(%{"legal" => legal}) end
      end
    end

    defp load_with(extra) do
      path = temp_path()

      File.write!(
        path,
        JSON.encode!(
          Map.merge(
            %{
              "site_name" => "Example",
              "frontends" => %{"web-next" => %{"url" => "http://web:3000"}},
              "routes" => [%{"pattern" => "/**", "frontend" => "web-next"}]
            },
            extra
          )
        )
      )

      System.put_env("SUKHI_INSTANCE_CONFIG", path)

      on_exit(fn ->
        System.delete_env("SUKHI_INSTANCE_CONFIG")
        File.rm(path)
      end)

      SukhiShared.InstanceConfig.load()
    end
  end

  defp temp_path do
    Path.join(System.tmp_dir!(), "instance_config_#{System.unique_integer([:positive])}.json")
  end
end
