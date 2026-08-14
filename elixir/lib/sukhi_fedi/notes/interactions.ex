# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Notes.Interactions do
  @moduledoc """
  Acting on a note: favourite / custom reaction / reblog / bookmark /
  pin, plus the viewer's bookmark and favourite lists. All idempotent;
  the federating ones enqueue their outbox event in the same
  transaction as the row change.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias SukhiFedi.Notes.{Ids, Read}
  alias SukhiFedi.{Outbox, Repo}
  alias SukhiFedi.Schema.{Account, Bookmark, Boost, Note, PinnedNote, Reaction}

  @favourite_emoji "⭐"

  @doc """
  The emoji a Mastodon-style favourite is stored as. A `Reaction` row
  carrying this emoji is a favourite; any other emoji is a Misskey-style
  custom reaction.
  """
  @spec favourite_emoji() :: String.t()
  def favourite_emoji, do: @favourite_emoji

  @doc """
  Mark a note as favourited by `account`. Idempotent — second call is
  a no-op. Emits `sns.outbox.like.created` on first insert (delivery
  node will translate to `Like` AP activity).
  """
  @spec favourite(Account.t() | integer(), integer() | binary()) ::
          {:ok, Note.t()} | {:error, :not_found}
  def favourite(%Account{id: aid}, note_id), do: favourite(aid, note_id)

  def favourite(account_id, note_id) when is_integer(account_id) do
    with_visible_note(account_id, note_id, fn note ->
      case Repo.get_by(Reaction,
             account_id: account_id,
             note_id: note.id,
             emoji: @favourite_emoji
           ) do
        %Reaction{} ->
          {:ok, note}

        nil ->
          Multi.new()
          |> Multi.insert(
            :reaction,
            Reaction.changeset(%Reaction{}, %{
              account_id: account_id,
              note_id: note.id,
              emoji: @favourite_emoji
            })
          )
          |> Outbox.enqueue_multi(
            :outbox_event,
            "sns.outbox.like.created",
            "reaction",
            & &1.reaction.id,
            fn %{reaction: r} ->
              %{
                reaction_id: r.id,
                account_id: r.account_id,
                note_id: r.note_id,
                note_ap_id: note.ap_id,
                emoji: r.emoji
              }
            end
          )
          |> Repo.transaction()
          |> case do
            {:ok, _} ->
              SukhiFedi.Notifications.create(%{
                account_id: note.account_id,
                from_account_id: account_id,
                note_id: note.id,
                type: "favourite"
              })

              {:ok, note}

            {:error, _step, reason, _} ->
              {:error, reason}
          end
      end
    end)
  end

  @doc "Remove favourite. Idempotent. Emits `sns.outbox.like.undone` on actual delete."
  @spec unfavourite(Account.t() | integer(), integer() | binary()) ::
          {:ok, Note.t()} | {:error, :not_found}
  def unfavourite(%Account{id: aid}, note_id), do: unfavourite(aid, note_id)

  def unfavourite(account_id, note_id) when is_integer(account_id) do
    with_loaded_note(note_id, fn note ->
      case Repo.get_by(Reaction,
             account_id: account_id,
             note_id: note.id,
             emoji: @favourite_emoji
           ) do
        nil ->
          {:ok, note}

        %Reaction{} = r ->
          Multi.new()
          |> Multi.delete(:reaction, r)
          |> Outbox.enqueue_multi(
            :outbox_event,
            "sns.outbox.like.undone",
            "reaction",
            fn _ -> r.id end,
            fn _ ->
              %{
                reaction_id: r.id,
                account_id: r.account_id,
                note_id: r.note_id,
                note_ap_id: note.ap_id
              }
            end
          )
          |> Repo.transaction()
          |> case do
            {:ok, _} -> {:ok, note}
            {:error, _step, reason, _} -> {:error, reason}
          end
      end
    end)
  end

  @doc """
  React to a note with an arbitrary emoji (Misskey-style custom
  reaction). Idempotent per `(account, note, emoji)`. Emits
  `sns.outbox.reaction.created` so the delivery node federates an
  `EmojiReact`.

  Unlike `favourite/2` — the ⭐ special case that federates as a
  `Like` — this carries the emoji on the wire. No HTTP route reaches
  it yet; the Misskey client API that would is parked (OPEN_QUESTIONS
  Q3).
  """
  @spec react(Account.t() | integer(), integer() | binary(), String.t()) ::
          {:ok, Note.t()} | {:error, :not_found | term()}
  def react(%Account{id: aid}, note_id, emoji), do: react(aid, note_id, emoji)

  def react(account_id, note_id, emoji)
      when is_integer(account_id) and is_binary(emoji) do
    with_visible_note(account_id, note_id, fn note ->
      case Repo.get_by(Reaction, account_id: account_id, note_id: note.id, emoji: emoji) do
        %Reaction{} ->
          {:ok, note}

        nil ->
          Multi.new()
          |> Multi.insert(
            :reaction,
            Reaction.changeset(%Reaction{}, %{
              account_id: account_id,
              note_id: note.id,
              emoji: emoji
            })
          )
          |> Outbox.enqueue_multi(
            :outbox_event,
            "sns.outbox.reaction.created",
            "reaction",
            & &1.reaction.id,
            fn %{reaction: r} ->
              %{
                reaction_id: r.id,
                account_id: r.account_id,
                note_id: r.note_id,
                note_ap_id: note.ap_id,
                emoji: r.emoji
              }
            end
          )
          |> Repo.transaction()
          |> case do
            {:ok, _} ->
              SukhiFedi.Notifications.create(%{
                account_id: note.account_id,
                from_account_id: account_id,
                note_id: note.id,
                type: "favourite"
              })

              {:ok, note}

            {:error, _step, reason, _} ->
              {:error, reason}
          end
      end
    end)
  end

  @doc "Remove a custom emoji reaction. Idempotent. Emits `sns.outbox.reaction.undone` on actual delete."
  @spec unreact(Account.t() | integer(), integer() | binary(), String.t() | nil) ::
          {:ok, Note.t()} | {:error, :not_found | term()}
  def unreact(account, note_id, emoji \\ nil)
  def unreact(%Account{id: aid}, note_id, emoji), do: unreact(aid, note_id, emoji)

  def unreact(account_id, note_id, emoji) when is_integer(account_id) do
    with_loaded_note(note_id, fn note ->
      reaction =
        if is_binary(emoji) and emoji != "" do
          Repo.get_by(Reaction, account_id: account_id, note_id: note.id, emoji: emoji) ||
            Repo.get_by(Reaction, account_id: account_id, note_id: note.id)
        else
          from(r in Reaction,
            where: r.account_id == ^account_id and r.note_id == ^note.id,
            limit: 1
          )
          |> Repo.one()
        end

      case reaction do
        nil ->
          {:ok, note}

        %Reaction{} = r ->
          Multi.new()
          |> Multi.delete(:reaction, r)
          |> Outbox.enqueue_multi(
            :outbox_event,
            "sns.outbox.reaction.undone",
            "reaction",
            fn _ -> r.id end,
            fn _ ->
              %{
                reaction_id: r.id,
                account_id: r.account_id,
                note_id: r.note_id,
                note_ap_id: note.ap_id,
                emoji: r.emoji
              }
            end
          )
          |> Repo.transaction()
          |> case do
            {:ok, _} -> {:ok, note}
            {:error, _step, reason, _} -> {:error, reason}
          end
      end
    end)
  end

  @doc "Reblog (Mastodon) / Boost (internal). Idempotent. Emits `sns.outbox.announce.created`."
  @spec reblog(Account.t() | integer(), integer() | binary()) ::
          {:ok, Note.t()} | {:error, :not_found}
  def reblog(%Account{id: aid}, note_id), do: reblog(aid, note_id)

  def reblog(account_id, note_id) when is_integer(account_id) do
    with_visible_note(account_id, note_id, fn note ->
      case Repo.get_by(Boost, account_id: account_id, note_id: note.id) do
        %Boost{} ->
          {:ok, note}

        nil ->
          Multi.new()
          |> Multi.insert(
            :boost,
            Boost.changeset(%Boost{}, %{account_id: account_id, note_id: note.id})
          )
          |> Outbox.enqueue_multi(
            :outbox_event,
            "sns.outbox.announce.created",
            "boost",
            & &1.boost.id,
            fn %{boost: b} ->
              %{
                boost_id: b.id,
                account_id: b.account_id,
                note_id: b.note_id,
                note_ap_id: note.ap_id
              }
            end
          )
          |> Repo.transaction()
          |> case do
            {:ok, _} ->
              SukhiFedi.Notifications.create(%{
                account_id: note.account_id,
                from_account_id: account_id,
                note_id: note.id,
                type: "reblog"
              })

              {:ok, note}

            {:error, _step, reason, _} ->
              {:error, reason}
          end
      end
    end)
  end

  @doc "Undo reblog. Idempotent. Emits `sns.outbox.announce.undone` on actual delete."
  @spec unreblog(Account.t() | integer(), integer() | binary()) ::
          {:ok, Note.t()} | {:error, :not_found}
  def unreblog(%Account{id: aid}, note_id), do: unreblog(aid, note_id)

  def unreblog(account_id, note_id) when is_integer(account_id) do
    with_loaded_note(note_id, fn note ->
      case Repo.get_by(Boost, account_id: account_id, note_id: note.id) do
        nil ->
          {:ok, note}

        %Boost{} = b ->
          Multi.new()
          |> Multi.delete(:boost, b)
          |> Outbox.enqueue_multi(
            :outbox_event,
            "sns.outbox.announce.undone",
            "boost",
            fn _ -> b.id end,
            fn _ ->
              %{
                boost_id: b.id,
                account_id: b.account_id,
                note_id: b.note_id,
                note_ap_id: note.ap_id
              }
            end
          )
          |> Repo.transaction()
          |> case do
            {:ok, _} -> {:ok, note}
            {:error, _step, reason, _} -> {:error, reason}
          end
      end
    end)
  end

  @doc "Bookmark a note. Local-only — no outbox event. Idempotent."
  @spec bookmark(Account.t() | integer(), integer() | binary()) ::
          {:ok, Note.t()} | {:error, :not_found}
  def bookmark(%Account{id: aid}, note_id), do: bookmark(aid, note_id)

  def bookmark(account_id, note_id) when is_integer(account_id) do
    with_visible_note(account_id, note_id, fn note ->
      _ =
        %Bookmark{account_id: account_id, note_id: note.id}
        |> Repo.insert(on_conflict: :nothing)

      {:ok, note}
    end)
  end

  @spec unbookmark(Account.t() | integer(), integer() | binary()) ::
          {:ok, Note.t()} | {:error, :not_found}
  def unbookmark(%Account{id: aid}, note_id), do: unbookmark(aid, note_id)

  def unbookmark(account_id, note_id) when is_integer(account_id) do
    with_loaded_note(note_id, fn note ->
      _ =
        Repo.delete_all(
          from(b in Bookmark, where: b.account_id == ^account_id and b.note_id == ^note.id)
        )

      {:ok, note}
    end)
  end

  @doc """
  Pin a note to the actor's featured collection. Owner-checked (you
  can only pin your own notes). Emits `sns.outbox.add.created` so
  remote followers can update their featured collection cache.
  """
  @spec pin(Account.t() | integer(), integer() | binary()) ::
          {:ok, Note.t()} | {:error, :not_found | :forbidden}
  def pin(%Account{id: aid}, note_id), do: pin(aid, note_id)

  def pin(account_id, note_id) when is_integer(account_id) do
    case load_owned_note(account_id, note_id) do
      {:error, e} ->
        {:error, e}

      {:ok, note} ->
        case Repo.get_by(PinnedNote, account_id: account_id, note_id: note.id) do
          %PinnedNote{} ->
            {:ok, note}

          nil ->
            Multi.new()
            |> Multi.insert(
              :pinned,
              PinnedNote.changeset(%PinnedNote{}, %{account_id: account_id, note_id: note.id})
            )
            |> Outbox.enqueue_multi(
              :outbox_event,
              "sns.outbox.add.created",
              "pinned_note",
              & &1.pinned.id,
              fn %{pinned: p} ->
                %{
                  pinned_id: p.id,
                  account_id: p.account_id,
                  note_id: p.note_id,
                  note_ap_id: note.ap_id
                }
              end
            )
            |> Repo.transaction()
            |> case do
              {:ok, _} -> {:ok, note}
              {:error, _step, reason, _} -> {:error, reason}
            end
        end
    end
  end

  @spec unpin(Account.t() | integer(), integer() | binary()) ::
          {:ok, Note.t()} | {:error, :not_found | :forbidden}
  def unpin(%Account{id: aid}, note_id), do: unpin(aid, note_id)

  def unpin(account_id, note_id) when is_integer(account_id) do
    case load_owned_note(account_id, note_id) do
      {:error, e} ->
        {:error, e}

      {:ok, note} ->
        case Repo.get_by(PinnedNote, account_id: account_id, note_id: note.id) do
          nil ->
            {:ok, note}

          %PinnedNote{} = p ->
            Multi.new()
            |> Multi.delete(:pinned, p)
            |> Outbox.enqueue_multi(
              :outbox_event,
              "sns.outbox.remove.created",
              "pinned_note",
              fn _ -> p.id end,
              fn _ ->
                %{
                  pinned_id: p.id,
                  account_id: p.account_id,
                  note_id: p.note_id,
                  note_ap_id: note.ap_id
                }
              end
            )
            |> Repo.transaction()
            |> case do
              {:ok, _} -> {:ok, note}
              {:error, _step, reason, _} -> {:error, reason}
            end
        end
    end
  end

  @doc """
  List the viewer's bookmarked notes (newest bookmark first, Mastodon
  pagination opts).
  """
  @spec list_bookmarks(Account.t() | integer(), keyword() | map()) :: [Note.t()]
  def list_bookmarks(%Account{id: aid}, opts), do: list_bookmarks(aid, opts)

  def list_bookmarks(account_id, opts) when is_integer(account_id) do
    opts = normalize_kv(opts)
    limit = clamp_limit(Map.get(opts, :limit, 20))

    from(b in Bookmark,
      join: n in Note,
      on: b.note_id == n.id,
      where: b.account_id == ^account_id,
      order_by: [desc: b.id],
      limit: ^limit,
      select: n
    )
    |> Repo.all()
    |> Repo.preload([:account, :media, :tags])
    |> Read.with_refs()
  end

  @doc "Same as list_bookmarks but for favourites (Reactions with the favourite emoji)."
  @spec list_favourites(Account.t() | integer(), keyword() | map()) :: [Note.t()]
  def list_favourites(%Account{id: aid}, opts), do: list_favourites(aid, opts)

  def list_favourites(account_id, opts) when is_integer(account_id) do
    opts = normalize_kv(opts)
    limit = clamp_limit(Map.get(opts, :limit, 20))

    from(r in Reaction,
      join: n in Note,
      on: r.note_id == n.id,
      where: r.account_id == ^account_id and r.emoji == ^@favourite_emoji,
      order_by: [desc: r.id],
      limit: ^limit,
      select: n
    )
    |> Repo.all()
    |> Repo.preload([:account, :media, :tags])
    |> Read.with_refs()
  end

  defp with_loaded_note(note_id, fun) do
    case Ids.parse_int(note_id) do
      nil ->
        {:error, :not_found}

      n ->
        case Repo.get(Note, n) do
          nil -> {:error, :not_found}
          note -> fun.(note)
        end
    end
  end

  # Like `with_loaded_note/2`, but only runs `fun` when `account_id` is
  # allowed to see the note (visibility-gated). Used by the favourite /
  # boost / bookmark / react interactions so a caller can't act on a
  # followers-only or direct note they aren't a party to.
  defp with_visible_note(account_id, note_id, fun) do
    case Ids.parse_int(note_id) do
      nil ->
        {:error, :not_found}

      n ->
        case Repo.get(Note, n) do
          nil ->
            {:error, :not_found}

          note ->
            if Read.visible_to?(note, account_id), do: fun.(note), else: {:error, :not_found}
        end
    end
  end

  defp load_owned_note(account_id, note_id) do
    case Ids.parse_int(note_id) do
      nil ->
        {:error, :not_found}

      n ->
        case Repo.get(Note, n) do
          nil -> {:error, :not_found}
          %Note{account_id: ^account_id} = note -> {:ok, note}
          %Note{} -> {:error, :forbidden}
        end
    end
  end

  defp normalize_kv(opts) when is_list(opts), do: Map.new(opts)
  defp normalize_kv(opts) when is_map(opts), do: opts

  defp clamp_limit(n) when is_integer(n) and n > 0 and n <= 40, do: n
  defp clamp_limit(_), do: 20
end
