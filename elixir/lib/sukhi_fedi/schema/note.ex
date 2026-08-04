# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Schema.Note do
  use Ecto.Schema
  import Ecto.Changeset

  schema "notes" do
    field(:content, :string)
    # What the author typed, rendered. Set once at write time for local
    # notes (Markdown → HTML); NULL for remote notes, whose `content` is
    # already the HTML their server sent, and for local notes written
    # before the column existed. Read it through `html/1`, never straight
    # — that fallback is what keeps both of those cases working.
    field(:content_html, :string)
    # An Article's human title (AP `name`); NULL for a plain Note. Kept
    # structured alongside the `<h2>` we also fold into `content`, so the
    # client can detect an article and route it to its reader page.
    field(:title, :string)
    field(:visibility, :string, default: "public")
    field(:ap_id, :string)
    # Locality: NULL = local (authored here), a host = remote. Derived from
    # `ap_id` at write time (see changeset/2); reads use this instead of
    # `is_nil(ap_id)`, which used to double as the local flag.
    field(:domain, :string)
    field(:cw, :string)
    field(:sensitive, :boolean, default: false)
    field(:in_reply_to_ap_id, :string)
    field(:conversation_ap_id, :string)
    field(:quote_of_ap_id, :string)
    # FEP-044f: the `QuoteAuthorization` stamp the quoted post's author
    # granted us, echoed on our outbound note so third parties verify the
    # quote. NULL until (and unless) their `Accept` arrives.
    field(:quote_authorization_ap_id, :string)
    field(:mfm, :string)
    field(:emojis, {:array, :map}, default: [])

    # Virtual, populated by `Notes.with_refs/1` for the Mastodon view:
    # the reply parent resolved to a local row, and the quoted note (with
    # its account preloaded) for a nested-Status `quote` render.
    field(:in_reply_to_id, :integer, virtual: true)
    field(:in_reply_to_account_id, :integer, virtual: true)
    field(:quoted_note, :map, virtual: true)
    # Virtual, populated by `Notes.with_refs/2` when the note owns a poll:
    # the `Polls.get_with_results/2` map, ready for `MastodonPoll.render/1`.
    field(:poll_view, :map, virtual: true)

    belongs_to(:account, SukhiFedi.Schema.Account)
    many_to_many(:media, SukhiFedi.Schema.Media, join_through: "note_media")
    many_to_many(:tags, SukhiFedi.Schema.Tag, join_through: "note_tags")
    has_one(:poll, SukhiFedi.Schema.Poll)
    has_many(:reactions, SukhiFedi.Schema.Reaction)

    timestamps(type: :utc_datetime, inserted_at: :created_at, updated_at: false)
  end

  def changeset(note, attrs) do
    note
    |> cast(attrs, [
      :content,
      :title,
      :visibility,
      :account_id,
      :cw,
      :sensitive,
      :ap_id,
      :in_reply_to_ap_id,
      :conversation_ap_id,
      :quote_of_ap_id,
      :quote_authorization_ap_id,
      :mfm,
      :emojis
    ])
    # Render before escaping — Markdown needs the source as typed, and
    # `escape/1` would turn every `<` into `&lt;` for Earmark to escape
    # a second time.
    |> put_content_html()
    |> sanitize_or_escape_content()
    |> put_domain()
    |> validate_required([:content, :account_id])
    # Cap content length (the only schema field that lacked one): bounds
    # unbounded storage + tag-row amplification from a multi-MB local post
    # or federated note. Oversized federated inserts simply fail the
    # changeset and are dropped. The ceiling is generous enough to hold a
    # hackers.pub `Article` (long-form HTML, title folded in) — a 5 000-char
    # cap silently dropped those — while still bounding multi-MB abuse.
    |> validate_length(:content, max: 100_000)
    |> validate_inclusion(:visibility, ["public", "followers", "direct"])
  end

  # Local notes arrive as plaintext (Mastodon's `status`); remote notes arrive
  # as HTML (AP `content`). Escaping plaintext keeps `x<y` / `List<String>`
  # intact, while the tag-dropping sanitizer would silently delete them — and
  # there is no `source` column to recover from. Remote HTML still gets the
  # allow-list sanitiser. We key off the *effective* ap_id host (via
  # `local_ap_id?/1`) so this is correct on both insert and a remote Update
  # (where ap_id is unchanged and `get_change/2` would read nil).
  defp sanitize_or_escape_content(changeset) do
    transform =
      if local_ap_id?(changeset),
        do: &SukhiFedi.HTML.escape/1,
        else: &SukhiFedi.HTML.sanitize/1

    update_change(changeset, :content, transform)
  end

  # Render the local author's Markdown, once, at write time. Remote notes
  # are left alone: their `content` is their own HTML, and running Markdown
  # over someone else's markup would change their words. Keyed off the same
  # `local_ap_id?/1` as the escaping above, so the two never disagree about
  # whose text this is.
  defp put_content_html(changeset) do
    case get_change(changeset, :content) do
      content when is_binary(content) ->
        if local_ap_id?(changeset),
          do: put_change(changeset, :content_html, SukhiFedi.Markdown.to_html(content)),
          else: changeset

      _ ->
        changeset
    end
  end

  @doc """
  The HTML to show a reader (or send to another server).

  Falls back to `content` when there is no rendered form: a remote note
  (already HTML) or a local note written before the column existed
  (plaintext, served the way it always was). Takes a plain map too — notes
  cross the node boundary as maps.
  """
  @spec html(map()) :: String.t()
  def html(note) do
    case Map.get(note, :content_html) do
      html when is_binary(html) and html != "" -> html
      _ -> Map.get(note, :content) || ""
    end
  end

  # Locality follows the ap_id host. A note created here inserts with no
  # ap_id (it's stamped just after, by id), so domain is NULL = local; a
  # mirrored note carries a remote ap_id, so domain is its host. An ap_id
  # on our own domain (a local note's stamped URL) is local too → NULL.
  defp put_domain(changeset) do
    case get_change(changeset, :ap_id) do
      nil ->
        changeset

      ap_id ->
        host = ap_id |> URI.parse() |> Map.get(:host)
        put_change(changeset, :domain, if(our_host?(host), do: nil, else: host))
    end
  end

  # True when the note is locally authored: no ap_id yet (fresh local insert,
  # stamped post-insert) or an ap_id under our own domain.
  defp local_ap_id?(changeset) do
    case get_field(changeset, :ap_id) do
      nil -> true
      ap_id -> ap_id |> URI.parse() |> Map.get(:host) |> our_host?()
    end
  end

  # Config domain may carry a port (localhost:4000); a URI host never does —
  # compare host-to-host. A nil host (relative/blank ap_id) counts as ours.
  defp our_host?(host) do
    our = SukhiFedi.Config.domain!() |> String.split(":") |> hd()
    is_nil(host) or host == our
  end
end
