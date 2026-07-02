# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Web.MediaTranscodeTest do
  use ExUnit.Case, async: true

  alias SukhiFedi.Web.MediaTranscode
  alias SukhiFedi.Web.MediaTranscode.Worker
  alias Vix.Vips.Image
  alias Vix.Vips.Operation

  # 写真っぽい(圧縮しがいのある)テスト画像。真っ黒だと jpeg も avif も
  # 数百 byte になって大小の比較にならないので、ノイズを使う。
  defp noise_buffer(suffix, width \\ 320, height \\ 240) do
    {:ok, img} = Operation.gaussnoise(width, height, mean: 128.0, sigma: 30.0)
    {:ok, buf} = Image.write_to_buffer(img, suffix)
    buf
  end

  # テストごとに独立した鍵(Cache.Ets はアプリ全体で共有なので)。
  defp key, do: {:test, make_ref()}

  test "webp はその場で変換して決着" do
    png = noise_buffer(".png")

    {out, ct, mode} = MediaTranscode.maybe(png, "image/png", {:webp, key()})

    assert ct == "image/webp"
    assert mode == :final
    assert byte_size(out) < byte_size(png)
  end

  test "avif の初回は webp でつなぎ、裏で焼けたら avif で決着" do
    jpg = noise_buffer(".jpg[Q=85]")
    k = key()

    # 一回目: AVIF はまだ無いので、その場の webp を「また聞いて」で返す。
    {out, ct, mode} = MediaTranscode.maybe(jpg, "image/jpeg", {:avif, k})
    assert ct == "image/webp"
    assert mode == :retry
    assert byte_size(out) < byte_size(jpg)

    # 裏の encode が終わったら、同じ鍵は avif で決着する。
    :ok = Worker.drain()
    {out, ct, mode} = MediaTranscode.maybe(jpg, "image/jpeg", {:avif, k})
    assert ct == "image/avif"
    assert mode == :final
    assert byte_size(out) < byte_size(jpg)
  end

  test "avif が縮まない画像は reject に落ちて、webp で決着する" do
    # 1x1 png(282B)。avif は container overhead で 537B に膨らむ =
    # 裏で reject になる。webp は 256B で、こちらは勝つ。
    {:ok, img} = Operation.black(1, 1, bands: 3)
    {:ok, png} = Image.write_to_buffer(img, ".png")
    k = key()

    # 初回は間に合わせの webp + :retry。
    assert {_out, "image/webp", :retry} = MediaTranscode.maybe(png, "image/png", {:avif, k})

    # 裏で「avif は駄目」と分かったら、以後は待たずに webp で決着。
    :ok = Worker.drain()
    assert {:ok, :reject} = SukhiFedi.Cache.Ets.get(:media_variants, k)
    assert {_out, "image/webp", :final} = MediaTranscode.maybe(png, "image/png", {:avif, k})
  end

  test "content-type の parameter 付きでも変換する" do
    jpg = noise_buffer(".jpg[Q=85]")

    {_out, ct, _mode} = MediaTranscode.maybe(jpg, "image/JPEG; charset=utf-8", {:webp, key()})

    assert ct == "image/webp"
  end

  test "頼まれていない(variant なし)ならそのまま決着" do
    jpg = noise_buffer(".jpg[Q=85]")

    assert {^jpg, "image/jpeg", :final} = MediaTranscode.maybe(jpg, "image/jpeg", nil)
  end

  test "webp → webp は再エンコードせずそのまま" do
    webp = noise_buffer(".webp[Q=80]")

    assert {^webp, "image/webp", :final} =
             MediaTranscode.maybe(webp, "image/webp", {:webp, key()})
  end

  test "対象外の形式(svg / gif / video)はそのまま決着" do
    svg = "<svg xmlns='http://www.w3.org/2000/svg'/>"
    assert {^svg, "image/svg+xml", :final} = MediaTranscode.maybe(svg, "image/svg+xml", {:avif, key()})

    gif = "GIF89a..."
    assert {^gif, "image/gif", :final} = MediaTranscode.maybe(gif, "image/gif", {:avif, key()})

    vid = "not really a video"
    assert {^vid, "video/mp4", :final} = MediaTranscode.maybe(vid, "video/mp4", {:avif, key()})
  end

  test "content-type が嘘(中身が画像でない)ならそのまま決着" do
    junk = :crypto.strong_rand_bytes(64)

    assert {^junk, "image/jpeg", :final} = MediaTranscode.maybe(junk, "image/jpeg", {:avif, key()})
  end

  test "画素数が上限を超える画像はそのまま決着(裏にも回さない)" do
    # 4K(3840x2160) を一回りだけ超える。中身は黒で軽い。
    {:ok, img} = Operation.black(3900, 2200, bands: 3)
    {:ok, png} = Image.write_to_buffer(img, ".png")
    k = key()

    assert {^png, "image/png", :final} = MediaTranscode.maybe(png, "image/png", {:avif, k})

    # 裏に enqueue されていない = drain 後も何も置かれていない。
    :ok = Worker.drain()
    assert :miss = SukhiFedi.Cache.Ets.get(:media_variants, k)
  end

  # 16x16・2 フレームの本物の animated webp(img2webp 製)。libvips で
  # animated webp を組み立てるのは savers の事情で回りくどいので、
  # 出来上がった 418 bytes をそのまま持っておく。
  @animated_webp Base.decode64!(
                   "UklGRpoBAABXRUJQVlA4WAoAAAACAAAADwAADwAAQU5JTQYAAAD/////AABBTk1GdgAAAAAAAAAAAA8AAA8AAGQAAAJWUDhMXQAAAC8PwAMAcBBJkhSlM6zgDCs4K/7vTgCCtm1jJhvTn+nPJAbZRiram7zamzza+j8QgEhEKURKpVRVB4qolIiTpE5EdukSnqhu4P/JmDk9HY1MLk0aZHPz02vfu32tAABBTk1G8AAAAAAAAAAAAA8AAA8AAGQAAABWUDhM2AAAAC8PwAMAD8E2sm0l57v/iCoogoj+c7pwlzrYRrat5H3/0c8Er4iaiSnDIXN3RrFttXn0DirQgRwsYgl2LdmRzH8A9w+EfD/8HJGDS4E3JKABBfRJe07NAksDfwwjgLcwnBdJQUZQER38+nYRN+f2l1m4wxkup3NptYvMd5odlSybmjMGh5Fkm9azbSP/KN83EpiN6L8it20b5jY7nlE+hQFYMvlEDUADVLT6D5dOPQ4RAw+2Lgz6/bIOuS1fsxI1zJJafSobF+8uPt77TTo9p+J50QNNevoHAA=="
                 )

  test "アニメーション(複数ページ)はそのまま決着" do
    # 前提の確認: ちゃんと 2 ページの webp として読める。
    {:ok, reloaded} = Image.new_from_buffer(@animated_webp)
    assert {:ok, 2} = Image.header_value(reloaded, "n-pages")

    webp = @animated_webp

    assert {^webp, "image/webp", :final} =
             MediaTranscode.maybe(webp, "image/webp", {:avif, key()})
  end
end
