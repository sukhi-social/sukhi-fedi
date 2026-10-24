# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiApi.Views.MastodonPoll do
  @moduledoc """
  Render a Polls.get_with_results/2 map into Mastodon poll JSON.
  """

  alias SukhiApi.Views.{Id, Timestamp}

  def render(nil), do: nil

  def render(%{poll: poll, options: options, tallies: tallies} = ctx) do
    expires_at = Timestamp.iso8601(Map.get(poll, :expires_at))

    %{
      id: Id.encode(poll.id),
      expires_at: expires_at,
      expired: expired?(poll),
      multiple: !!poll.multiple,
      votes_count: votes_count(tallies),
      voters_count: Map.get(ctx, :voters_count, 0),
      voted: Map.get(ctx, :voted?, false),
      # Mastodon's own_votes is a list of option *indices*, not DB ids.
      own_votes: own_vote_indices(options, Map.get(ctx, :voted_option_ids, [])),
      options:
        Enum.map(options, fn o ->
          %{title: o.title, votes_count: Map.get(tallies, o.id, 0)}
        end),
      emojis: []
    }
  end

  # `voted_option_ids` are DB option ids; map each back to its position in the
  # ordered `options` list so clients can highlight the viewer's own choices.
  defp own_vote_indices(options, voted_option_ids) do
    index_by_id =
      options
      |> Enum.with_index()
      |> Map.new(fn {o, i} -> {o.id, i} end)

    voted_option_ids
    |> Enum.map(&Map.get(index_by_id, &1))
    |> Enum.reject(&is_nil/1)
  end

  defp votes_count(tallies), do: tallies |> Map.values() |> Enum.sum()

  defp expired?(%{expires_at: nil}), do: false

  defp expired?(%{expires_at: %DateTime{} = exp}),
    do: DateTime.compare(exp, DateTime.utc_now()) != :gt

  defp expired?(_), do: false
end
