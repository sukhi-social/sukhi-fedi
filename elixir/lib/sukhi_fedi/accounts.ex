# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Accounts do
  @moduledoc """
  Account context. Reachable from the api plugin node via
  `SukhiApi.GatewayRpc.call(SukhiFedi.Accounts, :fun, [args])`.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias SukhiFedi.{Outbox, Repo}
  alias SukhiFedi.Schema.{Account, Follow, Note, Session}

  # ── origin ────────────────────────────────────────────────────────────────

  @doc """
  Compose an origin filter onto an `Account` query — the one place that
  spells "which side a row came from", so the remote wipe/rebuild tooling
  and any caller scoping by origin share it instead of re-spelling the
  predicate. `local` ⇔ `domain IS NULL` (see `by_local_username/1` for why
  `is_nil/1` and not `domain: nil`). Remote rows are mirrored from upstream
  and reconstructible from the inbound archive; local rows are the source
  of truth and can't be re-fetched.
  """
  @spec local_accounts(Ecto.Queryable.t()) :: Ecto.Query.t()
  def local_accounts(query \\ Account), do: from(a in query, where: is_nil(a.domain))

  @spec remote_accounts(Ecto.Queryable.t()) :: Ecto.Query.t()
  def remote_accounts(query \\ Account), do: from(a in query, where: not is_nil(a.domain))

  # ── reads ─────────────────────────────────────────────────────────────────

  def get_account_by_username(username), do: by_local_username(username)

  @doc """
  Look up an account by username, restricted to local rows (`domain IS NULL`).

  Used everywhere a caller specifically wants the local user. Stays
  out of `Repo.get_by/2` because Ecto 3.12+ refuses `domain: nil` in
  keyword filters — it warns about the silent-always-false trap of
  `WHERE domain = NULL`. We spell `is_nil/1` here once and let every
  call site reach for this helper instead of repeating the query.
  """
  @spec by_local_username(String.t() | nil) :: Account.t() | nil
  def by_local_username(nil), do: nil

  def by_local_username(username) when is_binary(username) do
    Repo.one(from(a in Account, where: a.username == ^username and is_nil(a.domain), limit: 1))
  end

  @doc """
  An HTTP-signature identity for signing outbound fetches against
  Mastodon Secure Mode / Misskey auth-fetch-required peers. Returns the
  oldest local account that holds a keypair, or `nil` when none do — in
  which case fetches go out unauthenticated, the same reach as before.

  Any local actor's signature satisfies an auth-fetch check; a
  dedicated instance actor (which wouldn't leak a username) is left
  for later.
  """
  @spec signing_identity() ::
          %{keyId: String.t(), privateJwk: map(), publicJwk: map() | nil} | nil
  def signing_identity do
    query =
      from(a in Account,
        where: is_nil(a.domain) and not is_nil(a.private_key_jwk),
        order_by: [asc: a.id],
        limit: 1
      )

    case Repo.one(query) do
      %Account{username: u, private_key_jwk: priv, public_key_jwk: pub} ->
        %{
          keyId: "https://#{SukhiFedi.Config.domain!()}/users/#{u}#main-key",
          privateJwk: priv,
          publicJwk: pub
        }

      nil ->
        nil
    end
  end

  @doc """
  Fetch by id. Returns `{:ok, account}` or `{:error, :not_found}`.
  """
  @spec get_account(integer() | binary()) :: {:ok, Account.t()} | {:error, :not_found}
  def get_account(id) do
    id =
      cond do
        is_integer(id) ->
          id

        is_binary(id) ->
          case Integer.parse(id) do
            {n, ""} -> n
            _ -> nil
          end

        true ->
          nil
      end

    case id && Repo.get(Account, id) do
      nil -> {:error, :not_found}
      %Account{} = a -> {:ok, a}
    end
  end

  @doc """
  Resolve a Mastodon-style `acct:` lookup.

  Default: local-only DB read. Pass `resolve: true` to fan out via
  WebFinger + ActorFetcher and upsert a remote shadow Account on miss
  (Mastodon's `?resolve=true` behaviour).
  """
  @spec lookup_by_acct(String.t(), keyword()) ::
          {:ok, Account.t()} | {:error, :not_found | term()}
  def lookup_by_acct(acct, opts \\ []) when is_binary(acct) do
    bare = String.trim_leading(acct, "@")
    local_domain = SukhiFedi.Config.domain!()
    resolve? = Keyword.get(opts, :resolve, false)

    case String.split(bare, "@", parts: 2) do
      [username] ->
        local_lookup(username)

      [username, host] when host == local_domain ->
        local_lookup(username)

      [username, host] ->
        case Repo.get_by(Account, username: username, domain: host) do
          %Account{} = a -> {:ok, a}
          nil when resolve? -> resolve_remote(bare)
          nil -> {:error, :not_found}
        end
    end
  end

  defp local_lookup(username) do
    case get_account_by_username(username) do
      nil -> {:error, :not_found}
      a -> {:ok, a}
    end
  end

  defp resolve_remote(handle) do
    alias SukhiFedi.Federation.{ActorFetcher, RemoteAccounts, WebFinger}

    with {:ok, self_url} <- WebFinger.resolve_self(handle),
         {:ok, actor_json} <- ActorFetcher.fetch(self_url),
         {:ok, %Account{} = a} <- RemoteAccounts.upsert_from_actor_json(actor_json, self_url) do
      {:ok, a}
    else
      {:error, _} = e -> e
      _ -> {:error, :resolve_failed}
    end
  end

  @doc """
  Resolve a session cookie value to its bound `Account`. Returns the
  account, or `nil` if the token is unknown / expired.

  Used by the OAuth `/oauth/authorize` capability to confirm that the
  browser has an authenticated session before minting an authorization
  code on the user's behalf.
  """
  def get_account_by_session_token(token) when is_binary(token) and token != "" do
    h = :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    case Repo.get_by(Session, token_hash: h) do
      nil ->
        nil

      %Session{expires_at: exp} = s ->
        if DateTime.compare(exp, now) == :gt do
          Repo.get(Account, s.account_id)
        else
          nil
        end
    end
  end

  def get_account_by_session_token(_), do: nil

  # ── counts ───────────────────────────────────────────────────────────────

  @doc """
  Return the three Mastodon profile counters in a single roundtrip.

  The numbers don't need to be perfectly fresh on every profile view,
  so we cache for 60 s in an ETS table to absorb refresh storms when a
  user is featured/linked. Cache misses fall through to a single
  `SELECT count` per dimension. Acceptable at MVP scale; revisit when a
  Counters table or trigger-maintained aggregate becomes worth the
  complexity.
  """
  @spec counts_for(integer()) :: %{
          followers: integer(),
          following: integer(),
          statuses: integer()
        }
  def counts_for(account_id) when is_integer(account_id) do
    case cache_get({:counts, account_id}) do
      {:ok, value} ->
        value

      :miss ->
        actor_uri = local_actor_uri(account_id)

        followers =
          Repo.aggregate(
            from(f in Follow, where: f.followee_id == ^account_id and f.state == "accepted"),
            :count,
            :id
          )

        following =
          if actor_uri do
            Repo.aggregate(
              from(f in Follow, where: f.follower_uri == ^actor_uri and f.state == "accepted"),
              :count,
              :id
            )
          else
            0
          end

        # **DM は数えない。** プロフィールの数は誰でも見られるので、ここに
        # direct を足すと「この人が何通 DM を送ったか」が外から数えられる。
        # 中身は見えなくても、増えかたは見えてしまう。
        #
        # 実際そうなっていた ── 一晩 DM をしていたら、公開のプロフィールが
        # 241 になった。手紙の枚数を、玄関に貼っていたようなもの。
        #
        # ほかは残す。フォロワー限定は「見える人には見える投稿」なので、
        # 投稿ではある。ここは timelines / lists / self_cleanup が既に
        # 使っている切りかたと同じ ── 数えるところだけが揃っていなかった。
        statuses =
          Repo.aggregate(
            from(n in Note,
              where: n.account_id == ^account_id and n.visibility != "direct"
            ),
            :count,
            :id
          )

        result = %{followers: followers, following: following, statuses: statuses}
        cache_put({:counts, account_id}, result)
        result
    end
  end

  # ── update_credentials ───────────────────────────────────────────────────

  @doc """
  Update profile fields (display_name, summary/note, avatar/header,
  bot, locked). Emits `sns.outbox.actor.updated` so federated peers
  can refresh their cached actor JSON.
  """
  @spec update_credentials(Account.t() | integer(), map()) ::
          {:ok, Account.t()} | {:error, :not_found | {:validation, map()}}
  def update_credentials(%Account{} = account, attrs) do
    do_update(account, attrs)
  end

  def update_credentials(account_id, attrs) when is_integer(account_id) do
    case Repo.get(Account, account_id) do
      nil -> {:error, :not_found}
      a -> do_update(a, attrs)
    end
  end

  defp do_update(%Account{} = account, attrs) do
    cs = Account.changeset_credentials(account, attrs)

    Multi.new()
    |> Multi.update(:account, cs)
    |> Outbox.enqueue_multi(
      :outbox_event,
      "sns.outbox.actor.updated",
      "account",
      & &1.account.id,
      fn %{account: a} -> %{account_id: a.id, username: a.username} end
    )
    |> Repo.transaction()
    |> case do
      {:ok, %{account: a}} ->
        cache_invalidate({:counts, a.id})
        {:ok, a}

      {:error, :account, %Ecto.Changeset{} = cs, _} ->
        {:error, {:validation, SukhiFedi.Changeset.errors(cs)}}

      {:error, _step, reason, _} ->
        {:error, reason}
    end
  end

  @doc """
  Publishes a bare `sns.outbox.actor.updated` event for a local account
  without changing any profile fields. Use this to nudge remote servers
  that have a stale cached copy of our actor JSON — they receive
  `Update {Person}` and refresh their cache (and, importantly, the
  public key they verify our HTTP signatures against).

  Intended for one-off use from `bin/sukhi_fedi eval`:

      SukhiFedi.Accounts.broadcast_actor_update("nyanrus")

  Returns `{:ok, %OutboxEvent{}}` on success, `{:error, :not_found}` if
  the username isn't local.
  """
  @spec broadcast_actor_update(String.t() | integer()) ::
          {:ok, SukhiFedi.Schema.OutboxEvent.t()} | {:error, :not_found | term()}
  def broadcast_actor_update(username) when is_binary(username) do
    case by_local_username(username) do
      nil -> {:error, :not_found}
      %Account{} = a -> emit_actor_updated(a)
    end
  end

  def broadcast_actor_update(account_id) when is_integer(account_id) do
    case Repo.get(Account, account_id) do
      nil -> {:error, :not_found}
      %Account{} = a -> emit_actor_updated(a)
    end
  end

  defp emit_actor_updated(%Account{id: id, username: username}) do
    Outbox.enqueue(
      "sns.outbox.actor.updated",
      "account",
      to_string(id),
      %{account_id: id, username: username}
    )
  end

  # ── admin listing ────────────────────────────────────────────────────────

  @doc """
  List accounts for the admin dashboard with filters and offset pagination.

  Supported filters (all optional):
    * `:suspended` (bool) — only suspended / only non-suspended
    * `:is_admin`  (bool) — only admins / only non-admins
    * `:username`  (string) — case-insensitive prefix match

  Pagination: `%{offset: non_neg_integer, limit: pos_integer}`.

  Returns `{:ok, {accounts, total_count}}`. The total is the count that
  would match the filters without the offset/limit, so the caller can
  compute `total_pages`.
  """
  @spec list_accounts(map(), %{offset: non_neg_integer(), limit: pos_integer()}) ::
          {:ok, {[Account.t()], non_neg_integer()}}
  def list_accounts(filter, %{offset: offset, limit: limit})
      when is_map(filter) and is_integer(offset) and is_integer(limit) do
    base = filter_accounts(Account, filter)

    total = Repo.aggregate(base, :count, :id)

    accounts =
      base
      |> order_by([a], desc: a.id)
      |> offset(^offset)
      |> limit(^limit)
      |> Repo.all()

    {:ok, {accounts, total}}
  end

  defp filter_accounts(query, filter) do
    Enum.reduce(filter, query, fn
      {:suspended, true}, q ->
        from(a in q, where: not is_nil(a.suspended_at))

      {:suspended, false}, q ->
        from(a in q, where: is_nil(a.suspended_at))

      {:is_admin, true}, q ->
        from(a in q, where: a.is_admin == true)

      {:is_admin, false}, q ->
        from(a in q, where: a.is_admin == false)

      {:username, <<_, _::binary>> = prefix}, q ->
        like = String.downcase(prefix) <> "%"
        from(a in q, where: like(fragment("lower(?)", a.username), ^like))

      _, q ->
        q
    end)
  end

  @doc """
  Toggle an account's `is_admin` flag. Emits
  `sns.outbox.admin.role_changed` so operator tooling and caches can react.
  `by_id` is the admin performing the change (recorded in the event payload).
  """
  @spec set_admin(integer(), integer(), boolean()) ::
          {:ok, Account.t()} | {:error, :not_found}
  def set_admin(account_id, by_id, flag)
      when is_integer(account_id) and is_integer(by_id) and is_boolean(flag) do
    case Repo.get(Account, account_id) do
      nil ->
        {:error, :not_found}

      %Account{} = account ->
        Multi.new()
        |> Multi.update(:account, Ecto.Changeset.change(account, %{is_admin: flag}))
        |> Multi.insert(
          :audit,
          fn %{account: a} ->
            SukhiFedi.Schema.AdminAudit.changeset(%{
              action: "role_changed",
              admin_account_id: by_id,
              target_account_id: a.id,
              metadata: %{is_admin: a.is_admin}
            })
          end
        )
        |> Outbox.enqueue_multi(
          :outbox_event,
          "sns.outbox.admin.role_changed",
          "account",
          & &1.account.id,
          fn %{account: a} ->
            %{account_id: a.id, by_id: by_id, is_admin: a.is_admin}
          end
        )
        |> Repo.transaction()
        |> case do
          {:ok, %{account: a}} -> {:ok, a}
          {:error, _step, reason, _} -> {:error, reason}
        end
    end
  end

  # ── statuses by account ──────────────────────────────────────────────────

  @doc """
  List notes by an account, with Mastodon pagination opts and filters.

  Opts (all optional):
    * `:max_id`, `:since_id`, `:min_id`, `:limit`
    * `:exclude_replies` — drop notes with `in_reply_to_ap_id`
    * `:exclude_reblogs` — drop the account's boosts (which are otherwise
      interleaved as reblog rows, the same shape the home feed uses)
    * `:only_media` — keep only notes with at least one attached Media
      (boosts are not surfaced on the media tab)

  Returns the page as a list (newest first).
  """
  @spec list_statuses(integer(), keyword() | map()) :: [Note.t()]
  def list_statuses(account_id, opts \\ []) do
    opts = normalize_opts(opts)
    viewer_id = Map.get(opts, :viewer_id)

    base =
      if Map.get(opts, :pinned, false) do
        # ピン留め（featured collection）。id カーソルではなく position 順の
        # 固定の並び。Mastodon クライアントはプロフィール先頭にこれを出す。
        from(n in Note,
          join: p in SukhiFedi.Schema.PinnedNote,
          on: p.note_id == n.id and p.account_id == ^account_id,
          where: n.account_id == ^account_id,
          order_by: [asc: p.position, asc: p.created_at]
        )
      else
        from(n in Note,
          where: n.account_id == ^account_id,
          order_by: [desc: n.id]
        )
      end

    # Per-note visibility, applied in SQL so pagination counts only the
    # statuses this viewer is allowed to see (followers-only/direct never
    # leak to strangers). Single source of truth: SukhiFedi.Notes.
    base = SukhiFedi.Notes.scope_profile_statuses(base, account_id, viewer_id)

    query =
      Enum.reduce(opts, base, fn
        {:max_id, v}, q when not is_nil(v) -> from(n in q, where: n.id < ^v)
        {:since_id, v}, q when not is_nil(v) -> from(n in q, where: n.id > ^v)
        {:min_id, v}, q when not is_nil(v) -> from(n in q, where: n.id > ^v)
        {:exclude_replies, true}, q -> from(n in q, where: is_nil(n.in_reply_to_ap_id))
        {:only_articles, true}, q -> from(n in q, where: not is_nil(n.title))
        _, q -> q
      end)

    limit = Map.get(opts, :limit, 20)

    notes =
      query
      |> limit(^limit)
      |> Repo.all()
      |> Repo.preload([:account, :media, :tags])
      |> SukhiFedi.Notes.with_refs()

    cond do
      # Media tab: own media only, no boosts (matches Mastodon).
      Map.get(opts, :only_media, false) ->
        Enum.filter(notes, fn n -> length(n.media || []) > 0 end)

      # Pinned (position order), reblog-excluded, and the Articles tab stay
      # notes-only — no boost interleave.
      Map.get(opts, :pinned, false) or Map.get(opts, :exclude_reblogs, false) or
          Map.get(opts, :only_articles, false) ->
        notes

      # Default profile feed: interleave the account's boosts as reblog rows,
      # sharing one time-sortable id space with notes so id paging holds.
      true ->
        boosts = SukhiFedi.Timelines.account_boosts(account_id, opts, limit, viewer_id)

        (notes ++ boosts)
        |> Enum.sort_by(& &1.id, :desc)
        |> Enum.take(limit)
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  @counts_table :sukhi_fedi_account_counts
  @counts_ttl_ms 60_000

  defp cache_get(key) do
    ensure_table()

    case :ets.lookup(@counts_table, key) do
      [{^key, value, expires_at}] ->
        if System.monotonic_time(:millisecond) < expires_at,
          do: {:ok, value},
          else: :miss

      [] ->
        :miss
    end
  end

  defp cache_put(key, value) do
    ensure_table()
    expires_at = System.monotonic_time(:millisecond) + @counts_ttl_ms
    :ets.insert(@counts_table, {key, value, expires_at})
    value
  end

  defp cache_invalidate(key) do
    ensure_table()
    :ets.delete(@counts_table, key)
  end

  defp ensure_table do
    case :ets.whereis(@counts_table) do
      :undefined ->
        :ets.new(@counts_table, [:set, :public, :named_table, read_concurrency: true])

      _ref ->
        :ok
    end
  rescue
    ArgumentError -> :ok
  end

  defp local_actor_uri(account_id) do
    case Repo.get(Account, account_id) do
      nil ->
        nil

      %Account{username: u} ->
        domain = SukhiFedi.Config.domain!()
        "https://#{domain}/users/#{u}"
    end
  end

  defp normalize_opts(opts) when is_list(opts), do: Map.new(opts)
  defp normalize_opts(opts) when is_map(opts), do: opts
end
