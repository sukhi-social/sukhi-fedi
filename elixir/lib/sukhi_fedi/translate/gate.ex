# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Translate.Gate do
  @moduledoc """
  How much translating one server does, and for whom. The only place those two
  limits are written (CODE_STYLE §0); `SukhiFedi.Translate` asks once, at the
  boundary, and the engine adapters trust it.

    * **Per person.** `@per_hour` translations an hour for one account, whichever
      engine. It keeps one account from spending a shared translator (or its own
      DeepL quota in a loop) and is counted by account, not by address — only a
      signed-in person can translate at all.
    * **At once, on the server's own translator.** At most `max_flight/0` run
      together on LibreTranslate, which is CPU and memory this server pays for.
      DeepL runs on the person's own quota and a network round trip, so it is
      not counted here. A request that finds the translator full is refused with
      how long to wait; it is not queued behind a socket (the person is looking
      at a button, not a spinner they must sit through), and the client does not
      retry on its own.

  The in-flight set holds one row per running request, `{pid}` in
  `:translate_flight` (owned by `Cache.Ets`), so a request that dies without
  cleaning up frees its place on the next count — the same shape as
  `Web.AdmissionQueue`.

  Both numbers are provisional until a load test has put real values on them
  (docs/TRANSLATION.md).
  """

  @table :translate_flight
  @per_hour 60
  @window_ms 3_600_000
  @default_flight 2
  @retry_after_s 10

  @type refusal :: {:busy, pos_integer()}

  @doc """
  Run `fun` if `account_id` is under their hourly allowance and, for the hosted
  translator (`engine: :libre`), the translator has a free place. `fun`'s own
  answer is returned unchanged.
  """
  @spec run(integer(), :libre | :deepl, (-> result)) :: result | {:error, refusal()} when result: term()
  def run(account_id, engine, fun) when is_integer(account_id) and engine in [:libre, :deepl] do
    case Hammer.check_rate("translate:#{account_id}", @window_ms, @per_hour) do
      {:allow, _} -> in_flight(engine, fun)
      {:deny, ms} -> {:error, {:busy, max(div(ms, 1_000), 1)}}
    end
  end

  defp in_flight(:deepl, fun), do: fun.()

  defp in_flight(:libre, fun) do
    :ets.insert(@table, {self()})

    if flight() > max_flight() do
      release()
      {:error, {:busy, @retry_after_s}}
    else
      try do
        fun.()
      after
        release()
      end
    end
  end

  @doc "How many translations the server's own translator runs at once."
  @spec max_flight() :: pos_integer()
  def max_flight, do: Application.get_env(:sukhi_fedi, :translate_max_flight, @default_flight)

  defp flight do
    n = :ets.info(@table, :size)

    if n > max_flight() do
      sweep_dead()
      :ets.info(@table, :size)
    else
      n
    end
  end

  defp release, do: :ets.delete(@table, self())

  defp sweep_dead do
    @table
    |> :ets.tab2list()
    |> Enum.each(fn {pid} -> if not Process.alive?(pid), do: :ets.delete(@table, pid) end)
  end
end
