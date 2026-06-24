# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Addons.Media.ScrubTest do
  use ExUnit.Case, async: true

  alias SukhiFedi.Addons.Media.Scrub

  describe "scrub/1 JPEG" do
    test "drops the APP1 (Exif) segment but keeps APP0/SOF/scan" do
      soi = <<0xFF, 0xD8>>
      # APP1 carrying a fake Exif block with "GPS" in it.
      app1_payload = "Exif\0\0GPS:35.6,139.7"
      app1 = <<0xFF, 0xE1, byte_size(app1_payload) + 2::16, app1_payload::binary>>
      app0 = <<0xFF, 0xE0, 0x00, 0x06, "JFIF">>
      sof0 = <<0xFF, 0xC0, 0x00, 0x08, 0x08, 0x00, 0x10, 0x00, 0x10, 0x03>>
      scan = <<0xFF, 0xDA, 0x00, 0x02, 0xAA, 0xBB, 0xFF, 0xD9>>

      input = soi <> app1 <> app0 <> sof0 <> scan
      out = Scrub.scrub(input)

      assert out == soi <> app0 <> sof0 <> scan
      refute String.contains?(out, "GPS")
      assert <<0xFF, 0xD8, _::binary>> = out
    end

    test "leaves an APP1-free JPEG byte-for-byte unchanged" do
      jpeg =
        <<0xFF, 0xD8>> <>
          <<0xFF, 0xE0, 0x00, 0x06, "JFIF">> <>
          <<0xFF, 0xDA, 0x00, 0x02, 0x12, 0x34, 0xFF, 0xD9>>

      assert Scrub.scrub(jpeg) == jpeg
    end
  end

  describe "scrub/1 PNG" do
    test "drops tEXt/eXIf chunks but keeps IHDR/IDAT/IEND" do
      sig = <<0x89, "PNG\r\n", 0x1A, 0x0A>>
      ihdr = chunk("IHDR", <<0::32, 0::32, 8, 6, 0, 0, 0>>)
      text = chunk("tEXt", "Comment\0taken at home")
      exif = chunk("eXIf", "II*\0fake-exif")
      idat = chunk("IDAT", <<0xDE, 0xAD, 0xBE, 0xEF>>)
      iend = chunk("IEND", "")

      input = sig <> ihdr <> text <> exif <> idat <> iend
      out = Scrub.scrub(input)

      assert out == sig <> ihdr <> idat <> iend
      refute String.contains?(out, "home")
      refute String.contains?(out, "fake-exif")
    end
  end

  test "scrub/1 passes through formats it doesn't understand" do
    gif = <<"GIF89a", 0x10, 0x00, 0x10, 0x00, 0x00>>
    assert Scrub.scrub(gif) == gif
  end

  # PNG chunk: length(32) + type(4) + data + crc(4). We never validate the
  # CRC, so any 4 bytes stand in for it here.
  defp chunk(type, data) do
    <<byte_size(data)::32, type::binary, data::binary, 0, 0, 0, 0>>
  end
end
