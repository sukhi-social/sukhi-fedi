# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.AccountPorter do
  @moduledoc """
  Export / import of an account's own lists — the people it follows, blocks
  and mutes — as the one-column CSV Mastodon uses (`Account address`, one
  `user@domain` per line), so a list can move to or from another server.
  Reachable from the api plugin node via
  `SukhiApi.GatewayRpc.call(SukhiFedi.AccountPorter, :fun, [args])`.

    * **export** — one query per kind, rendered as CSV. Following is the
      accepted follows only; mutes skip expired entries.

    * **import** — parsed once at the edge (`parse/1`: size and row caps,
      format check), then resolved in batch: two queries cover every
      address this server already knows. Only the rest go out over
      WebFinger (`Accounts.lookup_by_acct/2`, at most `@max_resolve`
      per import, ten at a time); whatever is still unknown is reported
      back as `unresolved` rather than failing the run. Applying goes
      through the same functions the single-account API uses
      (`Social.request_follow/2`, `Moderation.block/2`, `Moderation.mute/2`),
      so follow requests federate and idempotency stay in one place.

  Importing follows is "merge": nothing already followed, blocked or muted
  is removed.
  """

  import Ecto.Query

  alias SukhiFedi.{Accounts, Repo, Social}
  alias SukhiFedi.Addons.Moderation
  alias SukhiFedi.Schema.{Account, Block, Follow, Mute}

  @type kind :: :following | :blocks | :mutes

  @kinds [:following, :blocks, :mutes]
  @header "Account address"
  @max_rows 1_000
  @max_bytes 256 * 1024
  @max_resolve 200
  @max_unresolved_report 20
  # One follow every 100 ms ≈ 10 a second: 1000 rows in under two minutes.
  @follow_interval_ms 100

  @address ~r/\A[A-Za-z0-9_.\-]{1,64}(@[A-Za-z0-9.\-]{1,253})?\z/

  # ── export ──────────────────────────────────────────────────────────────

  @spec export(integer(), kind()) :: {:ok, binary()} | {:error, :not_found}
  def export(account_id, kind) when is_integer(account_id) and kind in @kinds do
    case Repo.get(Account, account_id) do
      nil ->
        {:error, :not_found}

      %Account{} = account ->
        local = SukhiFedi.Config.domain!()

        lines =
          account
          |> targets(kind)
          |> Repo.all()
          |> Enum.map(fn {username, domain} -> "#{username}@#{domain || local}" end)
          # A remote actor picks its own username; only lines `parse/1` would
          # accept leave, so a name like `=HYPERLINK(...)` never reaches a
          # spreadsheet and every exported line imports back.
          |> Enum.filter(&Regex.match?(@address, &1))
          |> Enum.sort()

        {:ok, Enum.join([@header | lines], "\r\n") <> "\r\n"}
    end
  end

  defp targets(%Account{username: username}, :following) do
    uri = "https://#{SukhiFedi.Config.domain!()}/users/#{username}"

    from(f in Follow,
      join: a in Account,
      on: a.id == f.followee_id,
      where: f.follower_uri == ^uri and f.state == "accepted",
      select: {a.username, a.domain}
    )
  end

  defp targets(%Account{id: id}, :blocks) do
    from(b in Block,
      join: a in Account,
      on: a.id == b.target_id,
      where: b.account_id == ^id,
      select: {a.username, a.domain}
    )
  end

  defp targets(%Account{id: id}, :mutes) do
    now = DateTime.utc_now()

    from(m in Mute,
      join: a in Account,
      on: a.id == m.target_id,
      where: m.account_id == ^id and (is_nil(m.expires_at) or m.expires_at > ^now),
      select: {a.username, a.domain}
    )
  end

  # ── import ──────────────────────────────────────────────────────────────

  @doc """
  Apply the CSV `csv` to `account_id`'s `kind` list.

  Blocks and mutes are local writes — they are done before this returns, with
  counts and (a sample of) the addresses that could not be resolved. Follows
  each federate a `Follow`, so they are **paced** and run in the background
  (`follow_paced/4`): this returns at once with `queued` set to how many rows
  were accepted, and the follows go out at a steady `@follow_interval_ms`
  — not a burst that reads as spam to the other servers, not a crawl.
  """
  @spec import_csv(integer(), kind(), binary()) ::
          {:ok,
           %{
             imported: non_neg_integer(),
             skipped: non_neg_integer(),
             unresolved: [String.t()],
             queued: non_neg_integer()
           }}
          | {:error, :not_found | :too_large | :too_many}
  def import_csv(account_id, kind, csv)
      when is_integer(account_id) and kind in @kinds and is_binary(csv) do
    with %Account{} = account <- Repo.get(Account, account_id),
         {:ok, addresses, invalid} <- parse(csv) do
      {known, missing} = resolve_known(addresses)
      run_import(account, kind, known, missing, invalid)
    else
      nil -> {:error, :not_found}
      {:error, _} = e -> e
    end
  end

  defp run_import(%Account{} = account, :following, known, missing, invalid) do
    {:ok, _pid} =
      Task.Supervisor.start_child(SukhiFedi.AccountPorter.TaskSup, fn ->
        follow_paced(account, known, missing)
      end)

    {:ok, %{imported: 0, skipped: invalid, unresolved: [], queued: length(known) + length(missing)}}
  end

  defp run_import(%Account{} = account, kind, known, missing, invalid) when kind in [:blocks, :mutes] do
    {fetched, unresolved} = resolve_remote(missing)
    targets = importable(account, known ++ fetched)
    imported = Enum.count(targets, &apply_one(account, kind, &1))

    {:ok,
     %{
       imported: imported,
       skipped: invalid + length(unresolved) + (length(known) + length(fetched) - imported),
       unresolved: Enum.take(unresolved, @max_unresolved_report),
       queued: 0
     }}
  end

  @doc """
  The background half of a follow import: look up what this server does not
  know yet, then follow one account every `interval_ms`. Public so a test can
  run it in its own process; callers go through `import_csv/3`.
  """
  @spec follow_paced(Account.t(), [Account.t()], [String.t()], non_neg_integer()) ::
          non_neg_integer()
  def follow_paced(%Account{} = account, known, missing, interval_ms \\ @follow_interval_ms) do
    {fetched, _unresolved} = resolve_remote(missing)

    account
    |> importable(known ++ fetched)
    |> Enum.reduce(0, fn target, followed ->
      done? = apply_one(account, :following, target)
      Process.sleep(interval_ms)
      if done?, do: followed + 1, else: followed
    end)
  end

  defp importable(%Account{id: own_id}, accounts) do
    accounts
    |> Enum.uniq_by(& &1.id)
    |> Enum.reject(&(&1.id == own_id))
  end

  @doc """
  The one place that reads untrusted CSV: size and row caps, the optional
  header and BOM, the first column only, a strict address shape. Returns the
  distinct valid addresses and how many rows were malformed.
  """
  @spec parse(binary()) :: {:ok, [String.t()], non_neg_integer()} | {:error, :too_large | :too_many}
  def parse(csv) when is_binary(csv) and byte_size(csv) > @max_bytes, do: {:error, :too_large}

  def parse(csv) when is_binary(csv) do
    cells =
      csv
      |> String.trim_leading("﻿")
      |> String.split(~r/\r\n|\n|\r/, trim: true)
      |> Enum.map(&first_cell/1)
      |> Enum.reject(&(&1 == "" or String.downcase(&1) == String.downcase(@header)))

    {valid, invalid} = Enum.split_with(cells, &Regex.match?(@address, &1))

    case length(cells) > @max_rows do
      true -> {:error, :too_many}
      false -> {:ok, Enum.uniq_by(valid, &String.downcase/1), length(invalid)}
    end
  end

  defp first_cell(line) do
    line
    |> String.split(",", parts: 2)
    |> hd()
    |> String.trim()
    |> String.trim("\"")
    |> String.trim_leading("@")
  end

  # `{username, nil}` for a local address, `{username, "host"}` otherwise.
  defp split_address(address, local_domain) do
    case String.split(address, "@", parts: 2) do
      [username] ->
        {username, nil}

      [username, host] ->
        case String.downcase(host) do
          ^local_domain -> {username, nil}
          lowered -> {username, lowered}
        end
    end
  end

  # Two queries answer every address this server already has: the local
  # usernames, and the remote (username, host) pairs.
  defp resolve_known(addresses) do
    local_domain = String.downcase(SukhiFedi.Config.domain!())
    parsed = Enum.map(addresses, &{&1, split_address(&1, local_domain)})

    usernames = for {_, {u, nil}} <- parsed, do: u
    remotes = for {_, {u, h}} <- parsed, is_binary(h), do: {u, h}

    local_by =
      case usernames do
        [] ->
          %{}

        _ ->
          from(a in Account,
            where: is_nil(a.domain) and is_nil(a.deleted_at) and a.username in ^usernames
          )
          |> Repo.all()
          |> Map.new(&{&1.username, &1})
      end

    remote_by =
      case remotes do
        [] ->
          %{}

        _ ->
          names = remotes |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
          hosts = remotes |> Enum.map(&elem(&1, 1)) |> Enum.uniq()

          from(a in Account,
            where:
              not is_nil(a.domain) and is_nil(a.deleted_at) and a.username in ^names and
                a.domain in ^hosts
          )
          |> Repo.all()
          |> Map.new(&{{&1.username, String.downcase(&1.domain)}, &1})
      end

    {found, missing} =
      Enum.reduce(parsed, {[], []}, fn {address, {username, host}}, {found, missing} ->
        hit = if is_nil(host), do: Map.get(local_by, username), else: Map.get(remote_by, {username, host})

        case hit do
          %Account{} = a -> {[a | found], missing}
          nil -> {found, [address | missing]}
        end
      end)

    {Enum.reverse(found), Enum.reverse(missing)}
  end

  # The rest go out over WebFinger — capped, and a few at a time, so one big
  # list can neither stall the call nor fan out without bound.
  defp resolve_remote(missing) do
    {try_now, over_cap} = Enum.split(missing, @max_resolve)

    results =
      Task.async_stream(
        try_now,
        fn address -> {address, Accounts.lookup_by_acct(address, resolve: true)} end,
        max_concurrency: 10,
        timeout: 15_000,
        on_timeout: :kill_task,
        ordered: true
      )
      |> Enum.zip(try_now)

    {fetched, failed} =
      Enum.reduce(results, {[], []}, fn
        {{:ok, {_address, {:ok, %Account{} = a}}}, _}, {fetched, failed} -> {[a | fetched], failed}
        {_other, address}, {fetched, failed} -> {fetched, [address | failed]}
      end)

    {Enum.reverse(fetched), Enum.reverse(failed) ++ over_cap}
  end

  defp apply_one(%Account{} = account, :following, %Account{id: id}),
    do: match?({:ok, _}, Social.request_follow(account, id))

  defp apply_one(%Account{id: account_id}, :blocks, %Account{id: id}),
    do: match?({:ok, _}, Moderation.block(account_id, id))

  defp apply_one(%Account{id: account_id}, :mutes, %Account{id: id}),
    do: match?({:ok, _}, Moderation.mute(account_id, id))
end
