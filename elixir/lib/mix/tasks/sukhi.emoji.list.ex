# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule Mix.Tasks.Sukhi.Emoji.List do
  @moduledoc """
  List registered custom emojis.

      mix sukhi.emoji.list [options]

  ## Options

      --category <category>   Filter by category
  """

  use Mix.Task

  @shortdoc "List registered custom emojis"

  @impl Mix.Task
  def run(args) do
    {opts, _argv, _} =
      OptionParser.parse(args,
        switches: [
          category: :string
        ]
      )

    Mix.Task.run("app.config")
    {:ok, _} = Application.ensure_all_started(:sukhi_fedi)

    emojis = SukhiFedi.CustomEmojis.list_local(opts)

    if emojis == [] do
      Mix.shell().info("No custom emojis found.")
    else
      Mix.shell().info("#{length(emojis)} custom emoji(s):")

      Enum.each(emojis, fn e ->
        cat_str = if e.category, do: " [#{e.category}]", else: ""
        alias_str = if e.aliases != [] and e.aliases != nil, do: " (aliases: #{Enum.join(e.aliases, ", ")})", else: ""
        Mix.shell().info("  :#{e.shortcode}:#{cat_str}#{alias_str} -> #{e.image_url}")
      end)
    end
  end
end
