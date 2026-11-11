# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiDelivery.Delivery.Announce do
  @moduledoc """
  FEP-f799, the telling side (docs/DELIVERY_SUSPENSION.md): send one
  pre-signed public activity — the `Create` that carries the notice when the
  resting starts, the `Undo` when it ends — to the peers, a little at a time.

  The activity is sent **as it is**: the same bytes for every peer (no peer list
  rides in it), signed ahead of the work by `Publisher`. What changes per peer
  is only the HTTP signature the delivery worker adds, as for any activity.

  The spread:

    * `SukhiShared.DeliverySuspension.Spread` gives each peer a time: random
      order, one slot each, so at most `per_second + 1` start in any second;
    * each becomes an ordinary `Delivery.Worker` job scheduled for that time,
      so the retries, the backoff and the `delivery` queue's worker count —
      the ceiling on how many run at once — are the usual ones. A
      `DeliverySuspension` activity is never itself held by a notice
      (`Gate.exempt?/1`), so telling a resting peer is not put off.

  `peers/0` is the default audience: one inbox per remote host we already
  deliver to (the followers of our accounts and the accounts they follow).
  `run/2` takes `:inboxes` to say otherwise.
  """

  import Ecto.Query

  alias SukhiDelivery.Delivery.Worker
  alias SukhiDelivery.Outbox.Recipients
  alias SukhiDelivery.Schema.Account
  alias SukhiShared.DeliverySuspension.Spread

  @doc """
  Send `activity` (a map, already signed) to the peers. Options:

    * `:inboxes` — the audience; default `peers/0`
    * `:now` — a `DateTime` (default now)
    * `:per_second` — the rate ceiling (default 5)

  Returns `{:ok, %{count: n, ends_in_ms: ms}}`: how many jobs, and how long
  until the last one starts.
  """
  @spec run(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(activity, opts \\ [])

  def run(%{"id" => id, "actor" => actor} = activity, opts)
      when is_binary(id) and is_binary(actor) do
    inboxes = Keyword.get_lazy(opts, :inboxes, &peers/0)
    plan = Spread.schedule(inboxes, Keyword.take(opts, [:per_second]))
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    case jobs(activity, plan, now) do
      [] ->
        {:ok, %{count: 0, ends_in_ms: 0}}

      changesets ->
        SukhiDelivery.Queue.insert_all(changesets)
        {:ok, %{count: length(changesets), ends_in_ms: Spread.duration(plan)}}
    end
  end

  def run(_activity, _opts), do: {:error, :not_an_activity}

  @doc "The delivery jobs for `plan` (`Spread.schedule/2`'s answer), not yet inserted."
  @spec jobs(map(), [{String.t(), non_neg_integer()}], DateTime.t()) :: [Ecto.Changeset.t()]
  def jobs(%{"id" => id, "actor" => actor} = activity, plan, %DateTime{} = now) do
    for {inbox, delay_ms} <- plan do
      Worker.new(
        %{raw_json: activity, actor_uri: actor, activity_id: id, inbox_url: inbox},
        scheduled_at: DateTime.add(now, delay_ms, :millisecond)
      )
    end
  end

  @doc """
  One inbox per remote host we already exchange activities with: the inboxes
  of the remote followers of our accounts, and of the remote accounts they
  follow. Our own host is left out. Reading the audience asks the usual
  actor lookups, so this is for an operator's command, not a request.
  """
  @spec peers() :: [String.t()]
  def peers do
    own = SukhiDelivery.Config.domain!() |> String.downcase()

    from(a in Account, where: is_nil(a.domain), select: a)
    |> SukhiDelivery.Repo.all()
    |> Enum.flat_map(fn account ->
      uri = Recipients.local_actor_uri(account)
      Recipients.followers_inboxes(uri) ++ Recipients.followed_inboxes(uri)
    end)
    |> one_per_host(own)
  end

  @doc "Keep the first inbox of each host, and none of `own`."
  @spec one_per_host([String.t()], String.t()) :: [String.t()]
  def one_per_host(inboxes, own) do
    inboxes
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(&host/1)
    |> Enum.reject(&(host(&1) in [nil, own]))
  end

  defp host(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) -> String.downcase(host)
      _ -> nil
    end
  end
end
