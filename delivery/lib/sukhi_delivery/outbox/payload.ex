# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiDelivery.Outbox.Payload do
  @moduledoc """
  Small `maybe_put_*` steps that build a translator payload: each adds its
  key only when the event carried the field, so absent fields stay absent on
  the wire.
  """

  alias SukhiDelivery.Repo

  # Local custom emoji only — domain IS NULL row in `custom_emojis`.
  # Unicode reactions and remote shortcodes leave tag absent.
  @doc false
  def maybe_attach_emoji_tag(payload, emoji) when is_binary(emoji) do
    with [_, shortcode] <- Regex.run(~r/^:([^:@]+)(?:@\.)?:$/, emoji),
         %SukhiDelivery.Schema.CustomEmoji{image_url: url, static_url: static_url} <-
           Repo.get_by(SukhiDelivery.Schema.CustomEmoji, shortcode: shortcode, domain: nil) do
      Map.put(payload, :tag, %{name: ":#{shortcode}:", url: url, static_url: static_url})
    else
      _ -> payload
    end
  end

  def maybe_attach_emoji_tag(payload, _), do: payload

  @doc false
  def maybe_put_audience(payload, a) when is_binary(a) and a != "",
    do: Map.put(payload, :audience, a)

  def maybe_put_audience(payload, _), do: payload

  # 題が無ければ何も足さない ── 話す板の投稿は素の Note のまま。
  @doc false
  def maybe_put_titled(payload, p) do
    case p["title"] do
      t when is_binary(t) and t != "" ->
        payload
        |> Map.put(:title, t)
        |> Map.put(:authorHandle, p["author_handle"])
        |> Map.put(:authorUri, p["author_uri"])
        |> Map.put(:asArticle, !!p["as_article"])

      _ ->
        payload
    end
  end

  @doc false
  def maybe_put_misskey_content(payload, content) when is_binary(content),
    do: Map.put(payload, :misskeyContent, content)

  def maybe_put_misskey_content(payload, _), do: payload

  # A note may quote another (Misskey 引用ノート). Thread the quoted
  # AP id through to the `note` translator only when one is present.
  @doc false
  def maybe_put_quote(payload, quote_uri) when is_binary(quote_uri) and quote_uri != "" do
    Map.put(payload, :quoteUrl, quote_uri)
  end

  def maybe_put_quote(payload, _), do: payload

  # FEP-044f: the authorization stamp we were granted for quoting a remote
  # post. Carried on the re-delivered Update so receivers verify the quote.
  @doc false
  def maybe_put_quote_authorization(payload, stamp) when is_binary(stamp) and stamp != "" do
    Map.put(payload, :quoteAuthorization, stamp)
  end

  def maybe_put_quote_authorization(payload, _), do: payload

  # The content warning rides as AP `summary`; only send it when present.
  @doc false
  def maybe_put_cw(payload, cw) when is_binary(cw) and cw != "" do
    Map.put(payload, :summary, cw)
  end

  def maybe_put_cw(payload, _), do: payload

  # `sensitive` defaults to absent (= not sensitive) on the wire, so only send
  # the flag when it's actually set.
  @doc false
  def maybe_put_sensitive(payload, true), do: Map.put(payload, :sensitive, true)
  def maybe_put_sensitive(payload, _), do: payload

  # Media descriptors built gateway-side by `SukhiFedi.AP.MediaSerialize`
  # ride through the outbox event under `media`. The bun `note` / `dm`
  # translator turns them into the Note's `attachment`.
  @doc false
  def maybe_put_attachments(payload, media) when is_list(media) and media != [] do
    Map.put(payload, :attachments, media)
  end

  def maybe_put_attachments(payload, _), do: payload

  @doc false
  def maybe_put_emojis(payload, emojis) when is_list(emojis) and emojis != [] do
    Map.put(payload, :emojis, emojis)
  end

  def maybe_put_emojis(payload, _), do: payload
end
