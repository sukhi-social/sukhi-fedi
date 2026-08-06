# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiApi.Views.MastodonMedia do
  @moduledoc """
  Render a `Media` row into Mastodon MediaAttachment JSON shape.
  Used by `MastodonStatus` for embedded attachments and by
  `MastodonMedia` (the upload capability) for direct responses.
  """

  alias SukhiApi.Views.Id
  alias SukhiApi.Views.ProxyUrl

  @spec render(map()) :: map()
  def render(media) do
    %{
      id: Id.encode(media.id),
      type: Map.get(media, :type) || "unknown",
      url: display_url(media),
      preview_url: display_url(media),
      remote_url: Map.get(media, :remote_url),
      text_url: nil,
      meta: meta(media),
      description: Map.get(media, :description),
      blurhash: Map.get(media, :blurhash),
      # Not a Mastodon field — sukhi extension so a non-image Clip can
      # show the name it was uploaded under instead of just an extension.
      filename: Map.get(media, :filename)
    }
  end

  # リモート添付(remote_url あり)は相手サーバの URL を直接渡さず、
  # gateway の /proxy/media/:id に書き換える ─ 閲覧者の IP を相手に
  # 渡さない + CF edge cache に乗る。原本は remote_url にそのまま残る
  # (Mastodon の意味論どおり)。ローカル upload は /uploads/ のまま。
  defp display_url(media) do
    case Map.get(media, :remote_url) do
      remote when is_binary(remote) -> ProxyUrl.media(media.id, remote)
      _ -> Map.get(media, :url)
    end
  end

  defp meta(media) do
    base = %{}

    base =
      case {Map.get(media, :width), Map.get(media, :height)} do
        {w, h} when is_integer(w) and is_integer(h) ->
          Map.put(base, :original, %{width: w, height: h, size: "#{w}x#{h}", aspect: w / h})

        _ ->
          base
      end

    base
  end
end
