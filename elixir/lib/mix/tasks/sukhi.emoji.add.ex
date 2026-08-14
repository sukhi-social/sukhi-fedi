# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule Mix.Tasks.Sukhi.Emoji.Add do
  @moduledoc """
  Register a custom emoji.

      mix sukhi.emoji.add <name> <image_url> [options]

  ## Options

      --category <category>   Emoji category (e.g. "blobcat")
      --aliases <a,b,c>       Comma-separated aliases
      --no-picker             Hide from emoji picker
  """

  use Mix.Task

  @shortdoc "Add/register a custom emoji"

  @impl Mix.Task
  def run(args) do
    {opts, argv, _} =
      OptionParser.parse(args,
        switches: [
          category: :string,
          aliases: :string,
          picker: :boolean
        ]
      )

    case argv do
      [name, url] ->
        Mix.Task.run("app.config")
        {:ok, _} = Application.ensure_all_started(:sukhi_fedi)

        aliases =
          case Keyword.get(opts, :aliases) do
            str when is_binary(str) -> String.split(str, ",", trim: true)
            _ -> []
          end

        category = Keyword.get(opts, :category)
        visible_in_picker = Keyword.get(opts, :picker, true)

        attrs = %{
          name: name,
          url: url,
          category: category,
          aliases: aliases,
          visible_in_picker: visible_in_picker
        }

        case SukhiFedi.CustomEmojis.register(attrs) do
          {:ok, emoji} ->
            Mix.shell().info("✓ Added emoji :#{emoji.shortcode}: (#{emoji.image_url})")

          {:error, reason} ->
            Mix.shell().error("✗ Failed to add emoji: #{inspect(reason)}")
        end

      _ ->
        Mix.shell().error("Usage: mix sukhi.emoji.add <name> <image_url> [--category <cat>] [--aliases <a,b>]")
    end
  end
end
