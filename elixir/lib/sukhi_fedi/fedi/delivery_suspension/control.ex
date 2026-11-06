# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Fedi.DeliverySuspension.Control do
  @moduledoc """
  Does this controller really speak for this target? (FEP-f799 §7.)

  Not built yet: stage 4 (#160) brings the three checks (individual inbox,
  shared inbox, origin) and the evidence age. Until then the answer is
  always no, which is the safe side of "deliver when in doubt": the
  `Receiver` takes a notice only when this says yes, so a notice from
  anyone cannot hold back deliveries to somebody else's inbox, and a build
  without stage 4 changes nothing about delivery.

  The `Receiver` takes the check as a function (`opts[:control]`), so its
  tests supply their own and this module is the one real value.
  """

  alias SukhiShared.DeliverySuspension.Notice

  @doc "Confirm `notice.controller` may speak for `notice.target`, as of `now`."
  @spec verify(Notice.t(), DateTime.t()) :: :ok | {:error, term()}
  def verify(%Notice{}, %DateTime{}), do: {:error, :control_unverified}
end
