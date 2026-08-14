# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.CustomEmojis do
  @moduledoc """
  Custom emoji directory and management.

  Supports:
  - Local emoji registration and lookup (`register/1`, `get_local/1`, `list_local/1`).
  - Remote emoji caching from inbound AP activities (`upsert_from_tag/3`).
  - Misskey custom emoji importing:
    - From remote Misskey instance endpoint (`import_from_misskey/2`).
    - From Misskey export / package JSON (`import_from_json/2`).
    - From Misskey emoji package zip file (`import_from_zip/2`).
  - Extracting custom emojis used in text content (`extract_from_text/1`).
  - Reaction namespacing and resolution (`namespaced/2`, `split/1`, `lookup_many/1`).
  """

  import Ecto.Query

  alias SukhiFedi.Repo
  alias SukhiFedi.Schema.CustomEmoji

  @doc """
  Build the namespaced storage key for a reaction emoji.

  - Unicode glyphs are returned untouched.
  - Local `:shortcode:` (no domain or `@.`) is returned untouched.
  - Remote `:shortcode:` becomes `:shortcode@host:`.
  """
  @spec namespaced(String.t(), String.t() | nil) :: String.t()
  def namespaced(emoji, nil), do: emoji
  def namespaced(emoji, ""), do: emoji
  def namespaced(emoji, "."), do: emoji

  def namespaced(emoji, domain) when is_binary(emoji) and is_binary(domain) do
    case Regex.run(~r/^:([^:@]+)(?:@\.)?:$/, emoji) do
      [_, shortcode] -> ":#{shortcode}@#{domain}:"
      _ -> emoji
    end
  end

  @doc """
  Decompose a stored emoji string back into `{shortcode, domain}` for
  DB lookup. Unicode and bare shortcodes return `nil` for domain.
  Returns `nil` for non-shortcode strings (unicode glyphs).
  """
  @spec split(String.t()) :: {String.t(), String.t() | nil} | nil
  def split(emoji) when is_binary(emoji) do
    case Regex.run(~r/^:([^:@]+)(?:@([^:]+))?:$/, emoji) do
      [_, shortcode] -> {shortcode, nil}
      [_, shortcode, "."] -> {shortcode, nil}
      [_, shortcode, ""] -> {shortcode, nil}
      [_, shortcode, domain] -> {shortcode, domain}
      _ -> nil
    end
  end

  @doc """
  Register or update a custom emoji.
  Accepts shortcode/name, image_url/url, static_url, category, aliases, visible_in_picker, domain.
  """
  @spec register(map()) :: {:ok, %CustomEmoji{}} | {:error, term()}
  def register(attrs) when is_map(attrs) do
    shortcode =
      Map.get(attrs, :shortcode) ||
      Map.get(attrs, "shortcode") ||
      Map.get(attrs, :name) ||
      Map.get(attrs, "name")

    image_url =
      Map.get(attrs, :image_url) ||
      Map.get(attrs, "image_url") ||
      Map.get(attrs, :url) ||
      Map.get(attrs, "url")

    static_url =
      Map.get(attrs, :static_url) ||
      Map.get(attrs, "static_url")

    category =
      Map.get(attrs, :category) ||
      Map.get(attrs, "category")

    aliases =
      case Map.get(attrs, :aliases) || Map.get(attrs, "aliases") do
        list when is_list(list) ->
          list
          |> Enum.filter(&is_binary/1)
          |> Enum.map(&normalize_shortcode/1)
          |> Enum.reject(&(&1 == ""))
          |> Enum.uniq()

        _ ->
          []
      end

    visible_in_picker =
      case Map.get(attrs, :visible_in_picker, Map.get(attrs, "visible_in_picker", true)) do
        false -> false
        _ -> true
      end

    domain =
      case Map.get(attrs, :domain) || Map.get(attrs, "domain") do
        d when is_binary(d) and d != "" and d != "." -> d
        _ -> nil
      end

    with sc when is_binary(sc) and sc != "" <- normalize_shortcode(shortcode),
         url when is_binary(url) and url != "" <- image_url do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      changes = %{
        shortcode: sc,
        domain: domain,
        image_url: url,
        static_url: static_url,
        category: category,
        aliases: aliases,
        visible_in_picker: visible_in_picker,
        last_fetched_at: now
      }

      %CustomEmoji{}
      |> CustomEmoji.changeset(changes)
      |> Repo.insert(
        on_conflict: {:replace, [:image_url, :static_url, :category, :aliases, :visible_in_picker, :last_fetched_at]},
        conflict_target: [:shortcode, :domain],
        returning: true
      )
    else
      _ -> {:error, :invalid_emoji_attributes}
    end
  end

  def create(attrs), do: register(attrs)

  @doc """
  Fetch a single local custom emoji by name/shortcode/alias (e.g. "blobcat", ":blobcat:", ":blobcat@.:").
  Returns `%CustomEmoji{}` or `nil`.
  """
  @spec get_local(String.t()) :: %CustomEmoji{} | nil
  def get_local(name) when is_binary(name) do
    clean = normalize_shortcode(name)

    from(e in CustomEmoji,
      where: is_nil(e.domain) and (e.shortcode == ^clean or ^clean in e.aliases),
      limit: 1
    )
    |> Repo.one()
  end

  def get_local(_), do: nil

  @doc """
  Upsert a remote custom emoji parsed from an activity's `tag` array.
  `tag` is the raw map (`%{"type" => "Emoji", "name" => ":foo:",
  "icon" => %{"url" => ...}}`). Returns `:ok` (idempotent).
  """
  @spec upsert_from_tag(String.t(), map(), String.t()) :: :ok
  def upsert_from_tag(shortcode, %{} = tag, domain)
      when is_binary(shortcode) and is_binary(domain) do
    icon = tag["icon"] || %{}
    url = icon["url"] || tag["url"]

    if is_binary(url) and url != "" do
      static_url =
        case icon do
          %{"summary" => s} when is_binary(s) -> s
          _ -> nil
        end

      now = DateTime.utc_now() |> DateTime.truncate(:second)

      attrs = %{
        shortcode: shortcode,
        domain: domain,
        image_url: url,
        static_url: static_url,
        last_fetched_at: now
      }

      %CustomEmoji{}
      |> CustomEmoji.changeset(attrs)
      |> Repo.insert(
        on_conflict: {:replace, [:image_url, :static_url, :last_fetched_at]},
        conflict_target: [:shortcode, :domain]
      )
    end

    :ok
  end

  def upsert_from_tag(_shortcode, _tag, _domain), do: :ok

  @doc """
  Local custom emoji directory, ordered by category and shortcode.
  Used by `GET /api/v1/custom_emojis` and the reaction/composer picker.
  Supports filtering by `:category`.
  """
  @spec list_local(keyword()) :: [%CustomEmoji{}]
  def list_local(opts \\ []) do
    query =
      from(e in CustomEmoji,
        where: is_nil(e.domain),
        order_by: [asc_nulls_last: e.category, asc: e.shortcode]
      )

    query =
      case Keyword.get(opts, :category) do
        cat when is_binary(cat) and cat != "" ->
          from(e in query, where: e.category == ^cat)

        _ ->
          query
      end

    Repo.all(query)
  end

  @doc """
  List all distinct categories of local custom emojis.
  """
  @spec list_categories() :: [String.t()]
  def list_categories do
    from(e in CustomEmoji,
      where: is_nil(e.domain) and not is_nil(e.category) and e.category != "",
      distinct: true,
      select: e.category,
      order_by: [asc: e.category]
    )
    |> Repo.all()
  end

  @doc """
  Extract all local custom emoji shortcodes used in a text (e.g. ":blobcat:" or ":blobcat@.:").
  Returns a list of Mastodon-shaped emoji maps:
  `[%{"shortcode" => "blobcat", "url" => "...", "static_url" => "...", "visible_in_picker" => false}]`
  """
  @spec extract_from_text(String.t() | nil) :: [map()]
  def extract_from_text(text) when is_binary(text) and text != "" do
    matches =
      Regex.scan(~r/:([a-zA-Z0-9_-]+)(?:@\.)?:/, text)
      |> Enum.map(fn
        [_, sc] -> sc
        _ -> nil
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    if matches == [] do
      []
    else
      from(e in CustomEmoji,
        where: is_nil(e.domain) and e.shortcode in ^matches
      )
      |> Repo.all()
      |> Enum.map(fn e ->
        %{
          "shortcode" => e.shortcode,
          "url" => e.image_url,
          "static_url" => e.static_url || e.image_url,
          "visible_in_picker" => false
        }
      end)
    end
  end

  def extract_from_text(_), do: []

  @doc """
  Bulk-resolve a list of reaction emoji strings to a map of
  `emoji_key => %{url, static_url}`. Unicode glyphs and unknown
  shortcodes are absent from the result map.
  """
  @spec lookup_many([String.t()]) :: %{String.t() => %{url: String.t(), static_url: String.t() | nil}}
  def lookup_many([]), do: %{}

  def lookup_many(emojis) when is_list(emojis) do
    pairs =
      emojis
      |> Enum.map(&{&1, split(&1)})
      |> Enum.reject(fn {_, parsed} -> is_nil(parsed) end)

    if pairs == [] do
      %{}
    else
      shortcodes = pairs |> Enum.map(fn {_, {sc, _}} -> sc end) |> Enum.uniq()

      rows =
        from(e in CustomEmoji,
          where: e.shortcode in ^shortcodes,
          select: {e.shortcode, e.domain, e.image_url, e.static_url}
        )
        |> Repo.all()

      by_key =
        Map.new(rows, fn {sc, d, url, static_url} ->
          {{sc, d}, %{url: url, static_url: static_url}}
        end)

      pairs
      |> Enum.map(fn {emoji_key, {sc, d}} ->
        {emoji_key, Map.get(by_key, {sc, d})}
      end)
      |> Enum.reject(fn {_, v} -> is_nil(v) end)
      |> Map.new()
    end
  end

  @doc """
  Import custom emojis from a remote Misskey instance.
  `host_or_url` can be "misskey.io" or "https://misskey.io" or "https://misskey.io/api/emojis".
  """
  @spec import_from_misskey(String.t(), keyword()) ::
          {:ok, %{imported: integer(), total: integer()}} | {:error, term()}
  def import_from_misskey(host_or_url, opts \\ []) when is_binary(host_or_url) do
    endpoint =
      cond do
        String.contains?(host_or_url, "/api/emojis") ->
          host_or_url

        String.starts_with?(host_or_url, "http://") or String.starts_with?(host_or_url, "https://") ->
          String.trim_trailing(host_or_url, "/") <> "/api/emojis"

        true ->
          "https://#{host_or_url}/api/emojis"
      end

    headers = [{"content-type", "application/json"}, {"user-agent", "sukhi-fedi/1.0"}]

    req_opts = [
      headers: headers,
      receive_timeout: 30_000,
      json: %{}
    ]

    req_opts =
      if Process.whereis(SukhiFedi.Finch) do
        Keyword.put(req_opts, :finch, SukhiFedi.Finch)
      else
        req_opts
      end

    case Req.post(endpoint, req_opts) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        import_from_json(body, opts)

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Import custom emojis from JSON (Misskey `/api/emojis`, Misskey export `emojis.json`/`meta.json`, or array).
  """
  @spec import_from_json(String.t() | map() | list(), keyword()) ::
          {:ok, %{imported: integer(), total: integer()}} | {:error, term()}
  def import_from_json(json_or_data, opts \\ [])

  def import_from_json(json, opts) when is_binary(json) do
    case JSON.decode(json) do
      {:ok, data} -> import_from_json(data, opts)
      {:error, reason} -> {:error, {:invalid_json, reason}}
    end
  end

  def import_from_json(%{"emojis" => list}, opts) when is_list(list) do
    import_emoji_list(list, opts)
  end

  def import_from_json(list, opts) when is_list(list) do
    import_emoji_list(list, opts)
  end

  def import_from_json(_other, _opts), do: {:error, :unrecognized_format}

  @doc """
  Import custom emojis from a Misskey emoji package zip file.
  Accepts file path or raw binary.
  """
  @spec import_from_zip(String.t() | binary(), keyword()) ::
          {:ok, %{imported: integer(), total: integer()}} | {:error, term()}
  def import_from_zip(zip_path_or_binary, opts \\ [])

  def import_from_zip(path, opts) when is_binary(path) and byte_size(path) < 4096 do
    if File.exists?(path) do
      case File.read(path) do
        {:ok, binary} -> do_import_from_zip_binary(binary, opts)
        {:error, reason} -> {:error, reason}
      end
    else
      do_import_from_zip_binary(path, opts)
    end
  end

  def import_from_zip(binary, opts) when is_binary(binary) do
    do_import_from_zip_binary(binary, opts)
  end

  defp do_import_from_zip_binary(binary, opts) do
    case :zip.unzip(binary, [:memory]) do
      {:ok, file_list} ->
        meta_entry =
          Enum.find(file_list, fn {filename, _content} ->
            base = filename |> to_string() |> Path.basename()
            base in ["meta.json", "emojis.json", "manifest.json"]
          end)

        case meta_entry do
          {_fname, meta_json_bytes} ->
            case JSON.decode(meta_json_bytes) do
              {:ok, data} ->
                files_map =
                  Map.new(file_list, fn {fname, content} ->
                    {fname |> to_string() |> Path.basename(), content}
                  end)

                import_emoji_list_with_files(data, files_map, opts)

              {:error, reason} ->
                {:error, {:invalid_meta_json, reason}}
            end

          nil ->
            {:error, :missing_manifest_in_zip}
        end

      {:error, reason} ->
        {:error, {:unzip_failed, reason}}
    end
  end

  defp import_emoji_list(list, opts) when is_list(list) do
    override_category = Keyword.get(opts, :category)
    prefix = Keyword.get(opts, :prefix, "")

    results =
      Enum.map(list, fn item ->
        emoji_attrs = extract_emoji_attrs(item, override_category, prefix)
        register(emoji_attrs)
      end)

    imported = Enum.count(results, fn {:ok, _} -> true; _ -> false end)
    {:ok, %{imported: imported, total: length(list)}}
  end

  defp import_emoji_list_with_files(data, files_map, opts) do
    list =
      case data do
        %{"emojis" => l} when is_list(l) -> l
        l when is_list(l) -> l
        _ -> []
      end

    override_category = Keyword.get(opts, :category)
    prefix = Keyword.get(opts, :prefix, "")

    results =
      Enum.map(list, fn item ->
        attrs = extract_emoji_attrs(item, override_category, prefix)
        file_name = Map.get(item, "fileName") || Map.get(item, :fileName)

        attrs =
          case file_name && Map.get(files_map, file_name) do
            bytes when is_binary(bytes) and byte_size(bytes) > 0 ->
              mime = mime_for_filename(file_name)
              b64 = Base.encode64(bytes)
              data_url = "data:#{mime};base64,#{b64}"
              Map.put_new(attrs, :image_url, data_url)

            _ ->
              attrs
          end

        register(attrs)
      end)

    imported = Enum.count(results, fn {:ok, _} -> true; _ -> false end)
    {:ok, %{imported: imported, total: length(list)}}
  end

  defp extract_emoji_attrs(item, override_category, prefix) when is_map(item) do
    nested = Map.get(item, "emoji") || Map.get(item, :emoji) || %{}

    name =
      Map.get(nested, "name") ||
      Map.get(nested, :name) ||
      Map.get(item, "name") ||
      Map.get(item, :name) ||
      Map.get(item, "shortcode") ||
      Map.get(item, :shortcode)

    name = if prefix != "" && name, do: "#{prefix}_#{name}", else: name

    url =
      Map.get(nested, "url") ||
      Map.get(nested, :url) ||
      Map.get(item, "url") ||
      Map.get(item, :url) ||
      Map.get(item, "downloadUrl") ||
      Map.get(item, :downloadUrl) ||
      Map.get(item, "originUrl") ||
      Map.get(item, :originUrl)

    category =
      override_category ||
      Map.get(nested, "category") ||
      Map.get(nested, :category) ||
      Map.get(item, "category") ||
      Map.get(item, :category)

    aliases =
      Map.get(nested, "aliases") ||
      Map.get(nested, :aliases) ||
      Map.get(item, "aliases") ||
      Map.get(item, :aliases) ||
      []

    %{
      shortcode: name,
      image_url: url,
      category: category,
      aliases: aliases,
      visible_in_picker: true
    }
  end

  defp extract_emoji_attrs(_item, _override_category, _prefix), do: %{}

  defp normalize_shortcode(nil), do: ""

  defp normalize_shortcode(name) when is_binary(name) do
    name
    |> String.trim()
    |> String.trim(":")
    |> String.replace_suffix("@.", "")
  end

  defp normalize_shortcode(_), do: ""

  defp mime_for_filename(fname) when is_binary(fname) do
    case fname |> Path.extname() |> String.downcase() do
      ".png" -> "image/png"
      ".jpg" -> "image/jpeg"
      ".jpeg" -> "image/jpeg"
      ".gif" -> "image/gif"
      ".webp" -> "image/webp"
      ".svg" -> "image/svg+xml"
      ".apng" -> "image/apng"
      _ -> "image/png"
    end
  end

  defp mime_for_filename(_), do: "image/png"
end
