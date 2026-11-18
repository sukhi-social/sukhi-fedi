# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.AP.Instructions.Memberships do
  @moduledoc """
  A group's answer to the `Join` we sent (`Social.join_group/2`).

  `Accept` turns the pending membership into an accepted one; `Reject`
  deletes it, so the person is simply not a member. Only the group the
  `Join` was addressed to can answer it: the answer's `actor` must be the
  group account the membership row points at, whichever way the Join is
  named in the answer —

    * embedded: `Accept{object: Join{actor, object}}` (Mastodon-family
      habit, and what Bonfire's `activity_pub` library builds);
    * by id: `Accept{object: "https://<us>/joins/<id>"}`, the id we gave
      the Join (`SukhiDelivery.Outbox.Handlers.Social.join/2`).
  """

  import Ecto.Query

  alias SukhiFedi.AP.Instructions.Extract
  alias SukhiFedi.Repo
  alias SukhiFedi.Schema.{Account, GroupMembership}

  @spec maybe_handle_join_reply(map()) :: :ok
  def maybe_handle_join_reply(%{"type" => type, "actor" => actor, "object" => joined})
      when type in ["Accept", "Reject"] do
    with group_uri when is_binary(group_uri) <- Extract.extract_uri(actor),
         %GroupMembership{} = membership <- membership_for(joined, group_uri) do
      settle(type, membership)
    end

    :ok
  end

  def maybe_handle_join_reply(_), do: :ok

  defp settle("Accept", %GroupMembership{} = m) do
    m |> GroupMembership.changeset(%{state: "accepted"}) |> Repo.update()
  end

  defp settle("Reject", %GroupMembership{} = m), do: Repo.delete(m)

  # Embedded Join: its actor is the member, its object must be the group
  # that is answering.
  defp membership_for(%{"type" => "Join"} = join, group_uri) do
    with member_uri when is_binary(member_uri) <- Extract.extract_uri(join["actor"]),
         ^group_uri <- Extract.extract_uri(join["object"]) do
      group_uri
      |> asked()
      |> where([m], m.member_uri == ^member_uri)
      |> Repo.one()
    else
      _ -> nil
    end
  end

  # Join named by the id we gave it.
  defp membership_for(join_id, group_uri) when is_binary(join_id) do
    prefix = "https://#{SukhiFedi.Config.domain!()}/joins/"

    with true <- String.starts_with?(join_id, prefix),
         {id, ""} <- join_id |> String.replace_prefix(prefix, "") |> Integer.parse() do
      group_uri
      |> asked()
      |> where([m], m.id == ^id)
      |> Repo.one()
    else
      _ -> nil
    end
  end

  defp membership_for(_, _), do: nil

  # The one place that says who may answer: a membership is only ever found
  # through the group account it was addressed to.
  defp asked(group_uri) do
    from(m in GroupMembership,
      join: g in Account,
      on: g.id == m.group_id,
      where: g.actor_uri == ^group_uri
    )
  end
end
