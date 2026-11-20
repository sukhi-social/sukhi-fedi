# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Addons.MisskeyApi do
  @moduledoc """
  Misskey-compatibility addon — a different API profile alongside the
  Mastodon one. Today its only contribution is the table for
  server-side compose drafts (`notes_drafts`); the REST surface lives on
  the api plugin node (`SukhiApi.Capabilities.MisskeyDrafts`, tagged
  `addon: :misskey_api`) and the context that owns the rows is
  `SukhiFedi.NoteDrafts`.

  The addon carries no supervision children or NATS subscriptions: a
  draft is a private per-account cache, never federated, so nothing here
  rides the outbox or the delivery pipeline. Enable it with
  `ENABLED_ADDONS=misskey_api`.
  """

  use SukhiFedi.Addon, id: :misskey_api
end
