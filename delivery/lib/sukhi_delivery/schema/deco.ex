# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiDelivery.Schema.Deco do
  use Ecto.Schema

  # 配達の側から見た板。要るのは署名の鍵と、名前だけ ── 板の Announce は
  # 板自身の鍵で署名するので、`accounts` を引くだけでは見つからない。
  #
  # 板は natadeco の addon のもので、この鯖では表そのものが無いことも
  # ある。読むだけ・落ちたら諦める、で扱う。
  schema "decos" do
    field(:slug, :string)
    field(:private_key_jwk, :map)
    field(:public_key_pem, :string)
    field(:has_actor, :boolean, default: true)
  end
end
