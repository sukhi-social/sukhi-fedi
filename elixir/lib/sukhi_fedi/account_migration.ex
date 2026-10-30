# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.AccountMigration do
  @moduledoc """
  Outgoing account migration (Mastodon-standard Move + `alsoKnownAs`).
  Reachable from the api plugin node via
  `SukhiApi.GatewayRpc.call(SukhiFedi.AccountMigration, :fun, [args])`.

  Two parts, matching the Mastodon flow:

    * **aliases** — the prior identities a user declares as "also me".
      Editing them re-publishes the actor (`Update {Person}`) so the
      `alsoKnownAs` set reaches followers; this is the consent a *new*
      server reads before it accepts an inbound Move to us. (The inbound
      side is `AP.Instructions.Migrations`.)

    * **move** — point this account at a `target` identity. We require the
      same bidirectional consent we require of others: the target must
      list us in its `alsoKnownAs`. On success we stamp `moved_to_uri`
      (so every screen renders "moved to @new") and emit
      `sns.outbox.move.created` so the delivery node fans a `Move` out to
      our followers — whose servers then re-point their follow.

  The consent rule is the one predicate
  `AP.Instructions.Migrations.bidirectional_consent?/2`; this module
  never re-spells it (CODE_STYLE §3).
  """

  alias Ecto.Multi
  alias SukhiFedi.AP.Instructions.{Migrations, Resolve}
  alias SukhiFedi.Addons.Moderation
  alias SukhiFedi.Federation.WebFinger
  alias SukhiFedi.{Outbox, Repo}
  alias SukhiFedi.Schema.Account

  @max_aliases 5

  @doc """
  Replace this account's alias set with `uris` (the full desired list).

  Each entry must be a well-formed http(s) actor URI other than the
  account's own. A new entry is accepted when its server vouches for it by
  WebFinger (a handle, a profile page or the actor URI), and the actor URI
  it answers with is what is stored, which is what a Move compares; one
  that cannot be resolved is `{:error, {:invalid_alias, entry}}`. Entries
  already saved are kept without asking again (an old server may be gone). Emits `sns.outbox.actor.updated` so the new
  `alsoKnownAs` federates. Returns `{:ok, account}` or `{:error, reason}`.
  """
  @spec set_aliases(integer(), [String.t()]) ::
          {:ok, Account.t()}
          | {:error, :not_found | :too_many | {:invalid_alias, String.t()} | {:validation, map()}}
  def set_aliases(account_id, uris) when is_integer(account_id) and is_list(uris) do
    case Repo.get(Account, account_id) do
      nil ->
        {:error, :not_found}

      %Account{} = account ->
        self_uri = actor_uri(account)

        with {:ok, resolved} <- resolve_aliases(uris, account.aliases || []) do
          cleaned = resolved |> Enum.flat_map(&valid_alias(&1, self_uri)) |> Enum.uniq()

          cond do
            length(cleaned) > @max_aliases -> {:error, :too_many}
            true -> update_aliases(account, cleaned)
          end
        end
    end
  end

  # Only entries we have not saved before are asked about, side by side
  # (each can take up to WebFinger's 10 s).
  defp resolve_aliases(entries, saved) do
    entries =
      entries |> Enum.map(&(&1 |> to_string() |> String.trim())) |> Enum.reject(&(&1 == ""))

    entries
    |> Task.async_stream(
      fn entry ->
        if entry in saved, do: {:ok, entry}, else: target_actor_uri(entry)
      end,
      max_concurrency: @max_aliases,
      timeout: 15_000,
      on_timeout: :kill_task,
      ordered: true
    )
    |> Enum.zip(entries)
    |> Enum.reduce_while({:ok, []}, fn
      {{:ok, {:ok, uri}}, _entry}, {:ok, acc} -> {:cont, {:ok, [uri | acc]}}
      {_failed, entry}, _acc -> {:halt, {:error, {:invalid_alias, entry}}}
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp update_aliases(%Account{} = account, cleaned) do
    Multi.new()
    |> Multi.update(:account, Ecto.Changeset.change(account, %{aliases: cleaned}))
    |> Outbox.enqueue_multi(
      :outbox_event,
      "sns.outbox.actor.updated",
      "account",
      & &1.account.id,
      fn %{account: a} -> %{account_id: a.id, username: a.username} end
    )
    |> Repo.transaction()
    |> case do
      {:ok, %{account: a}} -> {:ok, a}
      {:error, _step, reason, _} -> {:error, reason}
    end
  end

  @doc """
  Move this account to `target_uri`.

  `target` is anything the target's server vouches for by WebFinger: a
  handle (`@name@host`), a profile page, or the actor URI. We move to the
  actor URI it answers with.

  Fetches the target actor fresh, requires its `alsoKnownAs` to list this
  account (bidirectional consent), then in one transaction stamps
  `moved_to_uri` and enqueues `sns.outbox.move.created`. Returns
  `{:ok, account}` or `{:error, reason}`.
  """
  @spec move(integer(), String.t()) ::
          {:ok, Account.t()}
          | {:error, :not_found | :invalid_target | :already_moved | :consent_missing | term()}
  def move(account_id, target) when is_integer(account_id) and is_binary(target) do
    with %Account{moved_to_uri: nil} = account <- get_unmoved(account_id),
         self_uri = actor_uri(account),
         {:ok, target_uri} <- target_actor_uri(target),
         [^target_uri] <- valid_alias(target_uri, self_uri),
         {:ok, target} <- Resolve.resolve_or_ingest_actor(target_uri),
         true <- Migrations.bidirectional_consent?(self_uri, target) do
      do_move(account, target)
    else
      %Account{} -> {:error, :already_moved}
      nil -> {:error, :not_found}
      [] -> {:error, :invalid_target}
      false -> {:error, :consent_missing}
      {:error, _} -> {:error, :invalid_target}
    end
  end

  # What was typed (a handle, a profile page, an actor URI) is accepted when
  # the other server, asked by WebFinger, answers with the actor's `self`
  # URL; that URL is what we store and compare. No per-form rules here.
  defp target_actor_uri(input), do: WebFinger.resolve_self(input)

  defp do_move(%Account{} = account, %Account{} = target) do
    target_uri = target.actor_uri || actor_uri(target)

    Multi.new()
    |> Multi.update(:account, Ecto.Changeset.change(account, %{moved_to_uri: target_uri}))
    |> Outbox.enqueue_multi(
      :outbox_event,
      "sns.outbox.move.created",
      "account",
      & &1.account.id,
      fn %{account: a} -> %{account_id: a.id, move_id: a.id, target: target_uri} end
    )
    |> Repo.transaction()
    |> case do
      {:ok, %{account: a}} ->
        carry_over_moderation(a, target)
        {:ok, a}

      {:error, _step, reason, _} ->
        {:error, reason}
    end
  end

  # Relationship carry-over — only the portable, honest subset: the
  # migrating account's *own* outgoing mutes and blocks, and only when the
  # new identity is local (we don't own a remote account's moderation
  # state). We deliberately do NOT auto-propagate *incoming* blocks: it's
  # not ours to silently mutate every local blocker's state — same
  # dishonesty class as state surviving the action that should clear it.
  # Best-effort, outside the Move transaction: the federated Move must not
  # hinge on copying a local convenience.
  defp carry_over_moderation(%Account{id: from_id}, %Account{domain: nil, id: to_id})
       when from_id != to_id do
    Enum.each(Moderation.blocked_target_ids(from_id), &Moderation.block(to_id, &1))
    Enum.each(Moderation.muted_target_ids(from_id), &Moderation.mute(to_id, &1))
    :ok
  end

  defp carry_over_moderation(_account, _target), do: :ok

  defp get_unmoved(account_id) do
    case Repo.get(Account, account_id) do
      %Account{domain: nil} = a -> a
      _ -> nil
    end
  end

  # An alias must be a well-formed http(s) actor URI that isn't this
  # account itself. Returns `[uri]` when valid, `[]` otherwise, so callers
  # flat_map a list and pattern-match a single one.
  defp valid_alias(uri, self_uri) when is_binary(uri) do
    case URI.parse(uri) do
      %URI{scheme: s, host: h} when s in ["http", "https"] and is_binary(h) and h != "" ->
        if uri == self_uri, do: [], else: [uri]

      _ ->
        []
    end
  end

  defp valid_alias(_uri, _self_uri), do: []

  defp actor_uri(%Account{username: u}), do: "https://#{SukhiFedi.Config.domain!()}/users/#{u}"
end
