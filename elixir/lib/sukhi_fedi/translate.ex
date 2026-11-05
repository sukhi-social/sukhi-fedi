# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Translate do
  @moduledoc """
  Translating a post for the person reading it. The one window: `status/3`.

  What this is for (docs/TRANSLATION.md): a post is a person's voice, and a
  translation is a hand held out to hear it — never a film laid over it. So a
  translation is **for one reader**: it is made when they ask, shown beside the
  original, kept for a few minutes in memory for whoever asks next, and never
  stored on the post, federated, or shown to anyone else.

  Everything that must be true is checked here, once, before an engine is
  called, and the engine adapters trust it (CODE_STYLE §0):

    * **who may see the post** — `Notes.get_note/2`, the single visibility rule;
      a direct message is not translated at all;
    * **where the text may go** — the engine is the one the person chose, and
      never changes silently. `"deepl"` sends the post to a third party, so it is
      used only for posts anyone may read (public, unlisted); a followers-only post
      goes to the server's own translator instead, and the answer's `provider`
      says so. A person who chose `"deepl"` always has a key (the changeset
      requires it);
    * **how much** — `Translate.Gate` (per person, and in flight on the hosted
      translator) and a length cap;
    * **what comes back** — passed through `HTML.sanitize/1`, because what an
      engine returns is text from outside, however friendly.

  The answer is Mastodon's `Translation` entity (`content`, `spoiler_text`,
  `detected_source_language`, `provider`, plus the empty `poll` and
  `media_attachments`), so any Mastodon client can read it.
  """

  alias SukhiFedi.{HotCache, HTML, Notes, Repo}
  alias SukhiFedi.Schema.Account
  alias SukhiFedi.Translate.{DeepL, Gate, Key, LibreTranslate}

  @targets ~w(ja ko en)
  @max_chars 3_000

  @type reason ::
          :not_found
          | :not_translatable
          | :disabled
          | :unsupported_language
          | :too_long
          | :no_key
          | :key_rejected
          | :quota
          | :engine_rejected
          | :engine_unavailable
          | {:busy, pos_integer()}

  @doc "Whether this server has a translator of its own."
  @spec enabled?() :: boolean()
  def enabled?, do: LibreTranslate.configured?()

  @doc "The languages a translation can be made into."
  @spec targets() :: [String.t()]
  def targets, do: @targets

  @spec status(Account.t() | map(), integer() | binary(), String.t() | nil) ::
          {:ok, map()} | {:error, reason()}
  def status(%{id: viewer_id}, note_id, target) when is_integer(viewer_id) do
    with {:ok, target} <- target(target),
         {:ok, note} <- Notes.get_note(note_id, viewer_id),
         {:ok, engine} <- engine(Repo.get(Account, viewer_id), note),
         {:ok, texts} <- texts(note) do
      run(viewer_id, engine, note, texts, target)
    end
  end

  # ── the checks ────────────────────────────────────────────────────────────

  defp target(nil), do: {:error, :unsupported_language}
  defp target(t) when is_binary(t), do: if(t in @targets, do: {:ok, t}, else: {:error, :unsupported_language})

  # A direct message was written for named people; it is not sent to any engine.
  defp engine(_account, %{visibility: "direct"}), do: {:error, :not_translatable}

  defp engine(%Account{translate_engine: "deepl", translate_deepl_key: sealed, id: id}, %{visibility: v}) do
    cond do
      v not in SukhiFedi.Visibility.public_only() -> hosted()
      true -> deepl(Key.open(sealed, id))
    end
  end

  defp engine(%Account{}, _note), do: hosted()
  defp engine(nil, _note), do: {:error, :not_found}

  defp hosted, do: if(enabled?(), do: {:ok, :libre}, else: {:error, :disabled})

  defp deepl({:ok, key}), do: {:ok, {:deepl, key}}
  defp deepl(:error), do: {:error, :no_key}

  # [content] or [content, spoiler]. The spoiler is plain text; it is escaped on the
  # way out and stripped on the way back, so it stays plain text.
  defp texts(note) do
    content = body_html(note)

    if String.length(strip_tags(content)) > @max_chars do
      {:error, :too_long}
    else
      case note.cw do
        s when is_binary(s) and s != "" -> {:ok, [content, HTML.escape(s)]}
        _ -> {:ok, [content]}
      end
    end
  end

  # What the reader sees as the post's text: the rendered form when there is one,
  # the stored text behind it, as plain text wrapped in a paragraph (the same
  # choice the status view makes, so what is translated is what is on screen).
  defp body_html(note) do
    raw = note.content_html || note.content || ""
    if String.starts_with?(raw, "<"), do: raw, else: "<p>#{HTML.escape(raw)}</p>"
  end

  # ── the call ──────────────────────────────────────────────────────────────

  defp run(viewer_id, engine, note, texts, target) do
    {kind, scope} = scope(engine, viewer_id)
    digest = :crypto.hash(:sha256, texts) |> Base.encode16(case: :lower)

    # Cached per engine (and per person for their own key), so a post that many
    # people ask for is translated once, and one person's quota is never spent
    # by another. Only successes are kept.
    HotCache.fetch_ok({:translate, scope, digest, target}, HotCache.ttl(:translate), fn ->
      Gate.run(viewer_id, kind, fn -> call(engine, texts, target) end)
    end)
    |> render(kind, note)
  end

  defp scope(:libre, _viewer_id), do: {:libre, :libre}
  defp scope({:deepl, _key}, viewer_id), do: {:deepl, {:deepl, viewer_id}}

  defp call(:libre, texts, target), do: LibreTranslate.translate(texts, nil, target)
  defp call({:deepl, key}, texts, target), do: DeepL.translate(texts, nil, target, key)

  defp render({:ok, %{texts: [content | rest], detected: detected}}, kind, _note) do
    {:ok,
     %{
       content: HTML.sanitize(content),
       spoiler_text: spoiler(rest),
       detected_source_language: detected,
       provider: provider(kind),
       poll: nil,
       media_attachments: []
     }}
  end

  defp render({:error, _} = error, _kind, _note), do: error

  defp spoiler([text | _]), do: text |> strip_tags() |> HTML.unescape()
  defp spoiler([]), do: ""

  defp provider(:libre), do: "LibreTranslate"
  defp provider(:deepl), do: "DeepL"

  defp strip_tags(html), do: Regex.replace(~r/<[^>]*>/, html, "")
end
