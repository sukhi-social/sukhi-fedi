# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Addons.Moderation do
  @moduledoc """
  Moderation addon — mutes, blocks, reports, instance blocks, account
  suspension. Pure Ecto context; no supervision children.

  Admin-visible mutations (suspend/unsuspend, resolve_report,
  block/unblock instance, set_admin via `SukhiFedi.Accounts`) emit
  `sns.outbox.admin.*` events via the transactional outbox. That event
  stream doubles as the audit trail until a queryable `admin_audits`
  table is introduced.
  """

  use SukhiFedi.Addon, id: :moderation

  import Ecto.Query
  alias Ecto.Multi
  alias SukhiFedi.{Outbox, Repo}
  alias SukhiFedi.Schema.{Mute, Block, Report, InstanceBlock, BubbleInstance, Account, AdminAudit}

  # ── user-level mutes / blocks (no admin outbox) ──────────────────────────

  def mute(account_id, target_id, expires_at \\ nil) do
    %Mute{account_id: account_id, target_id: target_id, expires_at: expires_at}
    |> Repo.insert(on_conflict: :nothing)
  end

  def unmute(account_id, target_id) do
    Repo.delete_all(from m in Mute, where: m.account_id == ^account_id and m.target_id == ^target_id)
  end

  def muted?(account_id, target_id) do
    Repo.exists?(
      from m in Mute,
        where:
          m.account_id == ^account_id and m.target_id == ^target_id and
            (is_nil(m.expires_at) or m.expires_at > ^DateTime.utc_now())
    )
  end

  def block(account_id, target_id) do
    %Block{account_id: account_id, target_id: target_id}
    |> Repo.insert(on_conflict: :nothing)
  end

  def unblock(account_id, target_id) do
    Repo.delete_all(from b in Block, where: b.account_id == ^account_id and b.target_id == ^target_id)
  end

  def blocked?(account_id, target_id) do
    Repo.exists?(from b in Block, where: b.account_id == ^account_id and b.target_id == ^target_id)
  end

  @doc "Account ids that `account_id` has blocked."
  def blocked_target_ids(account_id) when is_integer(account_id) do
    Repo.all(from b in Block, where: b.account_id == ^account_id, select: b.target_id)
  end

  @doc "Account ids that `account_id` is currently muting (skips expired)."
  def muted_target_ids(account_id) when is_integer(account_id) do
    now = DateTime.utc_now()

    Repo.all(
      from m in Mute,
        where:
          m.account_id == ^account_id and (is_nil(m.expires_at) or m.expires_at > ^now),
        select: m.target_id
    )
  end

  @doc """
  Account ids whose content a viewer should never see — everyone they've
  blocked or muted. This is the one place that says "hidden from a viewer";
  timelines hide both these authors' own notes and their notes surfaced by
  someone else's boost. `nil` (an anonymous viewer) hides no one.
  """
  def hidden_author_ids(nil), do: []

  def hidden_author_ids(account_id) when is_integer(account_id) do
    # One round trip for both sets (blocks ∪ live mutes), not two.
    now = DateTime.utc_now()

    blocks = from b in Block, where: b.account_id == ^account_id, select: b.target_id

    Repo.all(
      from m in Mute,
        where: m.account_id == ^account_id and (is_nil(m.expires_at) or m.expires_at > ^now),
        select: m.target_id,
        union: ^blocks
    )
  end

  @doc "Subset of `target_ids` that have blocked `account_id` (reverse blocks)."
  def blocked_by_ids(account_id, target_ids) when is_integer(account_id) and is_list(target_ids) do
    Repo.all(
      from b in Block,
        where: b.target_id == ^account_id and b.account_id in ^target_ids,
        select: b.account_id
    )
  end

  @doc "Hydrated list of accounts the viewer has blocked. Public-safe fields only."
  def list_blocks(account_id) when is_integer(account_id) do
    Repo.all(
      from b in Block,
        join: a in Account,
        on: a.id == b.target_id,
        where: b.account_id == ^account_id,
        select: %{
          id: a.id,
          username: a.username,
          display_name: a.display_name,
          summary: a.summary,
          domain: a.domain,
          actor_uri: a.actor_uri,
          avatar_url: a.avatar_url,
          banner_url: a.banner_url
        }
    )
  end

  @doc "Hydrated list of accounts the viewer has muted (skips expired entries)."
  def list_mutes(account_id) when is_integer(account_id) do
    now = DateTime.utc_now()

    Repo.all(
      from m in Mute,
        join: a in Account,
        on: a.id == m.target_id,
        where:
          m.account_id == ^account_id and
            (is_nil(m.expires_at) or m.expires_at > ^now),
        select: %{
          id: a.id,
          username: a.username,
          display_name: a.display_name,
          summary: a.summary,
          domain: a.domain,
          actor_uri: a.actor_uri,
          avatar_url: a.avatar_url,
          banner_url: a.banner_url
        }
    )
  end

  # ── reports ──────────────────────────────────────────────────────────────

  def create_report(attrs) do
    %Report{}
    |> Ecto.Changeset.cast(attrs, [:account_id, :target_id, :note_id, :comment])
    |> Ecto.Changeset.validate_required([:target_id])
    |> Ecto.Changeset.put_change(:status, "open")
    |> Repo.insert()
  end

  @spec get_report(integer() | binary()) ::
          {:ok, Report.t()} | {:error, :not_found}
  def get_report(id) do
    case coerce_id(id) && Repo.get(Report, coerce_id(id)) do
      nil -> {:error, :not_found}
      %Report{} = report -> {:ok, Repo.preload(report, [:account, :target, :note, :resolved_by])}
    end
  end

  @doc """
  List reports filtered by status with offset pagination. Returns
  `{:ok, {reports, total}}`. Reports are preloaded with `account`
  (reporter), `target`, `note`, and `resolved_by`.
  """
  @spec list_reports(String.t(), %{offset: non_neg_integer(), limit: pos_integer()}) ::
          {:ok, {[Report.t()], non_neg_integer()}}
  def list_reports(status, %{offset: offset, limit: limit})
      when is_binary(status) and is_integer(offset) and is_integer(limit) do
    base = from r in Report, where: r.status == ^status

    total = Repo.aggregate(base, :count, :id)

    reports =
      base
      |> order_by([r], desc: r.inserted_at)
      |> offset(^offset)
      |> limit(^limit)
      |> preload([:account, :target, :note, :resolved_by])
      |> Repo.all()

    {:ok, {reports, total}}
  end

  @spec resolve_report(integer() | binary(), integer()) ::
          {:ok, Report.t()} | {:error, :not_found}
  def resolve_report(report_id, resolved_by_id) when is_integer(resolved_by_id) do
    case coerce_id(report_id) && Repo.get(Report, coerce_id(report_id)) do
      nil ->
        {:error, :not_found}

      %Report{} = report ->
        changeset =
          Ecto.Changeset.change(report, %{
            status: "resolved",
            resolved_at: DateTime.utc_now() |> DateTime.truncate(:second),
            resolved_by_id: resolved_by_id
          })

        Multi.new()
        |> Multi.update(:report, changeset)
        |> Multi.insert(
          :audit,
          fn %{report: r} ->
            AdminAudit.changeset(%{
              action: "report_resolved",
              admin_account_id: resolved_by_id,
              target_account_id: r.target_id,
              metadata: %{report_id: r.id}
            })
          end
        )
        |> Outbox.enqueue_multi(
          :outbox_event,
          "sns.outbox.admin.report_resolved",
          "report",
          & &1.report.id,
          fn %{report: r} ->
            %{report_id: r.id, target_id: r.target_id, by_id: resolved_by_id}
          end
        )
        |> Repo.transaction()
        |> case do
          {:ok, %{report: r}} -> {:ok, r}
          {:error, _, reason, _} -> {:error, reason}
        end
    end
  end

  # ── instance blocks ──────────────────────────────────────────────────────

  @spec block_instance(String.t(), String.t(), String.t() | nil, integer()) ::
          {:ok, InstanceBlock.t()} | {:error, term()}
  def block_instance(domain, severity, reason, created_by_id)
      when is_binary(domain) and is_binary(severity) and is_integer(created_by_id) do
    changeset =
      Ecto.Changeset.cast(
        %InstanceBlock{},
        %{
          domain: domain,
          severity: severity,
          reason: reason,
          created_by_id: created_by_id
        },
        [:domain, :severity, :reason, :created_by_id]
      )
      |> Ecto.Changeset.validate_required([:domain, :severity])

    Multi.new()
    |> Multi.insert(:block, changeset, on_conflict: :nothing, conflict_target: :domain)
    |> Multi.insert(
      :audit,
      AdminAudit.changeset(%{
        action: "instance_blocked",
        admin_account_id: created_by_id,
        target_domain: domain,
        reason: reason,
        metadata: %{severity: severity}
      })
    )
    |> Outbox.enqueue_multi(
      :outbox_event,
      "sns.outbox.admin.instance_blocked",
      "instance_block",
      & &1.block.id,
      fn %{block: b} ->
        %{domain: b.domain, severity: b.severity, reason: b.reason, by_id: created_by_id}
      end
    )
    |> Repo.transaction()
    |> case do
      {:ok, %{block: b}} -> {:ok, b}
      {:error, _, reason, _} -> {:error, reason}
    end
  end

  @spec unblock_instance(String.t(), integer()) ::
          {:ok, %{domain: String.t()}} | {:error, :not_found}
  def unblock_instance(domain, by_id) when is_binary(domain) and is_integer(by_id) do
    case Repo.get_by(InstanceBlock, domain: domain) do
      nil ->
        {:error, :not_found}

      %InstanceBlock{} = block ->
        Multi.new()
        |> Multi.delete(:block, block)
        |> Multi.insert(
          :audit,
          AdminAudit.changeset(%{
            action: "instance_unblocked",
            admin_account_id: by_id,
            target_domain: block.domain
          })
        )
        |> Outbox.enqueue_multi(
          :outbox_event,
          "sns.outbox.admin.instance_unblocked",
          "instance_block",
          & &1.block.id,
          fn %{block: b} -> %{domain: b.domain, by_id: by_id} end
        )
        |> Repo.transaction()
        |> case do
          {:ok, %{block: b}} -> {:ok, %{domain: b.domain}}
          {:error, _, reason, _} -> {:error, reason}
        end
    end
  end

  def instance_blocked?(domain) do
    Repo.exists?(from i in InstanceBlock, where: i.domain == ^domain)
  end

  @doc """
  Inbound federation policy for `host` — the one place that turns a stored
  instance-block severity into a decision. `:reject` drops the activity at
  the door (accept-and-drop, see the inbox gate); `:silence` lets it in but
  keeps its notes off the home/public surfaces (via `silenced_author_ids/0`,
  the same id-subtraction circles use); `:pass` is the default for an
  unblocked host (observe and surface normally).

  Signature and proof checks are crypto-trust, not operator policy, so they
  stay ahead of this in the inbox and are unaffected.
  """
  @spec instance_policy(String.t() | nil) :: :reject | :silence | :pass
  def instance_policy(host) when is_binary(host) do
    case Repo.one(from i in InstanceBlock, where: i.domain == ^host, select: i.severity) do
      "silence" -> :silence
      "suspend" -> :reject
      _ -> :pass
    end
  end

  def instance_policy(_), do: :pass

  @doc """
  Local account ids authored by `:silence`-severity instances. The global
  sibling of `hidden_author_ids/1`: home and public subtract this set so a
  silenced instance's posts are materialized (and federate/archive) but
  never surface, for every viewer including anonymous ones.
  """
  @spec silenced_author_ids() :: [integer()]
  def silenced_author_ids do
    # Same for every viewer and read on every timeline request, so it is
    # kept a few seconds (SukhiFedi.HotCache) — a new silence takes effect
    # within that window.
    SukhiFedi.HotCache.fetch(:silenced_author_ids, SukhiFedi.HotCache.ttl(:moderation_sets), fn ->
      Repo.all(
        from a in Account,
          join: i in InstanceBlock,
          on: i.domain == a.domain,
          where: i.severity == "silence",
          select: a.id
      )
    end)
  end

  @doc """
  List federated domain blocks with offset pagination. Returns
  `{:ok, {blocks, total}}`.
  """
  @spec list_instance_blocks(%{offset: non_neg_integer(), limit: pos_integer()}) ::
          {:ok, {[InstanceBlock.t()], non_neg_integer()}}
  def list_instance_blocks(%{offset: offset, limit: limit})
      when is_integer(offset) and is_integer(limit) do
    base = InstanceBlock
    total = Repo.aggregate(base, :count, :id)

    blocks =
      from(i in base, order_by: [desc: i.inserted_at])
      |> offset(^offset)
      |> limit(^limit)
      |> Repo.all()

    {:ok, {blocks, total}}
  end

  # ── bubble (ご近所) allow-list ────────────────────────────────────────────

  @doc """
  The trusted-instance allow-set behind the bubble (ご近所) timeline — the one
  place that says "which remote hosts are in the neighbourhood". The bubble
  feed (`SukhiFedi.Timelines.bubble/1`) surfaces public posts only from these
  domains; an empty set means an empty bubble (curated, not a firehose). The
  sibling of `silenced_author_ids/0`: that subtracts hosts globally, this
  admits a small chosen set.
  """
  @spec bubble_domains() :: [String.t()]
  def bubble_domains do
    SukhiFedi.HotCache.fetch(:bubble_domains, SukhiFedi.HotCache.ttl(:moderation_sets), fn ->
      Repo.all(from b in BubbleInstance, select: b.domain)
    end)
  end

  @spec add_bubble_instance(String.t(), integer()) ::
          {:ok, BubbleInstance.t()} | {:error, term()}
  def add_bubble_instance(domain, created_by_id)
      when is_binary(domain) and is_integer(created_by_id) do
    changeset =
      Ecto.Changeset.cast(%BubbleInstance{}, %{domain: domain, created_by_id: created_by_id}, [
        :domain,
        :created_by_id
      ])
      |> Ecto.Changeset.validate_required([:domain])

    Multi.new()
    |> Multi.insert(:bubble, changeset, on_conflict: :nothing, conflict_target: :domain)
    |> Multi.insert(
      :audit,
      AdminAudit.changeset(%{
        action: "bubble_instance_added",
        admin_account_id: created_by_id,
        target_domain: domain
      })
    )
    |> Outbox.enqueue_multi(
      :outbox_event,
      "sns.outbox.admin.bubble_instance_added",
      "bubble_instance",
      & &1.bubble.id,
      fn %{bubble: b} -> %{domain: b.domain, by_id: created_by_id} end
    )
    |> Repo.transaction()
    |> case do
      {:ok, %{bubble: b}} -> {:ok, b}
      {:error, _, reason, _} -> {:error, reason}
    end
  end

  @spec remove_bubble_instance(String.t(), integer()) ::
          {:ok, %{domain: String.t()}} | {:error, :not_found}
  def remove_bubble_instance(domain, by_id) when is_binary(domain) and is_integer(by_id) do
    case Repo.get_by(BubbleInstance, domain: domain) do
      nil ->
        {:error, :not_found}

      %BubbleInstance{} = bubble ->
        Multi.new()
        |> Multi.delete(:bubble, bubble)
        |> Multi.insert(
          :audit,
          AdminAudit.changeset(%{
            action: "bubble_instance_removed",
            admin_account_id: by_id,
            target_domain: bubble.domain
          })
        )
        |> Outbox.enqueue_multi(
          :outbox_event,
          "sns.outbox.admin.bubble_instance_removed",
          "bubble_instance",
          & &1.bubble.id,
          fn %{bubble: b} -> %{domain: b.domain, by_id: by_id} end
        )
        |> Repo.transaction()
        |> case do
          {:ok, %{bubble: b}} -> {:ok, %{domain: b.domain}}
          {:error, _, reason, _} -> {:error, reason}
        end
    end
  end

  @doc """
  The bubble allow-list as full rows (domain + when it was added), newest
  first — for the admin page. `bubble_domains/0` stays the lean string-only
  read the timeline hot path uses.
  """
  @spec list_bubble_instances() :: [BubbleInstance.t()]
  def list_bubble_instances do
    Repo.all(from b in BubbleInstance, order_by: [desc: b.id])
  end

  @doc """
  Remote hosts we've already talked to — the distinct domains of the remote
  accounts we've stored. Powers the bubble admin's "pick from a host you
  already federate with" search: `query` is a light case-insensitive
  substring match over the domain (blank → the first `:limit` alphabetically).
  Local accounts (`domain IS NULL`) are excluded by construction.
  """
  @spec known_domains(String.t() | nil, keyword()) :: [String.t()]
  def known_domains(query \\ nil, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    base =
      from a in Account,
        where: not is_nil(a.domain),
        distinct: true,
        select: a.domain,
        order_by: a.domain,
        limit: ^limit

    query
    |> trimmed()
    |> case do
      nil -> base
      q -> from a in base, where: ilike(a.domain, ^("%" <> escape_like(q) <> "%"))
    end
    |> Repo.all()
  end

  defp trimmed(s) when is_binary(s) do
    case String.trim(s) do
      "" -> nil
      v -> v
    end
  end

  defp trimmed(_), do: nil

  # Neutralise LIKE wildcards in user input so a search for "a_b" or "50%"
  # is a literal substring, not a pattern. Backslash is the default LIKE
  # escape character in Postgres — escape it first so we don't double-escape
  # the backslashes we add for % and _.
  defp escape_like(s) do
    s
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  # ── account suspension ───────────────────────────────────────────────────

  @spec suspend_account(integer() | binary(), integer(), String.t() | nil) ::
          {:ok, Account.t()} | {:error, :not_found}
  def suspend_account(account_id, suspended_by_id, reason) when is_integer(suspended_by_id) do
    case coerce_id(account_id) && Repo.get(Account, coerce_id(account_id)) do
      nil ->
        {:error, :not_found}

      %Account{} = account ->
        changeset =
          Ecto.Changeset.change(account, %{
            suspended_at: DateTime.utc_now() |> DateTime.truncate(:second),
            suspended_by_id: suspended_by_id,
            suspension_reason: reason
          })

        Multi.new()
        |> Multi.update(:account, changeset)
        |> Multi.insert(
          :audit,
          fn %{account: a} ->
            AdminAudit.changeset(%{
              action: "account_suspended",
              admin_account_id: suspended_by_id,
              target_account_id: a.id,
              reason: reason
            })
          end
        )
        |> Outbox.enqueue_multi(
          :outbox_event,
          "sns.outbox.admin.account_suspended",
          "account",
          & &1.account.id,
          fn %{account: a} ->
            %{account_id: a.id, by_id: suspended_by_id, reason: reason}
          end
        )
        |> Repo.transaction()
        |> case do
          {:ok, %{account: a}} -> {:ok, a}
          {:error, _, reason, _} -> {:error, reason}
        end
    end
  end

  @spec unsuspend_account(integer() | binary(), integer()) ::
          {:ok, Account.t()} | {:error, :not_found}
  def unsuspend_account(account_id, by_id) when is_integer(by_id) do
    case coerce_id(account_id) && Repo.get(Account, coerce_id(account_id)) do
      nil ->
        {:error, :not_found}

      %Account{} = account ->
        changeset =
          Ecto.Changeset.change(account, %{
            suspended_at: nil,
            suspended_by_id: nil,
            suspension_reason: nil
          })

        Multi.new()
        |> Multi.update(:account, changeset)
        |> Multi.insert(
          :audit,
          fn %{account: a} ->
            AdminAudit.changeset(%{
              action: "account_unsuspended",
              admin_account_id: by_id,
              target_account_id: a.id
            })
          end
        )
        |> Outbox.enqueue_multi(
          :outbox_event,
          "sns.outbox.admin.account_unsuspended",
          "account",
          & &1.account.id,
          fn %{account: a} -> %{account_id: a.id, by_id: by_id} end
        )
        |> Repo.transaction()
        |> case do
          {:ok, %{account: a}} -> {:ok, a}
          {:error, _, reason, _} -> {:error, reason}
        end
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp coerce_id(id), do: SukhiFedi.Coercion.parse_id(id)
end
