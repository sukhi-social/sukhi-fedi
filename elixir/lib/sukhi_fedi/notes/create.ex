# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Notes.Create do
  @moduledoc """
  The write path: creating notes (public/unlisted/followers statuses,
  DMs, polls, media attachment, reply/quote resolution) and deleting
  them. Every write enqueues its outbox event in the same transaction —
  "DB commit = event durable".
  """

  import Ecto.Query

  alias Ecto.Multi
  alias SukhiFedi.Notes.{Ids, Read}
  alias SukhiFedi.{Notifications, Outbox, Repo}
  alias SukhiFedi.Schema.{ConversationParticipant, Media, Note}
  alias SukhiFedi.Schema.{Account, NoteCleanupLedger}

  require Logger

  @doc """
  Create a note and enqueue the `sns.outbox.note.created` event atomically.

  A single Ecto.Multi transaction does both the `notes` insert and the
  `outbox` row. Combined with `Outbox.Relay` this delivers
  "DB commit = event durable" semantics.
  """
  def create_note(attrs) do
    attrs = maybe_extract_emojis(attrs)

    Multi.new()
    |> Multi.insert(:note, Note.changeset(%Note{}, attrs))
    |> stamp_local_ap_id()
    |> Outbox.enqueue_multi(
      :outbox_event,
      "sns.outbox.note.created",
      "note",
      & &1.note.id,
      fn %{note: note} ->
        %{
          note_id: note.id,
          account_id: note.account_id,
          visibility: note.visibility,
          content: Note.html(note),
          emojis: note.emojis || []
        }
      end
    )
    |> Repo.transaction()
    |> case do
      {:ok, %{note: note}} -> {:ok, Repo.preload(note, [:account, :media])}
      {:error, :note, %Ecto.Changeset{} = cs, _} -> {:error, {:validation, SukhiFedi.Changeset.errors(cs)}}
      {:error, _step, reason, _} -> {:error, reason}
    end
  end

  @doc """
  Create a status from Mastodon-shaped input.

  Translates:
    * `spoiler_text` → `cw`
    * `media_ids[]`  → resolves Media rows owned by the same account,
      attaches via `note_media` and stamps `attached_at` in the same
      `Ecto.Multi`
    * `in_reply_to_id` → either a local Note id or an http(s) URI; in
      the URI case `Federation.NoteFetcher` mirrors the remote note
      first so we can store its `ap_id`
    * `quote_id` / `quoted_status_id` → `quote_of_ap_id` (same id/URI
      resolution as `in_reply_to_id`) — federates as a 引用ノート
    * `poll[options][]` (or JSON `poll: %{…}`) → inserts a Poll +
      PollOptions in the same transaction

  `visibility: "direct"` routes to a DM: `@user` / `@user@host`
  mentions are pulled from the text, resolved to recipient actors
  (WebFinger + shadow upsert on a remote miss), and the note federates
  via `sns.outbox.dm.created`. Returns `{:error, :dm_no_recipients}`
  when no mention resolves.
  """
  @spec create_status(Account.t() | integer(), map()) ::
          {:ok, Note.t()} | {:error, atom() | {:validation, map()}}
  def create_status(%Account{id: aid}, params), do: create_status(aid, params)

  def create_status(account_id, params) when is_integer(account_id) do
    visibility = normalize_visibility(params[:visibility] || params["visibility"] || "public")

    # deco 発の「連合に出さない」指定。notes.visibility は変えず
    # (公開のまま local API/timeline から普通に読める)、出前だけを
    # 止める ── outbox payload に載せるだけで、notes 側には持たせない。
    local_only? = !!(params[:local_only] || params["local_only"])

    # 長い文章として出すか(AP の `Article`)。notes には持たせない ──
    # `local_only` と同じで、連合の側にだけ効く上乗せ。
    as_article? = !!(params[:as_article] || params["as_article"])

    if visibility == "direct" do
      create_direct_status(account_id, params)
    else
      content = params[:status] || params["status"] || ""

      # 本文の @メンションは、これまで DM でしか実配達先に解決していな
      # かった(公開投稿は文字列のまま、フォロワー以外には届かない)。
      # ここで actor_uri のリストにして outbox へ渡す ── webfinger/actor
      # fetch はここ(書き込みの瞬間)で一度だけ。本人宛のセルフメンション
      # は除く。DM側と違い、公開投稿にとってメンションはあくまで添え物
      # ── 解決に失敗しても投稿そのものは通す(他の fetch 失敗時と同じ、
      # 「落ちたら諦める」の方針)。
      mention_actor_uris =
        try do
          content
          |> resolve_mention_recipients()
          |> Enum.reject(&(&1.account_id == account_id))
          |> Enum.map(& &1.actor_uri)
          |> Enum.uniq()
        rescue
          error ->
            Logger.warning("mention resolution failed, posting without it: #{Exception.message(error)}")
            []
        end

      attrs =
        %{
          account_id: account_id,
          content: content,
          # 題は掲示板（deco）から来る。Mastodon の status には無い欄で、
          # 取り込んだ Article と同じ `notes.title` に入る ── 題つきの
          # 投稿の置き場を二つ作らないため。
          title: params[:title] || params["title"],
          cw: params[:spoiler_text] || params["spoiler_text"] || params[:cw] || params["cw"],
          sensitive: params[:sensitive] || params["sensitive"] || false,
          visibility: visibility
        }
        |> resolve_in_reply_to(params)
        |> resolve_quote(params)
        |> maybe_extract_emojis()

      media_ids = list_media_ids(params)
      media = attachment_descriptors(media_ids, account_id)

      Multi.new()
      |> Multi.insert(:note, Note.changeset(%Note{}, attrs))
      |> stamp_local_ap_id()
      |> attach_media(media_ids, account_id)
      |> Multi.run(:tags, fn _repo, %{note: n} ->
        {:ok, SukhiFedi.Tags.upsert_for_note(n.id, n.content)}
      end)
      |> attach_poll(params)
      |> Outbox.enqueue_multi(
        :outbox_event,
        "sns.outbox.note.created",
        "note",
        & &1.note.id,
        fn %{note: n} ->
          %{
            note_id: n.id,
            account_id: n.account_id,
            visibility: n.visibility,
            # AP `content` is HTML, so the rendered form is what federates.
            content: Note.html(n),
            # The content warning and sensitive flag are set by the author but
            # were never federated — remotes showed our CW'd / NSFW posts
            # unwarned. Carry them through to the outbound builder.
            cw: n.cw,
            sensitive: n.sensitive,
            media: media,
            quote_of_ap_id: n.quote_of_ap_id,
            in_reply_to_ap_id: n.in_reply_to_ap_id,
            emojis: n.emojis || [],
            local_only: local_only?,
            mention_actor_uris: mention_actor_uris,
            # 題と書いた人は、線の上でだけ本文の頭に添える(`Fedi.Builders`)。
            # ここの画面は題も名前ももう出しているので、保存する本文には
            # 入れない ── 同じことを二度書かせない。
            title: n.title,
            as_article: as_article?,
            author_handle: author_handle(n),
            author_uri: author_uri(n)
          }
        end
      )
      |> Repo.transaction()
      |> case do
        {:ok, %{note: note}} ->
          maybe_request_quote(note)
          maybe_enqueue_preview(note)
          notify_local_mentions(note)
          {:ok, Repo.preload(note, [:account, :media]) |> Read.with_refs()}

        {:error, :note, %Ecto.Changeset{} = cs, _} ->
          {:error, {:validation, SukhiFedi.Changeset.errors(cs)}}

        {:error, :media_check, :not_owned, _} ->
          {:error, :media_not_owned}

        {:error, _step, reason, _} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Re-deliver a note to our followers as an `Update(Note)` (FEP-044f).

  Called when a quote authorization lands (`Accept`) or is withdrawn
  (`Reject`) so already-delivered copies refresh the inline quote.
  Best-effort: a missing note is a no-op.
  """
  def enqueue_update(note_id) do
    case Repo.get(Note, note_id) do
      %Note{} = note ->
        note = Repo.preload(note, :media)

        Outbox.enqueue("sns.outbox.note.updated", "note", to_string(note.id), %{
          note_id: note.id,
          account_id: note.account_id,
          content: Note.html(note),
          cw: note.cw,
          sensitive: note.sensitive,
          published: DateTime.to_iso8601(note.created_at),
          media: SukhiFedi.AP.MediaSerialize.descriptors(note.media),
          quote_of_ap_id: note.quote_of_ap_id,
          quote_authorization_ap_id: note.quote_authorization_ap_id,
          in_reply_to_ap_id: note.in_reply_to_ap_id
        })

      _ ->
        :ok
    end
  end

  # FEP-044f: when we quote a *remote* post, ask its author for approval
  # (a `QuoteRequest`) so the quote can render inline — not just as a
  # legacy link — on their server and their followers'. A local quote
  # needs no request. The quoted note was mirrored during `resolve_quote`,
  # so its author's inbox is already on hand.
  defp maybe_request_quote(%Note{quote_of_ap_id: q, id: note_id, account_id: account_id})
       when is_binary(q) do
    if Ids.local_note_id_from_uri(q) do
      :ok
    else
      case quoted_author_inbox(q) do
        nil ->
          :ok

        inbox ->
          Outbox.enqueue("sns.outbox.quote.requested", "note", to_string(note_id), %{
            note_id: note_id,
            account_id: account_id,
            quote_of_ap_id: q,
            target_inbox: inbox
          })
      end
    end
  end

  defp maybe_request_quote(_), do: :ok

  # FEP-8967: if the post carries an external link, fetch a preview card
  # for it in the background. Off in tests; a no-op when there's no link.
  defp maybe_enqueue_preview(%Note{id: id, content: content}) do
    with true <- SukhiFedi.PreviewCards.enabled?(),
         url when is_binary(url) <-
           SukhiFedi.PreviewCards.first_link(content, SukhiFedi.Config.domain!()) do
      %{note_id: id, url: url}
      |> SukhiFedi.PreviewCards.Worker.new()
      |> then(&Oban.insert(SukhiFedi.Oban, &1))
    end

    :ok
  end

  defp maybe_enqueue_preview(_), do: :ok

  defp quoted_author_inbox(quote_ap_id) do
    case Repo.get_by(Note, ap_id: quote_ap_id) do
      %Note{account_id: aid} ->
        case Repo.get(Account, aid) do
          %Account{inbox_url: inbox} when is_binary(inbox) and inbox != "" -> inbox
          %Account{actor_uri: uri} when is_binary(uri) and uri != "" -> uri <> "/inbox"
          _ -> nil
        end

      _ ->
        nil
    end
  end

  # `visibility: "direct"` path of `create_status/2`. Mentions are
  # resolved to recipients, split into local vs remote: local recipients
  # are delivered in-process (a `conversation_participants` row — they
  # read the sender's single note through the conversation), remote ones
  # federate via `sns.outbox.dm.created`. The note carries a
  # `conversation_ap_id` (its own AP id for a new thread, the parent's
  # for a reply) so the federated `context` threads on the other side and
  # the DM shows up in everyone's `/api/v1/conversations`. Hashtags and
  # polls are skipped — a DM is private and point-to-point.
  defp create_direct_status(account_id, params) do
    content = params[:status] || params["status"] || ""

    with {:ok, sender} <- SukhiFedi.Accounts.get_account(account_id),
         recipients when recipients != [] <- resolve_mention_recipients(content) do
      remote_uris = for r <- recipients, not r.local?, do: r.actor_uri

      base_attrs =
        %{
          account_id: account_id,
          content: content,
          cw: params[:spoiler_text] || params["spoiler_text"] || params[:cw] || params["cw"],
          sensitive: params[:sensitive] || params["sensitive"] || false,
          visibility: "direct"
        }
        |> resolve_in_reply_to(params)
        |> maybe_extract_emojis()

      inherited_cid = reply_parent_conversation(params)
      media_ids = list_media_ids(params)

      Multi.new()
      |> Multi.insert(:note, Note.changeset(%Note{}, base_attrs))
      |> attach_media(media_ids, account_id)
      |> Multi.run(:dm, fn repo, %{note: note} ->
        cid = inherited_cid || dm_conversation_ap_id(sender.username, note.id)

        {:ok, note} =
          note
          |> Ecto.Changeset.change(conversation_ap_id: cid, ap_id: Ids.note_ap_id(note.id))
          |> repo.update()

        # Record every participant so the conversation's `accounts` is
        # complete (remote recipients have shadow accounts too). The
        # sender's own row stays read; a local recipient is unread;
        # remote rows just exist for the `accounts` list (their unread
        # flag is never read here).
        #
        # A self-mention (Clips: you're both sender and sole recipient)
        # would otherwise upsert your own row twice in this same
        # transaction — read (as sender), then immediately unread (as a
        # "local recipient" who happens to be you) — since both target
        # the same (cid, account_id) row and `on_conflict` keeps the
        # last write. Every message you post to yourself flipped the
        # conversation back to unread the instant you sent it.
        upsert_participant(repo, cid, account_id, false)

        Enum.each(recipients, fn r ->
          unread = r.local? and r.account_id != account_id
          upsert_participant(repo, cid, r.account_id, unread)
        end)

        {:ok, note}
      end)
      |> maybe_enqueue_dm(remote_uris, attachment_descriptors(media_ids, account_id))
      |> Repo.transaction()
      |> case do
        {:ok, %{dm: note}} ->
          notify_local_mentions(note)
          {:ok, Repo.preload(note, [:account, :media]) |> Read.with_refs()}

        {:error, :note, %Ecto.Changeset{} = cs, _} ->
          {:error, {:validation, SukhiFedi.Changeset.errors(cs)}}

        {:error, :media_check, :not_owned, _} ->
          {:error, :media_not_owned}

        {:error, _step, reason, _} ->
          {:error, reason}
      end
    else
      {:error, :not_found} -> {:error, :account_not_found}
      [] -> {:error, :dm_no_recipients}
    end
  end

  # Only federate when there's a remote recipient. A purely local DM has
  # no inbox to POST to — its delivery is the participant rows above.
  defp maybe_enqueue_dm(multi, [], _media), do: multi

  defp maybe_enqueue_dm(multi, remote_uris, media) do
    Outbox.enqueue_multi(
      multi,
      :outbox_event,
      "sns.outbox.dm.created",
      "note",
      & &1.dm.id,
      fn %{dm: n} ->
        %{
          note_id: n.id,
          account_id: n.account_id,
          content: Note.html(n),
          media: media,
          recipient_actor_uris: remote_uris,
          in_reply_to_ap_id: n.in_reply_to_ap_id,
          conversation_ap_id: n.conversation_ap_id
        }
      end
    )
  end

  defp upsert_participant(repo, conversation_ap_id, account_id, unread) do
    %ConversationParticipant{}
    |> ConversationParticipant.changeset(%{
      conversation_ap_id: conversation_ap_id,
      account_id: account_id,
      unread: unread
    })
    |> repo.insert(
      on_conflict: [set: [unread: unread]],
      conflict_target: [:conversation_ap_id, :account_id]
    )
  end

  # A new DM thread is identified by the root note's own synthesized AP
  # id (local notes don't persist `ap_id`; it's derived on demand, same
  # convention the delivery node and AP controllers use).
  # 線の上の引用ヘッダに添える、書いた人。ローカルの人だけを相手に
  # するので domain は自分のもの ── 取り込んだ note がここを通ることは
  # ない(出前は自分の投稿だけ)。
  defp author_handle(%Note{} = n) do
    case SukhiFedi.Repo.get(Account, n.account_id) do
      %Account{username: u} -> "@#{u}@#{SukhiFedi.Config.domain!()}"
      nil -> nil
    end
  end

  defp author_uri(%Note{} = n) do
    case SukhiFedi.Repo.get(Account, n.account_id) do
      %Account{username: u} -> SukhiFedi.AP.ActorJson.actor_uri(u)
      nil -> nil
    end
  end

  defp dm_conversation_ap_id(username, note_id),
    do: "https://#{SukhiFedi.Config.domain!()}/users/#{username}/notes/#{note_id}"

  # A DM reply inherits the parent's conversation so the whole thread
  # shares one `conversation_ap_id`. Resolved straight from the reply
  # target (a local note id or a remote note's AP URI) rather than via
  # `in_reply_to_ap_id`, which is null for local parents (local notes
  # don't persist an `ap_id`). Falls back to a new thread on a miss.
  defp reply_parent_conversation(params) do
    case params[:in_reply_to_id] || params["in_reply_to_id"] do
      nil -> nil
      id -> parent_note_conversation(id)
    end
  end

  defp parent_note_conversation(id) when is_integer(id),
    do: parent_note_conversation(to_string(id))

  defp parent_note_conversation(id) when is_binary(id) do
    query =
      if String.starts_with?(id, "http") do
        from(n in Note, where: n.ap_id == ^id, select: n.conversation_ap_id)
      else
        case Ids.parse_int(id) do
          nil -> nil
          int -> from(n in Note, where: n.id == ^int, select: n.conversation_ap_id)
        end
      end

    query && Repo.one(query)
  end

  defp parent_note_conversation(_), do: nil

  # Pull `@user` / `@user@host` handles from the note text and resolve
  # each to a recipient. The negative lookbehind keeps email addresses
  # from matching. Unresolvable handles are dropped. Each entry carries
  # whether the account is local, so the caller can split in-process
  # delivery from federation.
  @mention_re ~r/(?<![\w])@([\w]+)(?:@([\w.\-]+))?/
  @max_mentions 20

  @doc """
  Tell the local people this note named.

  This did not exist. `mention` notifications were created in exactly one
  place — `AP.Instructions.Mirror`, where a note arriving *from another
  server* is taken in — and its own comment notes that DMs never reach it.
  So nothing written here ever notified anybody: not a DM, not a public
  post naming a neighbour. A hundred messages in one conversation and not
  one `mention` row behind them.

  It went unnoticed because the thread shows its own messages regardless,
  and because the direct-tier count and Web Push both read the
  notification table — a pipe can be built end to end and stay silent
  when nothing upstream ever pours into it.

  Best-effort and after the commit: a notification that fails must never
  fail the post it was about.
  """
  def notify_local_mentions(%Note{} = note) do
    for account_id <- local_mentioned_ids(note.content),
        account_id != note.account_id do
      Notifications.create(%{
        account_id: account_id,
        from_account_id: note.account_id,
        note_id: note.id,
        type: "mention"
      })
    end

    :ok
  rescue
    error ->
      Logger.warning("mention notify failed for note #{note.id}: #{Exception.message(error)}")
      :ok
  end

  # Local accounts named in the body. **No remote resolution here** —
  # `resolve_mention_recipients/1` WebFingers unknown handles so it can
  # address them, which is right for delivery and wrong for this: a
  # notification is only ever for someone who lives here, and a synchronous
  # fetch to an attacker-named host on every post is a door we don't need
  # to open twice.
  defp local_mentioned_ids(content) when is_binary(content) do
    our = SukhiFedi.Config.domain!() |> String.split(":") |> hd()

    @mention_re
    |> Regex.scan(content)
    |> Enum.flat_map(fn
      # A bare `@name`, or `@name@our-own-domain` — both mean someone here.
      [_, user, host] when host == "" or host == our -> [user]
      [_, user] -> [user]
      _ -> []
    end)
    |> Enum.uniq()
    |> Enum.take(@max_mentions)
    |> Enum.flat_map(fn username ->
      case SukhiFedi.Accounts.by_local_username(username) do
        %Account{id: id} -> [id]
        _ -> []
      end
    end)
  end

  defp local_mentioned_ids(_), do: []

  defp resolve_mention_recipients(content) when is_binary(content) do
    domain = SukhiFedi.Config.domain!()

    @mention_re
    |> Regex.scan(content)
    |> Enum.map(fn
      [_, user, host] when host != "" -> "#{user}@#{host}"
      [_, user | _] -> user
    end)
    |> Enum.uniq()
    # Cap the fan-out: each unknown remote handle triggers a synchronous
    # WebFinger + actor fetch to an attacker-chosen host, so an unbounded
    # mention list is an amplification/DoS vector.
    |> Enum.take(@max_mentions)
    |> Enum.flat_map(fn handle ->
      case SukhiFedi.Accounts.lookup_by_acct(handle, resolve: true) do
        {:ok, %Account{} = account} ->
          [
            %{
              actor_uri: recipient_actor_uri(account, domain),
              account_id: account.id,
              local?: is_nil(account.domain)
            }
          ]

        _ ->
          []
      end
    end)
    |> Enum.uniq_by(& &1.actor_uri)
  end

  defp resolve_mention_recipients(_), do: []

  defp recipient_actor_uri(%Account{actor_uri: uri}, _domain) when is_binary(uri), do: uri
  defp recipient_actor_uri(%Account{username: u}, domain), do: "https://#{domain}/users/#{u}"

  # Optional poll block. Mastodon shape:
  #   poll[options][]=A&poll[options][]=B&poll[expires_in]=3600&poll[multiple]=false
  # JSON clients send `"poll": {"options": [...], ...}`. We accept
  # both; missing means "no poll", invalid means a Multi error so
  # the whole transaction rolls back.
  defp attach_poll(multi, params) do
    case extract_poll(params) do
      nil ->
        multi

      %{options: [_, _ | _] = options, expires_in: ein, multiple: multiple} ->
        expires_at =
          if is_integer(ein) and ein > 0 do
            DateTime.utc_now()
            |> DateTime.add(ein, :second)
            |> DateTime.truncate(:second)
          end

        multi
        |> Multi.run(:poll, fn repo, %{note: %SukhiFedi.Schema.Note{id: nid}} ->
          poll_cs =
            SukhiFedi.Schema.Poll.changeset(%SukhiFedi.Schema.Poll{}, %{
              note_id: nid,
              multiple: !!multiple,
              expires_at: expires_at
            })

          repo.insert(poll_cs)
        end)
        |> Multi.run(:poll_options, fn repo, %{poll: %{id: pid}} ->
          rows =
            options
            |> Enum.with_index()
            |> Enum.map(fn {title, idx} ->
              %{title: title, position: idx, poll_id: pid}
            end)

          {n, _} = repo.insert_all("poll_options", rows)
          {:ok, n}
        end)

      _ ->
        Multi.error(multi, :poll_invalid, :poll_needs_two_options)
    end
  end

  defp extract_poll(params) do
    opts =
      params[:poll] || params["poll"] ||
        params["poll[options][]"] || params[:poll_options] ||
        nil

    case opts do
      nil ->
        nil

      list when is_list(list) ->
        %{
          options: clean_options(list),
          expires_in: Ids.parse_int(params["poll[expires_in]"]),
          multiple: parse_bool(params["poll[multiple]"])
        }

      %{} = map ->
        %{
          options: clean_options(map["options"] || map[:options] || []),
          expires_in: Ids.parse_int(map["expires_in"] || map[:expires_in]),
          multiple: parse_bool(map["multiple"] || map[:multiple])
        }

      _ ->
        nil
    end
  end

  defp clean_options(list) when is_list(list) do
    list
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp clean_options(_), do: []

  defp parse_bool(true), do: true
  defp parse_bool(false), do: false
  defp parse_bool("true"), do: true
  defp parse_bool("1"), do: true
  defp parse_bool(_), do: false

  defp resolve_in_reply_to(attrs, params) do
    case params[:in_reply_to_id] || params["in_reply_to_id"] do
      nil ->
        attrs

      id ->
        case resolve_in_reply_to_ap_id(id) do
          nil -> attrs
          ap_id -> Map.put(attrs, :in_reply_to_ap_id, ap_id)
        end
    end
  end

  # Three shapes accepted:
  #   1. A local Note id (integer or numeric string) — its AP id, which for
  #      a local note (NULL `ap_id`) is the synthesized URL, same as a quote
  #      target. Returning NULL here would drop the threading link for a
  #      local→local reply, so go through `Ids.note_ap_id/1`.
  #   2. An http(s) URI for a remote note already mirrored locally
  #      (`notes.ap_id` match) — return as-is.
  #   3. An http(s) URI we've never seen — fetch + mirror via
  #      `Federation.NoteFetcher`, then return the mirrored ap_id.
  #
  # On any fetch error we return nil rather than failing the whole
  # status-create so the user's reply still posts (just without the
  # threading link).
  defp resolve_in_reply_to_ap_id(id) when is_binary(id) do
    cond do
      String.starts_with?(id, "http://") or String.starts_with?(id, "https://") ->
        case SukhiFedi.Federation.NoteFetcher.fetch_and_mirror(id) do
          {:ok, %Note{ap_id: ap_id}} when is_binary(ap_id) -> ap_id
          _ -> nil
        end

      true ->
        case Ids.parse_int(id) do
          nil -> nil
          int_id -> Ids.note_ap_id(int_id)
        end
    end
  end

  defp resolve_in_reply_to_ap_id(id) when is_integer(id) do
    Ids.note_ap_id(id)
  end

  defp resolve_in_reply_to_ap_id(_), do: nil

  # `quote_id` / `quoted_status_id` → `quote_of_ap_id`. A Mastodon
  # client quoting a note is the caller for the outbound 引用ノート
  # plumbing. On any resolution miss we drop the quote rather than
  # failing the post.
  defp resolve_quote(attrs, params) do
    case params[:quote_id] || params["quote_id"] ||
           params[:quoted_status_id] || params["quoted_status_id"] do
      nil ->
        attrs

      id ->
        case quote_ap_id(id) do
          nil -> attrs
          ap_id -> Map.put(attrs, :quote_of_ap_id, ap_id)
        end
    end
  end

  # A quote target is an http(s) URI (fetched + mirrored on a miss) or
  # a local Note id. Local notes carry no `ap_id`, so synthesize the AP
  # URL the way `NoteController` publishes it.
  defp quote_ap_id(id) when is_binary(id) do
    if String.starts_with?(id, "http://") or String.starts_with?(id, "https://") do
      case SukhiFedi.Federation.NoteFetcher.fetch_and_mirror(id) do
        {:ok, %Note{ap_id: ap_id}} when is_binary(ap_id) -> ap_id
        _ -> nil
      end
    else
      case Ids.parse_int(id) do
        nil -> nil
        int_id -> Ids.note_ap_id(int_id)
      end
    end
  end

  defp quote_ap_id(id) when is_integer(id), do: Ids.note_ap_id(id)
  defp quote_ap_id(_), do: nil

  # AP `attachment` descriptors for the outbox event, kept in `media_ids`
  # order so the receiving server shows the gallery the way the author
  # laid it out. The rows already exist (uploaded earlier); ownership is
  # re-checked inside the transaction by `attach_media/3`.
  defp attachment_descriptors([], _account_id), do: []

  defp attachment_descriptors(media_ids, account_id) do
    by_id =
      from(m in Media, where: m.id in ^media_ids and m.account_id == ^account_id)
      |> Repo.all()
      |> Map.new(&{&1.id, &1})

    media_ids
    |> Enum.map(&Map.get(by_id, &1))
    |> Enum.reject(&is_nil/1)
    |> SukhiFedi.AP.MediaSerialize.descriptors()
  end

  defp list_media_ids(params) do
    raw =
      params[:media_ids] || params["media_ids"] || params["media_ids[]"] || []

    raw
    |> List.wrap()
    |> Enum.map(&Ids.parse_int/1)
    |> Enum.reject(&is_nil/1)
  end

  defp attach_media(multi, [], _account_id), do: multi

  defp attach_media(multi, media_ids, account_id) do
    multi
    |> Multi.run(:media_check, fn repo, _changes ->
      owned =
        from(m in Media, where: m.id in ^media_ids and m.account_id == ^account_id, select: m.id)
        |> repo.all()

      if MapSet.equal?(MapSet.new(owned), MapSet.new(media_ids)) do
        {:ok, owned}
      else
        {:error, :not_owned}
      end
    end)
    |> Multi.run(:media_attached, fn repo, %{note: note, media_check: media_ids} ->
      # note_media is a pure join table — no timestamps in the schema.
      rows = Enum.map(media_ids, fn mid -> %{note_id: note.id, media_id: mid} end)
      {n, _} = repo.insert_all("note_media", rows)

      # Stamp attached_at so subsequent attach attempts (or the
      # idempotency check in MediaCtx.attach/3) treat these rows as
      # claimed. Only flips rows that haven't been claimed yet.
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      repo.update_all(
        from(m in Media, where: m.id in ^media_ids and is_nil(m.attached_at)),
        set: [attached_at: now]
      )

      {:ok, n}
    end)
  end

  @doc """
  Delete a note. Owner-checked: returns `{:error, :forbidden}` if the
  caller doesn't own the note.

  Emits `sns.outbox.note.deleted` carrying the AP id so federated
  peers can scrub their cached copies.
  """
  @spec delete_note(Account.t() | integer(), integer() | binary()) ::
          {:ok, Note.t()} | {:error, :not_found | :forbidden}
  def delete_note(%Account{id: aid}, note_id), do: delete_note(aid, note_id)

  def delete_note(account_id, note_id) when is_integer(account_id) do
    case Ids.parse_int(note_id) do
      nil ->
        {:error, :not_found}

      n ->
        case Repo.get(Note, n) do
          nil ->
            {:error, :not_found}

          %Note{account_id: ^account_id} = note ->
            do_delete(note)

          %Note{} ->
            {:error, :forbidden}
        end
    end
  end

  # Stamp a freshly-inserted local note with its canonical ap_id. A local
  # note is created without one (the id isn't known until insert), so we
  # derive and persist it right after — every later reader (delete, refs,
  # the boomerang guard) then just reads the column. change/3, not
  # changeset/2, so domain derivation isn't re-run (the note stays local).
  defp stamp_local_ap_id(multi) do
    Multi.update(multi, :stamp_ap_id, fn %{note: note} ->
      Ecto.Changeset.change(note, ap_id: Ids.note_ap_id(note.id))
    end)
  end

  defp do_delete(%Note{} = note) do
    Multi.new()
    |> Multi.delete(:note, note)
    |> enqueue_note_delete(note)
    |> Repo.transaction()
    |> case do
      {:ok, %{note: deleted}} -> {:ok, deleted}
      {:error, _step, reason, _} -> {:error, reason}
    end
  end

  @doc """
  Hard-delete a local note for self-cleanup: remove the row (and its media
  via cascade), append the cleanup ledger row recording its birth + deletion,
  and enqueue the **same** federated `Delete(Note)` a manual delete sends, so
  remote peers forget it. All three ride one `Ecto.Multi` so the Delete is
  never lost (transactional outbox; the irreversible-loss discipline).

  `now`/`reason` are passed by the caller so a batch shares one timestamp.
  Idempotent: a note that is already gone returns `:noop` without hitting the
  DB, so a retried Oban batch converges safely.
  """
  @spec delete_note_for_cleanup(Note.t(), DateTime.t(), String.t() | nil) ::
          {:ok, Note.t()} | {:noop, nil} | {:error, term()}
  def delete_note_for_cleanup(%Note{} = note, %DateTime{} = now, reason) do
    Multi.new()
    |> Multi.delete(:note, note)
    |> Multi.insert(
      :ledger,
      NoteCleanupLedger.changeset(%{
        account_id: note.account_id,
        note_id: note.id,
        note_created_at: note.created_at,
        deleted_at: now,
        reason: reason
      })
    )
    |> enqueue_note_delete(note)
    |> Repo.transaction()
    |> case do
      {:ok, %{note: deleted}} -> {:ok, deleted}
      {:error, _step, failed, _} -> {:error, failed}
    end
  end

  # The one federated-Delete enqueue, shared by hard delete and soft archive.
  # ap_id is persisted now, but fall back to deriving it so a row created
  # before the backfill still federates its Delete (nil here is exactly the
  # bug that left deletes stuck — see Ids.note_ap_id). The delivery node's
  # `handle_note_deleted` needs only account_id + ap_id; it never re-reads the
  # row, so a kept-but-archived row federates its Delete identically.
  defp enqueue_note_delete(multi, %Note{} = note) do
    ap_id = note.ap_id || Ids.note_ap_id(note.id)

    Outbox.enqueue_multi(
      multi,
      :outbox_event,
      "sns.outbox.note.deleted",
      "note",
      fn _ -> note.id end,
      fn _ ->
        %{note_id: note.id, ap_id: ap_id, account_id: note.account_id}
      end
    )
  end

  defp maybe_extract_emojis(attrs) do
    case attrs[:emojis] || attrs["emojis"] do
      list when is_list(list) and list != [] ->
        attrs

      _ ->
        content = attrs[:content] || attrs["content"] || ""
        cw = attrs[:cw] || attrs["cw"] || ""
        title = attrs[:title] || attrs["title"] || ""
        text = "#{title} #{cw} #{content}"

        case SukhiFedi.CustomEmojis.extract_from_text(text) do
          [] -> attrs
          emojis -> Map.put(attrs, :emojis, emojis)
        end
    end
  end

  defp normalize_visibility(v) when v in ["public", "unlisted", "followers", "direct"], do: v
  # Mastodon's "private" maps to our "followers"
  defp normalize_visibility("private"), do: "followers"
  defp normalize_visibility(_), do: "public"
end
