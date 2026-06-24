# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Addons.Media.Scrub do
  @moduledoc """
  Strip privacy-sensitive metadata from an uploaded image before we store
  it — no decode, no native dependency, the same byte-walking style as
  `Dimensions`. A phone photo carries GPS coordinates, a capture time and
  the device model in its Exif block; none of that should leak just
  because someone shared a picture.

  What we drop:

    * **JPEG** — the `APP1` segment (Exif and XMP). `APP0` (JFIF) and
      `APP2` (ICC colour profile) are kept, so the image still renders
      with the right colours.
    * **PNG** — the `eXIf` chunk plus the textual chunks (`tEXt`,
      `zTXt`, `iTXt`), which can carry location, comments or software
      tags. Every critical/colour chunk is left untouched.

  Anything we don't recognise (WebP, GIF, …) passes through unchanged —
  scrubbing never corrupts, it only removes the segments it understands.
  WebP can hold an Exif chunk too; that's a known gap, not yet walked.
  """

  @spec scrub(binary()) :: binary()
  def scrub(<<0xFF, 0xD8, rest::binary>>) do
    IO.iodata_to_binary([<<0xFF, 0xD8>> | jpeg(rest)])
  end

  def scrub(<<0x89, "PNG\r\n", 0x1A, 0x0A, rest::binary>>) do
    IO.iodata_to_binary([<<0x89, "PNG\r\n", 0x1A, 0x0A>> | png(rest)])
  end

  def scrub(bytes) when is_binary(bytes), do: bytes

  # ── JPEG ───────────────────────────────────────────────────────────────
  # Walk marker segments. At Start-Of-Scan (0xDA) the entropy-coded image
  # data begins with no length of its own, so copy it and the rest verbatim.
  defp jpeg(<<0xFF, 0xDA, _::binary>> = rest), do: [rest]

  # APP1 (0xE1) = Exif / XMP → drop. Everything else with a length → keep.
  # `len` counts itself (2 bytes) plus the payload; `body` already starts
  # past `len`, so the payload is `len - 2` bytes.
  defp jpeg(<<0xFF, marker, len::16, body::binary>>) when len >= 2 do
    payload = len - 2

    case body do
      <<seg::binary-size(^payload), next::binary>> ->
        if marker == 0xE1 do
          jpeg(next)
        else
          [<<0xFF, marker, len::16, seg::binary>> | jpeg(next)]
        end

      _ ->
        [<<0xFF, marker, len::16, body::binary>>]
    end
  end

  # A lone 0xFF (fill byte before a marker): copy it and carry on.
  defp jpeg(<<0xFF, rest::binary>>), do: [<<0xFF>> | jpeg(rest)]
  defp jpeg(rest), do: [rest]

  # ── PNG ────────────────────────────────────────────────────────────────
  @png_strip ~w(eXIf tEXt zTXt iTXt)

  defp png(<<len::32, type::binary-size(4), body::binary>>) do
    case body do
      <<data::binary-size(^len), crc::binary-size(4), next::binary>> ->
        if type in @png_strip do
          png(next)
        else
          [<<len::32, type::binary, data::binary, crc::binary>> | png(next)]
        end

      _ ->
        [<<len::32, type::binary, body::binary>>]
    end
  end

  defp png(rest), do: [rest]
end
