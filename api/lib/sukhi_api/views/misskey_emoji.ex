# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiApi.Views.MisskeyEmoji do
  @moduledoc """
  Render a `CustomEmoji` struct (or map projection) into Misskey
  emoji JSON shape.
  """

  @spec render(map() | nil) :: map() | nil
  def render(nil), do: nil

  def render(emoji) do
    shortcode = Map.get(emoji, :shortcode) || Map.get(emoji, "shortcode") || ""
    domain = Map.get(emoji, :domain) || Map.get(emoji, "domain")
    image_url = Map.get(emoji, :image_url) || Map.get(emoji, "image_url")
    id = Map.get(emoji, :id) || Map.get(emoji, "id") || shortcode
    category = Map.get(emoji, :category) || Map.get(emoji, "category")

    %{
      id: to_string(id),
      aliases: [],
      name: shortcode,
      category: category,
      host: domain,
      url: image_url,
      license: nil,
      isSensitive: false,
      localOnly: is_nil(domain),
      roleIdsThatCanBeUsedThisEmojiAsReaction: []
    }
  end

  @spec render_list([map()]) :: [map()]
  def render_list(emojis) when is_list(emojis) do
    Enum.map(emojis, &render/1)
  end
end
