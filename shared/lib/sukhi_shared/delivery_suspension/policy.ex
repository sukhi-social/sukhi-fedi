# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiShared.DeliverySuspension.Policy do
  @moduledoc """
  The numbers FEP-f799 leaves to each server (spec draft §12). They are
  sukhi's starting values, not the FEP's: ages, evidence and queues have
  different purposes and do not have to be the same number.

  Durations are whole seconds (or `_ms` where the name says so). Pure data;
  the gate takes a `%Policy{}` as an argument and never reads configuration,
  so a test moves a limit by passing a different struct.
  """

  @enforce_keys []
  defstruct notice_max_bytes: 64 * 1024,
            notice_max_depth: 8,
            # a notice older than this since `published` is no longer in effect
            notice_max_age: 14 * 86_400,
            # `published` may be this far ahead of our clock
            future_skew: 300,
            # how old control evidence may be before new/extending notices wait for a re-check
            evidence_max_age: 24 * 3600,
            # a suspension never lasts longer than this from its (effective) start
            max_suspension: 48 * 3600,
            fetch_timeout_ms: 10_000,
            max_redirects: 3,
            # after a suspension ends, deliveries resume spread over 0..this
            resume_jitter: 60,
            per_target_concurrency: 2,
            # what one controller may keep with us (spec §13): notices, and
            # Undos held for a Create we have not seen yet (per actor / in all)
            max_notices_per_controller: 32,
            max_pending_per_actor: 16,
            max_pending_total: 4096

  @type t :: %__MODULE__{
          notice_max_bytes: pos_integer(),
          notice_max_depth: pos_integer(),
          notice_max_age: pos_integer(),
          future_skew: non_neg_integer(),
          evidence_max_age: pos_integer(),
          max_suspension: pos_integer(),
          fetch_timeout_ms: pos_integer(),
          max_redirects: non_neg_integer(),
          resume_jitter: non_neg_integer(),
          per_target_concurrency: pos_integer(),
          max_notices_per_controller: pos_integer(),
          max_pending_per_actor: pos_integer(),
          max_pending_total: pos_integer()
        }

  @spec default() :: t()
  def default, do: %__MODULE__{}
end
