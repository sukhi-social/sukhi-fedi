# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.CustomEmojis do
  @moduledoc """
  Custom emoji directory and management.

  Supports:
  - Local emoji registration and lookup (`register/1`, `get_local/1`, `list_local/1`).
  - Admin batch import in one transaction, audited (`import_many/3`). It
    takes already-normalised attribute maps; reading Misskey instances,
    export JSON and emoji packs is the job of `scripts/emoji_import.jl`,
    which posts to `POST /api/admin/emojis`.
  - Remote emoji caching from inbound AP activities (`upsert_from_tag/3`).
  - Extracting custom emojis used in text content (`extract_from_text/1`).
  - Reaction namespacing and resolution (`namespaced/2`, `split/1`, `lookup_many/1`).

  ## Caching

  Reads are served from `Cache.Ets` (`:custom_emojis`); this module is the
  one place that fills it and the one place that empties it. The local
  directory is cached whole (one list plus a shortcode/alias index, so
  `list_local/1`, `get_local/1` and `extract_from_text/1` never touch the
  DB when warm); remote and local reaction lookups are cached per key.
  Every write path ends in `invalidate/1`, after its transaction commits.
  The TTLs are only a backstop for writers in another VM (mix tasks).
  """

  import Ecto.Query

  alias Ecto.Multi
  alias SukhiFedi.Cache.Ets, as: Cache
  alias SukhiFedi.{Outbox, Repo}
  alias SukhiFedi.Schema.{AdminAudit, CustomEmoji}

  @cache :custom_emojis
  @local_key :local
  @local_ttl 300
  @key_ttl 300

  # One request, one transaction: bound it so a runaway client cannot hold a
  # long write open. A pack of ~1000 emoji fits with room to spare.
  @max_import 2_000

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
    with {:ok, changes} <- prepare(attrs),
         {:ok, emoji} <- upsert(changes) do
      invalidate(emoji)
      {:ok, emoji}
    end
  end

  # The one place an emoji's attributes are read and normalised. Pure: no
  # DB, so a batch can be checked in full before anything is written.
  @spec prepare(map()) :: {:ok, map()} | {:error, :invalid_emoji_attributes}
  defp prepare(attrs) do
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

      {:ok,
       %{
         shortcode: sc,
         domain: domain,
         image_url: url,
         static_url: static_url,
         category: category,
         aliases: aliases,
         visible_in_picker: visible_in_picker,
         last_fetched_at: now
       }}
    else
      _ -> {:error, :invalid_emoji_attributes}
    end
  end

  @replaced [:image_url, :static_url, :category, :aliases, :visible_in_picker, :last_fetched_at]

  # Insert-or-replace by (shortcode, domain).
  #
  # A remote emoji (domain set) conflicts on the (shortcode, domain) index.
  # A LOCAL one (domain NULL) never does there -- Postgres treats NULLs as
  # distinct -- so it has its own partial unique index on shortcode WHERE
  # domain IS NULL (custom_emojis_local_shortcode_index), and conflicts on
  # that instead.
  defp upsert(%{domain: nil} = changes) do
    %CustomEmoji{}
    |> CustomEmoji.changeset(changes)
    |> Repo.insert(
      on_conflict: {:replace, @replaced},
      conflict_target: {:unsafe_fragment, "(shortcode) WHERE domain IS NULL"},
      returning: true
    )
  end

  defp upsert(changes) do
    %CustomEmoji{}
    |> CustomEmoji.changeset(changes)
    |> Repo.insert(
      on_conflict: {:replace, @replaced},
      conflict_target: [:shortcode, :domain],
      returning: true
    )
  end

  @doc """
  Register many emoji for an admin, all or nothing, with an audit trail.

  `items` is a list of attribute maps (what `register/1` takes). Every item
  is checked first; the ones that pass are written together in one
  transaction with an `admin_audits` row and an
  `sns.outbox.admin.emoji_imported` event, so a failed write leaves nothing
  behind. Items that do not pass are reported and skipped — they do not stop
  the others.

  Options: `dry_run: true` checks and reports without writing. Always local:
  any `domain` in an item is ignored.

  Returns `{:ok, %{imported, failed, dry_run, results}}`, `results` in input
  order, each `%{index, shortcode, status: :ok | :error, error}`.
  """
  @spec import_many([term()], integer(), keyword()) ::
          {:ok, map()} | {:error, :too_many | :empty | term()}
  def import_many(items, admin_id, opts \\ [])

  def import_many(items, _admin_id, _opts) when is_list(items) and length(items) > @max_import,
    do: {:error, :too_many}

  def import_many([], _admin_id, _opts), do: {:error, :empty}

  def import_many(items, admin_id, opts) when is_list(items) and is_integer(admin_id) do
    dry_run? = Keyword.get(opts, :dry_run, false)
    checked = items |> Enum.with_index() |> Enum.map(&check_item/1)
    valid = for {:ok, index, changes} <- checked, do: {index, changes}

    if dry_run? or valid == [] do
      {:ok, summary(checked, dry_run?)}
    else
      case write_many(valid, admin_id) do
        {:ok, _} ->
          invalidate(:local)
          {:ok, summary(checked, false)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # An admin import writes LOCAL emoji only: a `domain` in the input is
  # dropped, not honoured, so this door cannot plant a remote-looking row.
  defp check_item({attrs, index}) when is_map(attrs) do
    with {:ok, changes} <- prepare(Map.drop(attrs, [:domain, "domain"])),
         %{valid?: true} <- CustomEmoji.changeset(%CustomEmoji{}, changes) do
      {:ok, index, changes}
    else
      {:error, reason} -> {:error, index, attrs, reason}
      %Ecto.Changeset{} -> {:error, index, attrs, :invalid_emoji_attributes}
    end
  end

  defp check_item({other, index}), do: {:error, index, other, :not_an_object}

  defp write_many(valid, admin_id) do
    multi =
      Enum.reduce(valid, Multi.new(), fn {index, changes}, multi ->
        Multi.run(multi, {:emoji, index}, fn _repo, _so_far -> upsert(changes) end)
      end)

    multi
    |> Multi.insert(
      :audit,
      AdminAudit.changeset(%{
        action: "emoji_imported",
        admin_account_id: admin_id,
        metadata: %{count: length(valid)}
      })
    )
    |> Outbox.enqueue_multi(
      :outbox_event,
      "sns.outbox.admin.emoji_imported",
      "custom_emoji",
      fn _ -> admin_id end,
      fn _ -> %{count: length(valid), by_id: admin_id} end
    )
    |> Repo.transaction()
    |> case do
      {:ok, changes} -> {:ok, changes}
      {:error, _step, reason, _so_far} -> {:error, reason}
    end
  end

  defp summary(checked, dry_run?) do
    results =
      Enum.map(checked, fn
        {:ok, index, changes} ->
          %{index: index, shortcode: changes.shortcode, status: :ok, error: nil}

        {:error, index, attrs, reason} ->
          %{index: index, shortcode: shortcode_hint(attrs), status: :error, error: reason}
      end)

    ok = Enum.count(results, &(&1.status == :ok))

    %{
      imported: if(dry_run?, do: 0, else: ok),
      failed: length(results) - ok,
      dry_run: dry_run?,
      results: results
    }
  end

  defp shortcode_hint(%{} = attrs) do
    case Map.get(attrs, "shortcode") || Map.get(attrs, :shortcode) || Map.get(attrs, "name") ||
           Map.get(attrs, :name) do
      sc when is_binary(sc) -> sc
      _ -> nil
    end
  end

  defp shortcode_hint(_), do: nil

  def create(attrs), do: register(attrs)

  @doc """
  Fetch a single local custom emoji by name/shortcode/alias (e.g. "blobcat", ":blobcat:", ":blobcat@.:").
  Returns `%CustomEmoji{}` or `nil`.
  """
  @spec get_local(String.t()) :: %CustomEmoji{} | nil
  def get_local(name) when is_binary(name) do
    {_list, index} = local_directory()
    Map.get(index, normalize_shortcode(name))
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
      |> case do
        {:ok, _} -> invalidate({shortcode, domain})
        _ -> :ok
      end
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
    {list, _index} = local_directory()

    case Keyword.get(opts, :category) do
      cat when is_binary(cat) and cat != "" -> Enum.filter(list, &(&1.category == cat))
      _ -> list
    end
  end

  @doc """
  List all distinct categories of local custom emojis.
  """
  @spec list_categories() :: [String.t()]
  def list_categories do
    {list, _index} = local_directory()

    list
    |> Enum.map(& &1.category)
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
    |> Enum.sort()
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
      {_list, index} = local_directory()

      # Shortcodes only, not aliases: an alias is a search handle for the
      # picker, not something a post can spell.
      matches
      |> Enum.flat_map(fn sc ->
        case Map.get(index, sc) do
          %CustomEmoji{shortcode: ^sc} = e -> [e]
          _ -> []
        end
      end)
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
      keys = pairs |> Enum.map(fn {_, parsed} -> parsed end) |> Enum.uniq()
      by_key = resolve_keys(keys)

      pairs
      |> Enum.map(fn {emoji_key, parsed} -> {emoji_key, Map.get(by_key, parsed)} end)
      |> Enum.reject(fn {_, v} -> is_nil(v) end)
      |> Map.new()
    end
  end

  @doc """
  Empty the emoji cache. For tests, whose rolled-back sandbox rows must not
  outlive them, and for a maintenance script that edits the table by hand.
  """
  @spec clear_cache() :: :ok
  def clear_cache do
    invalidate(:local)
    :ok
  end

  ## ── cache ────────────────────────────────────────────────────────────

  # The whole local directory, ordered, plus a lookup index. Shortcodes are
  # inserted after aliases so a shortcode beats an alias spelled the same.
  defp local_directory do
    cached(@local_key, @local_ttl, fn ->
      list =
        Repo.all(
          from(e in CustomEmoji,
            where: is_nil(e.domain),
            order_by: [asc_nulls_last: e.category, asc: e.shortcode]
          )
        )

      aliased = for e <- list, a <- e.aliases || [], do: {a, e}
      named = for e <- list, do: {e.shortcode, e}
      {list, Map.new(aliased ++ named)}
    end)
  end

  # `{shortcode, domain}` => `%{url, static_url}`, one DB trip for the misses.
  defp resolve_keys(keys) do
    {hits, misses} =
      Enum.reduce(keys, {%{}, []}, fn key, {hits, misses} ->
        case Cache.get(@cache, {:key, key}) do
          {:ok, {:found, v}} -> {Map.put(hits, key, v), misses}
          _ -> {hits, [key | misses]}
        end
      end)

    if misses == [] do
      hits
    else
      shortcodes = misses |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

      fetched =
        from(e in CustomEmoji,
          where: e.shortcode in ^shortcodes,
          select: {e.shortcode, e.domain, e.image_url, e.static_url}
        )
        |> Repo.all()
        |> Map.new(fn {sc, d, url, static_url} ->
          {{sc, d}, %{url: url, static_url: static_url}}
        end)

      # Only hits are kept: an unknown shortcode may be registered a moment
      # later, and a remote one is upserted on the very reaction that names it.
      for {key, v} <- fetched, key in misses, do: put(@cache, {:key, key}, {:found, v}, @key_ttl)

      Map.merge(hits, Map.take(fetched, misses))
    end
  end

  defp cached(key, ttl, fun) do
    case Cache.get(@cache, key) do
      {:ok, value} ->
        value

      :miss ->
        value = fun.()
        put(@cache, key, value, ttl)
        value
    end
  rescue
    # No table (unit tests run with --no-start): behave as an empty cache.
    ArgumentError -> fun.()
  end

  defp put(table, key, value, ttl) do
    Cache.put(table, key, value, ttl)
  rescue
    ArgumentError -> true
  end

  # The single point where a write empties the cache. A local row also
  # shapes the directory; any row shapes the per-key entries.
  defp invalidate(:local) do
    drop(@local_key)
    clear_keys()
  end

  defp invalidate(%CustomEmoji{domain: nil}), do: invalidate(:local)
  defp invalidate(%CustomEmoji{shortcode: sc, domain: d}), do: invalidate({sc, d})
  defp invalidate({_sc, nil} = key), do: invalidate_key(key) && invalidate(:local)
  defp invalidate({_sc, _domain} = key), do: invalidate_key(key)

  defp invalidate_key(key) do
    drop({:key, key})
    true
  end

  defp clear_keys do
    :ets.match_delete(@cache, {{:key, :_}, :_, :_})
  rescue
    ArgumentError -> true
  end

  defp drop(key) do
    Cache.delete(@cache, key)
  rescue
    ArgumentError -> true
  end

  defp normalize_shortcode(nil), do: ""

  defp normalize_shortcode(name) when is_binary(name) do
    name
    |> String.trim()
    |> String.trim(":")
    |> String.replace_suffix("@.", "")
  end

  defp normalize_shortcode(_), do: ""
end
