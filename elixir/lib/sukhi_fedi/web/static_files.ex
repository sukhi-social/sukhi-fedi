# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Web.StaticFiles do
  @moduledoc """
  The few files the gateway hands out itself under `/static/`. None of them
  is a page — pages, icons and the web manifest belong to the web front.

  Two trees, and which one answers is decided by the path alone:

    * `emojis/…` — **the override dir** (`$STATIC_OVERRIDE_DIR`, default
      `/app/priv/static-override`): the custom emoji the importer drops on
      the host and the container sees through a read-only bind. They are
      the only thing in it, and it is the only place they are looked up — a
      missing one is a 404, not a fall-through.
    * everything else — **the baked tree** (`<release>/…/priv/static/`,
      `$STATIC_BAKED_DIR` in tests): what ships in the release. Today that is
      `avatar-default.svg`, the placeholder the API names for an account
      without a picture (`SukhiApi.Views.MastodonAccount`) — a remote client
      fetches it from here, so it has to keep answering.

  The override path is fixed (not `:code.priv_dir/1`, which has the release
  version in it) so the bind-mount target does not move on every release.

  An earlier version also chose between the two trees by which one was built
  later, because a pushed copy of the SPA could shadow a baked one. There is
  no SPA to shadow any more, so that choice — and `STATIC_OVERRIDE`,
  `STATIC_OVERRIDE_ONLY`, `STATIC_OVERRIDE_ALWAYS` with it — is gone.
  """

  @doc """
  The absolute path to serve for `relative` (a path under `/static/`), or
  `nil` when the tree that owns it cannot send it.
  """
  @spec resolve(String.t()) :: String.t() | nil
  def resolve("emojis/" <> _ = relative), do: servable(override_root(), relative)
  def resolve(relative), do: servable(baked_root(), relative)

  @doc """
  The override directory. A fixed path, so the bind-mount target never moves.
  """
  @spec override_root() :: String.t()
  def override_root, do: System.get_env("STATIC_OVERRIDE_DIR", "/app/priv/static-override")

  @spec baked_root() :: String.t()
  def baked_root do
    System.get_env("STATIC_BAKED_DIR") || Path.join([:code.priv_dir(:sukhi_fedi), "static"])
  end

  # "Is it there" is not the question — "can we actually send it" is.
  #
  # This used to be `File.regular?/1`, which stats, and stat only needs the
  # directories above a file to be walkable. A file we cannot open passed
  # that check, so the response went out with 200 and its body then died
  # mid-flight on eacces; the client saw a 502 while the log said 200. It
  # happened for real: 983 emoji files arrived from a zip at mode 0700 and
  # the container stopped running as root, so for nine hours every one of
  # them was a 502 that looked like a success from the inside.
  #
  # `File.stat/1` already knows — `:access` is computed against the running
  # user — and it is the same syscall we were making anyway.
  defp servable(root, relative) do
    full = Path.join(root, relative)

    with true <- String.starts_with?(Path.expand(full), Path.expand(root)),
         {:ok, %File.Stat{type: :regular, access: access}} <- File.stat(full),
         true <- access in [:read, :read_write] do
      full
    else
      _ -> nil
    end
  end
end
