# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Fedi.DeliverySuspension.Admin do
  @moduledoc """
  What an admin may do about the rests other servers have asked of us
  (FEP-f799, docs/DELIVERY_SUSPENSION.md): choose, on this server only, to
  **ignore** one, and to stop ignoring it.

  Ignoring changes nothing in the peer's record. The notice stays in the store
  exactly as received; its `id` is added to `suspension_ignores`, and the
  cache (the one place the delivery worker asks) leaves it out. So deliveries
  to that target go out as usual at once, a later revision of the same notice
  stays ignored, and a new rest from the peer is a new `id` and is judged on
  its own. Un-ignoring puts it back for as long as it still has to run.

  Each choice is written to the admin audit trail (`suspension_ignored` /
  `suspension_unignored`) and announced to telemetry
  (`[:sukhi_fedi, :delivery_suspension, :ignored]`).

  `list/1` is what the admin screen reads: one row per notice, as plain data.
  What a peer wrote in it is treated like any other remote text: `summary` goes
  through `SukhiFedi.HTML.sanitize/1` (the one scrubber), and `url` is passed
  on only if it is an `https` address, as text. **Nothing here fetches a `url`**.
  """

  alias SukhiFedi.AccountRepo
  alias SukhiFedi.Fedi.DeliverySuspension.{Control, Store, Upkeep}
  alias SukhiFedi.Schema.AdminAudit
  alias SukhiShared.DeliverySuspension.{Cache, Gate, Notice, Policy}

  @type row :: %{
          id: String.t(),
          controller: String.t(),
          target_kind: :inbox | :origin,
          target: String.t(),
          revision: non_neg_integer(),
          status: :active | :cancelled,
          published: DateTime.t(),
          effective_start: DateTime.t() | nil,
          effective_end: DateTime.t() | nil,
          in_effect: boolean(),
          ignored: boolean(),
          ignored_at: DateTime.t() | nil,
          summary: String.t() | nil,
          url: String.t() | nil,
          evidence: map() | nil,
          held: non_neg_integer()
        }

  @doc """
  Every notice we hold, newest rest first: those in effect, then the others by
  how late they end. `held` is how many deliveries the notice's controller
  has held back right now (what the delivery worker counted; zero when the
  delivery side is not in this VM).
  """
  @spec list(DateTime.t(), Policy.t()) :: {:ok, [row()]} | {:error, term()}
  def list(now \\ DateTime.utc_now(), policy \\ Policy.default()) do
    with {:ok, notices} <- Store.all_notices(),
         {:ok, ignored} <- Store.ignored() do
      evidence = Store.all_evidence()
      held = Cache.held_counts()

      rows =
        notices
        |> Enum.map(&row(&1, now, policy, ignored, evidence, held))
        |> Enum.sort_by(&{not &1.in_effect, -sort_key(&1.effective_end)})

      {:ok, rows}
    end
  end

  defp row(%Notice{} = n, now, policy, ignored, evidence, held) do
    finish = if n.effective_start, do: Gate.effective_end(n, policy)
    ignored_at = Map.get(ignored, n.id)

    %{
      id: n.id,
      controller: n.controller,
      target_kind: n.target_kind,
      target: n.target,
      revision: n.revision,
      status: n.status,
      published: n.published,
      effective_start: n.effective_start,
      effective_end: finish,
      in_effect: ignored_at == nil and in_effect?(n, finish, now),
      ignored: ignored_at != nil,
      ignored_at: ignored_at,
      summary: safe_summary(n.summary),
      url: https_only(n.url),
      evidence: latest_evidence(n, evidence),
      held: Map.get(held, n.controller, 0)
    }
  end

  defp in_effect?(%Notice{status: :active, accepted_at: %DateTime{}, effective_start: %DateTime{} = start}, finish, now),
    do: DateTime.compare(start, now) != :gt and DateTime.compare(now, finish) == :lt

  defp in_effect?(_notice, _finish, _now), do: false

  defp sort_key(nil), do: 0
  defp sort_key(%DateTime{} = at), do: DateTime.to_unix(at)

  # The most recent attempt among the kinds this target is checked as.
  defp latest_evidence(%Notice{} = n, evidence) do
    n
    |> Control.kinds()
    |> Enum.map(&Map.get(evidence, {&1, n.target, n.controller}))
    |> Enum.reject(&is_nil/1)
    |> Enum.max_by(&sort_key(&1.attempted_at), fn -> nil end)
  end

  # Remote text, like any other: through the one scrubber. If it cannot run,
  # the text is escaped, never passed through raw.
  defp safe_summary(nil), do: nil

  defp safe_summary(text) when is_binary(text) do
    case SukhiFedi.HTML.sanitize(text) do
      html when is_binary(html) -> html
      _ -> SukhiFedi.HTML.escape(text)
    end
  rescue
    _ -> SukhiFedi.HTML.escape(text)
  end

  defp https_only(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host} when is_binary(host) and host != "" -> url
      _ -> nil
    end
  end

  defp https_only(_), do: nil

  @doc "Ignore the notice `id` (the admin is `admin_id`, for the audit trail)."
  @spec ignore(String.t(), integer() | nil) :: :ok | {:error, :not_found | term()}
  def ignore(id, admin_id \\ nil), do: choose(:ignore, id, admin_id)

  @doc "Stop ignoring the notice `id`."
  @spec unignore(String.t(), integer() | nil) :: :ok | {:error, :not_found | term()}
  def unignore(id, admin_id \\ nil), do: choose(:unignore, id, admin_id)

  defp choose(action, id, admin_id) when is_binary(id) do
    with {:ok, notice, _create_id} <- known(id),
         :ok <- write(action, id),
         :ok <- Upkeep.reload() do
      audit(action, notice, admin_id)

      :telemetry.execute(
        [:sukhi_fedi, :delivery_suspension, :ignored],
        %{count: 1},
        %{action: action}
      )

      :ok
    end
  end

  defp choose(_action, _id, _admin_id), do: {:error, :not_found}

  defp known(id) do
    case Store.get_notice(id) do
      {:ok, _notice, _create_id} = found -> found
      :none -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  defp write(:ignore, id), do: Store.ignore(id, DateTime.utc_now())
  defp write(:unignore, id), do: Store.unignore(id)

  defp audit(action, notice, admin_id) do
    AccountRepo.insert(
      AdminAudit.changeset(%{
        action: "suspension_#{action}d",
        admin_account_id: admin_id,
        target_domain: host(notice.target),
        metadata: %{"notice_id" => notice.id, "controller" => notice.controller}
      })
    )

    :ok
  rescue
    # The choice has been made; a trail that cannot be written is not a reason to undo it.
    _ -> :ok
  end

  defp host(target) do
    case URI.parse(target) do
      %URI{host: host} when is_binary(host) -> host
      _ -> nil
    end
  end
end
