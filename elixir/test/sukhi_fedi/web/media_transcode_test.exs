# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Web.MediaTranscodeTest do
  use ExUnit.Case, async: true

  alias SukhiFedi.Web.MediaTranscode
  alias Vix.Vips.Image
  alias Vix.Vips.Operation

  # 写真っぽい(圧縮しがいのある)テスト画像。真っ黒だと jpeg も avif も
  # 数百 byte になって大小の比較にならないので、ノイズを使う。
  defp noise_buffer(suffix, width \\ 320, height \\ 240) do
    {:ok, img} = Operation.gaussnoise(width, height, mean: 128.0, sigma: 30.0)
    {:ok, buf} = Image.write_to_buffer(img, suffix)
    buf
  end

  test "jpeg を avif に変換して縮める" do
    jpg = noise_buffer(".jpg[Q=85]")

    {out, ct} = MediaTranscode.maybe(jpg, "image/jpeg", :avif)

    assert ct == "image/avif"
    assert byte_size(out) < byte_size(jpg)
  end

  test "png を webp に変換して縮める" do
    png = noise_buffer(".png")

    {out, ct} = MediaTranscode.maybe(png, "image/png", :webp)

    assert ct == "image/webp"
    assert byte_size(out) < byte_size(png)
  end

  test "content-type の parameter 付きでも変換する" do
    jpg = noise_buffer(".jpg[Q=85]")

    {_out, ct} = MediaTranscode.maybe(jpg, "image/JPEG; charset=utf-8", :avif)

    assert ct == "image/avif"
  end

  test "target 無しはそのまま" do
    jpg = noise_buffer(".jpg[Q=85]")

    assert {^jpg, "image/jpeg"} = MediaTranscode.maybe(jpg, "image/jpeg", nil)
  end

  test "webp → webp は再エンコードせずそのまま" do
    webp = noise_buffer(".webp[Q=80]")

    assert {^webp, "image/webp"} = MediaTranscode.maybe(webp, "image/webp", :webp)
  end

  test "対象外の形式(svg / gif / video)はそのまま" do
    svg = "<svg xmlns='http://www.w3.org/2000/svg'/>"
    assert {^svg, "image/svg+xml"} = MediaTranscode.maybe(svg, "image/svg+xml", :avif)

    gif = "GIF89a..."
    assert {^gif, "image/gif"} = MediaTranscode.maybe(gif, "image/gif", :avif)

    vid = "not really a video"
    assert {^vid, "video/mp4"} = MediaTranscode.maybe(vid, "video/mp4", :avif)
  end

  test "content-type が嘘(中身が画像でない)ならそのまま" do
    junk = :crypto.strong_rand_bytes(64)

    assert {^junk, "image/jpeg"} = MediaTranscode.maybe(junk, "image/jpeg", :avif)
  end

  test "画素数が上限を超える画像はそのまま" do
    # 4K(3840x2160) を一回りだけ超える。中身は黒で軽い。
    {:ok, img} = Operation.black(3900, 2200, bands: 3)
    {:ok, png} = Image.write_to_buffer(img, ".png")

    assert {^png, "image/png"} = MediaTranscode.maybe(png, "image/png", :avif)
  end

  test "変換して縮まないなら原本のまま" do
    # 1x1 png は数十 byte。avif の container overhead のほうが大きい。
    {:ok, img} = Operation.black(1, 1, bands: 3)
    {:ok, png} = Image.write_to_buffer(img, ".png")

    assert {^png, "image/png"} = MediaTranscode.maybe(png, "image/png", :avif)
  end

  # 16x16・2 フレームの本物の animated webp(img2webp 製)。libvips で
  # animated webp を組み立てるのは savers の事情で回りくどいので、
  # 出来上がった 418 bytes をそのまま持っておく。
  @animated_webp Base.decode64!(
                   "UklGRpoBAABXRUJQVlA4WAoAAAACAAAADwAADwAAQU5JTQYAAAD/////AABBTk1GdgAAAAAAAAAAAA8AAA8AAGQAAAJWUDhMXQAAAC8PwAMAcBBJkhSlM6zgDCs4K/7vTgCCtm1jJhvTn+nPJAbZRiram7zamzza+j8QgEhEKURKpVRVB4qolIiTpE5EdukSnqhu4P/JmDk9HY1MLk0aZHPz02vfu32tAABBTk1G8AAAAAAAAAAAAA8AAA8AAGQAAABWUDhM2AAAAC8PwAMAD8E2sm0l57v/iCoogoj+c7pwlzrYRrat5H3/0c8Er4iaiSnDIXN3RrFttXn0DirQgRwsYgl2LdmRzH8A9w+EfD/8HJGDS4E3JKABBfRJe07NAksDfwwjgLcwnBdJQUZQER38+nYRN+f2l1m4wxkup3NptYvMd5odlSybmjMGh5Fkm9azbSP/KN83EpiN6L8it20b5jY7nlE+hQFYMvlEDUADVLT6D5dOPQ4RAw+2Lgz6/bIOuS1fsxI1zJJafSobF+8uPt77TTo9p+J50QNNevoHAA=="
                 )

  test "アニメーション(複数ページ)はそのまま" do
    # 前提の確認: ちゃんと 2 ページの webp として読める。
    {:ok, reloaded} = Image.new_from_buffer(@animated_webp)
    assert {:ok, 2} = Image.header_value(reloaded, "n-pages")

    webp = @animated_webp
    assert {^webp, "image/webp"} = MediaTranscode.maybe(webp, "image/webp", :avif)
  end
end
