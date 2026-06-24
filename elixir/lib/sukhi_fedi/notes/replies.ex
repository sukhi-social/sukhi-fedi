# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Notes.Replies do
  @moduledoc """
  The public replies to a note, for FEP-7458's `replies` collection.

  A reply is any note pointing back at the parent through
  `in_reply_to_ap_id`. The parent can be referenced by either its stored
  `ap_id` or the synthesized `/users/<u>/notes/<id>` URL (a remote that
  dereferenced us replies to whichever id it saw), so the caller passes
  every form the parent is known by and we match on all of them.

  Only public replies are listed — a collection a remote can read should
  never surface a follower-only or direct reply.
  """

  import Ecto.Query

  alias SukhiFedi.Repo
  alias SukhiFedi.Schema.Note

  @spec public_reply_uris([String.t()]) :: [String.t()]
  def public_reply_uris(parent_ap_ids) when is_list(parent_ap_ids) do
    domain = SukhiFedi.Config.domain!()

    from(n in Note,
      join: a in assoc(n, :account),
      where: n.in_reply_to_ap_id in ^parent_ap_ids and n.visibility == "public",
      order_by: [asc: n.created_at],
      select: %{ap_id: n.ap_id, id: n.id, username: a.username}
    )
    |> Repo.all()
    |> Enum.map(&reply_uri(&1, domain))
  end

  # Remote reply → its real ap_id; local reply (ap_id NULL) → synthesized.
  defp reply_uri(%{ap_id: ap_id}, _domain) when is_binary(ap_id), do: ap_id

  defp reply_uri(%{id: id, username: username}, domain),
    do: "https://#{domain}/users/#{username}/notes/#{id}"
end
