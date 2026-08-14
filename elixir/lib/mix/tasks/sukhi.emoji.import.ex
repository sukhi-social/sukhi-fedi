# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule Mix.Tasks.Sukhi.Emoji.Import do
  @moduledoc """
  Import custom emojis from a Misskey instance, a JSON file, or a zip package.

      mix sukhi.emoji.import <source> [options]

  ## Sources

      https://misskey.io           Misskey server URL
      emojis.json                  Misskey export or list JSON file
      pack.zip                     Misskey emoji pack zip archive

  ## Options

      --category <category>        Override/assign category
      --prefix <prefix>            Prefix shortcodes
  """

  use Mix.Task

  @shortdoc "Import custom emojis from Misskey / JSON / Zip"

  @impl Mix.Task
  def run(args) do
    {opts, argv, _} =
      OptionParser.parse(args,
        switches: [
          category: :string,
          prefix: :string
        ]
      )

    case argv do
      [source] ->
        Mix.Task.run("app.config")
        {:ok, _} = Application.ensure_all_started(:sukhi_fedi)

        import_opts = [
          category: Keyword.get(opts, :category),
          prefix: Keyword.get(opts, :prefix, "")
        ]

        result =
          cond do
            String.starts_with?(source, "http://") or String.starts_with?(source, "https://") ->
              Mix.shell().info("Importing emojis from Misskey server #{source}...")
              SukhiFedi.CustomEmojis.import_from_misskey(source, import_opts)

            String.ends_with?(source, ".zip") ->
              Mix.shell().info("Importing emojis from zip package #{source}...")
              SukhiFedi.CustomEmojis.import_from_zip(source, import_opts)

            String.ends_with?(source, ".json") or File.exists?(source) ->
              Mix.shell().info("Importing emojis from file #{source}...")
              case File.read(source) do
                {:ok, content} -> SukhiFedi.CustomEmojis.import_from_json(content, import_opts)
                {:error, reason} -> {:error, reason}
              end

            true ->
              # Assume server hostname like misskey.io
              Mix.shell().info("Importing emojis from Misskey server https://#{source}...")
              SukhiFedi.CustomEmojis.import_from_misskey(source, import_opts)
          end

        case result do
          {:ok, %{imported: imported, total: total}} ->
            Mix.shell().info("✓ Successfully imported #{imported}/#{total} emojis.")

          {:error, reason} ->
            Mix.shell().error("✗ Import failed: #{inspect(reason)}")
        end

      _ ->
        Mix.shell().error("Usage: mix sukhi.emoji.import <url_or_filepath> [--category <cat>] [--prefix <pre>]")
    end
  end
end
