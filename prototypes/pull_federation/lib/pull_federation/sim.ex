# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule PullFederation.Sim do
  @moduledoc """
  Wires an `Origin` to a `Puller` in-process: the "network".
  `round/4` delivers due notifications, then lets B pull once if it can.
  """

  alias PullFederation.{Origin, Puller}

  def round(origin, domain, puller, opts) do
    now = Keyword.fetch!(opts, :now)
    busy? = Keyword.get(opts, :busy?, false)
    jitter = Keyword.get(opts, :jitter, fn _ -> 0 end)
    origin_domain = Keyword.get(opts, :origin_domain, "a.example")

    {origin, notes} = Origin.due_notifications(origin, now)

    puller =
      for {^domain, announced} <- notes, reduce: puller do
        acc -> elem(Puller.notify(acc, origin_domain, announced, now), 0)
      end

    case Puller.next_pull(puller, now, busy?) do
      {:pull, ^origin_domain, cursors} ->
        case Origin.open_stream(origin, domain, cursors, now) do
          {:ok, origin, events, announced} ->
            puller =
              Puller.finish_pull(puller, origin_domain, {:ok, events, announced}, now, jitter)

            {Origin.close_stream(origin), puller}

          {:error, _} = err ->
            {origin, Puller.finish_pull(puller, origin_domain, err, now, jitter)}
        end

      _ ->
        {origin, puller}
    end
  end
end
