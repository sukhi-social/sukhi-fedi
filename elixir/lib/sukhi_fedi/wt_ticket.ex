# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.WtTicket do
  @moduledoc """
  WebTransport の入場チケットを Ed25519 で署名して発行する。

  karutte（WT のエッジ、別ノード）が公開鍵だけで**ローカル検証**できるようにするための
  もの。接続ごとに sukhi へ問い合わせない＝暗号の直後に安く弾ける＝flood に強い。

  形（karutte 側 `Karutte.Ticket` と同じ契約）:

      token = base64url(payload_json) <> "." <> base64url(ed25519_sig)

  `payload_json` は `{"sub": account_id, "exp": unix_seconds, "feeds": [...]}`。署名対象は
  **base64url(payload_json) の ASCII バイト**（JSON の直列化差を跨いでも一致する）。

  秘密鍵は `:sukhi_fedi, :wt_ticket_key`（生 32 バイト seed の base64）。公開鍵は karutte の
  `:ticket_pubkey` に置く。未設定なら発行しない（`{:error, :no_key}`）＝streaming 同様 best-effort。
  """

  # `mint/2` を feeds 無しで呼んだときだけ効く。実際の発券口
  # （`WtController`）は `feeds:` を明示で渡すので、**チケットに何が載るかを
  # 変えたいならあちらを見ること** ── ここを直しても何も起きない。
  @default_feeds ["local", "user"]
  @default_ttl 300

  @spec mint(integer() | String.t(), keyword()) :: {:ok, String.t()} | {:error, :no_key}
  def mint(account_id, opts \\ []) do
    case priv_key() do
      nil ->
        {:error, :no_key}

      priv ->
        exp = System.system_time(:second) + Keyword.get(opts, :ttl, @default_ttl)
        feeds = Keyword.get(opts, :feeds, @default_feeds)

        b64p =
          %{"sub" => to_string(account_id), "exp" => exp, "feeds" => feeds}
          |> JSON.encode!()
          |> Base.url_encode64(padding: false)

        sig = :crypto.sign(:eddsa, :none, b64p, [priv, :ed25519])
        {:ok, b64p <> "." <> Base.url_encode64(sig, padding: false)}
    end
  end

  defp priv_key do
    with k when is_binary(k) <- Application.get_env(:sukhi_fedi, :wt_ticket_key),
         {:ok, raw} <- Base.decode64(k) do
      raw
    else
      _ -> nil
    end
  end
end
