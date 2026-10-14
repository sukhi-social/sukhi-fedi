# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Fedi.OjakShadowTest do
  # Flips application env, so not async.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias SukhiFedi.Fedi.OjakShadow

  setup do
    previous = Application.get_env(:sukhi_fedi, :ojak_shadow)
    on_exit(fn -> Application.put_env(:sukhi_fedi, :ojak_shadow, previous) end)
  end

  defp shadow(on?), do: Application.put_env(:sukhi_fedi, :ojak_shadow, on?)

  test "agreement is silent" do
    shadow(true)

    log =
      capture_log(fn ->
        assert :ok = OjakShadow.compare(:t, :ok, fn -> :ok end)

        assert :ok =
                 OjakShadow.compare(:t, {:error, :bad_signature}, fn -> {:error, :invalid} end)
      end)

    assert log == ""
  end

  test "disagreement warns, and names both verdicts" do
    shadow(true)

    log =
      capture_log(fn ->
        assert :ok = OjakShadow.compare(:http_signature, :ok, fn -> {:error, :invalid} end)
        assert :ok = OjakShadow.compare(:oip, {:error, :bad_proof}, fn -> :ok end)
      end)

    assert log =~ "ojak shadow disagreement on http_signature: ours=:ok ojak={:error, :invalid}"
    assert log =~ "ojak shadow disagreement on oip"
  end

  test "off does nothing — ojak is not even asked" do
    shadow(false)

    log =
      capture_log(fn ->
        assert :ok = OjakShadow.compare(:t, :ok, fn -> flunk("ojak was asked") end)
      end)

    assert log == ""
  end

  test "whatever ojak raises or throws is swallowed" do
    shadow(true)

    assert :ok = OjakShadow.compare(:t, :ok, fn -> raise "panic" end)
    assert :ok = OjakShadow.compare(:t, :ok, fn -> throw(:nope) end)
    assert :ok = OjakShadow.compare(:t, :ok, fn -> exit(:gone) end)
  end

  test "a broken PEM comes out as an error tuple, not a crash" do
    shadow(true)

    assert {:error, _} =
             SukhiFedi.Fedi.Ojak.verify_http_signature(
               "POST",
               "https://sukhi.test/inbox",
               %{"signature" => "keyId=\"x\""},
               "{}",
               "not a pem"
             )
  end
end
