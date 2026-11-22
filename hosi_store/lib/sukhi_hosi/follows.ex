# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiHosi.Follows do
  @moduledoc """
  Who follows whom. A follow is an entity (it has a state and a time); the pair is its
  identity, as a string, because hosigraph has no tuple attribute.
  """

  alias SukhiHosi.{Notifications, Store}

  defp pair(a, b), do: "#{a}>#{b}"

  @doc """
  `follower` follows `followee`: pending (they must say yes) or, with `state: :accepted`, at once.
  The followee is told in the same write: a request, or a follow.
  """
  def follow(db, follower, followee, opts \\ []) do
    state = Keyword.get(opts, :state, :pending)
    type = if state == :accepted, do: :follow, else: :follow_request

    ops =
      [
        [:create, [:tmp, 1], :"follow/follower", [:ref, follower]],
        [:create, [:tmp, 1], :"follow/followee", [:ref, followee]],
        [:create, [:tmp, 1], :"follow/state", state],
        [:create, [:tmp, 1], :"follow/pair", pair(follower, followee)],
        [:create, [:tmp, 1], :"follow/at", Store.now_us()]
      ] ++ Notifications.follow_ops(db, 2, type, follower, followee)

    case Hosi.write(db, ops) do
      {:ok, _} -> :ok
      {:error, {:app, _, _}} -> :already
    end
  end

  @doc """
  Pending becomes accepted, once; anything else is left as it is. The request they were shown
  becomes a follow, in the same write.
  """
  def accept(db, follower, followee) do
    case Store.lookup(db, :"follow/pair", pair(follower, followee)) do
      nil ->
        :none

      f ->
        ops =
          [[:create, f, :"follow/state", :accepted]] ++
            Notifications.undo_ops(db, :follow_request, followee, follower) ++
            Notifications.follow_ops(db, 1, :follow, follower, followee)

        case Hosi.write(db, ops, when: [[:holds, f, :"follow/state", :pending]]) do
          {:ok, _} -> :ok
          {:error, {:app, :conflict, _}} -> :not_pending
        end
    end
  end

  def unfollow(db, follower, followee) do
    case Store.lookup(db, :"follow/pair", pair(follower, followee)) do
      nil -> :none
      f ->
        ops =
          Store.retract_ops(db, f) ++
            Notifications.undo_ops(db, :follow, followee, follower) ++
            Notifications.undo_ops(db, :follow_request, followee, follower)

        {:ok, _} = Hosi.write(db, ops)
        :ok
    end
  end

  @doc "The accounts `follower` follows, accepted only."
  def followees(db, follower) do
    db
    |> Store.rows(
      "[:find ?a :in $ ?me :where [?f :follow/follower ?me] [?f :follow/state :accepted] [?f :follow/followee ?a]]",
      [[:scalar, follower]]
    )
    |> List.flatten()
  end
end
