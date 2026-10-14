# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Fedi.OjakShadow do
  @moduledoc """
  Runs ojak next to our own verifier and says so when the two disagree.

  The caller always keeps *its own* answer; this module returns `:ok`
  whatever happens. It is how we learn, on real traffic, whether ojak
  would have accepted and refused the same requests — before anything
  depends on it. Off unless `OJAK_SHADOW=1` (`Fedi.Ojak.shadow?/0`).

  Only the verdicts are compared (accepted vs refused); the reasons are
  logged beside them because ojak and we name failures differently.
  Nothing from the request — body, headers, keys — goes into the log.
  """

  require Logger

  alias SukhiFedi.Fedi.Ojak

  @type verdict :: :ok | {:error, term()}

  @doc """
  `ours` is the verdict the caller already has. `ojak` runs only when the
  shadow is on, and its raise or exit is swallowed.
  """
  @spec compare(atom(), verdict(), (-> verdict())) :: :ok
  def compare(kind, ours, ojak) when is_function(ojak, 0) do
    if Ojak.shadow?(), do: run(kind, ours, ojak)
    :ok
  end

  defp run(kind, ours, ojak) do
    theirs = ojak.()

    unless accepted?(ours) == accepted?(theirs) do
      Logger.warning(
        "ojak shadow disagreement on #{kind}: ours=#{inspect(ours)} ojak=#{inspect(theirs)}"
      )
    end
  rescue
    _ -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp accepted?(:ok), do: true
  defp accepted?(_), do: false
end
