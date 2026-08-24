# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Web.StaticFiles do
  @moduledoc """
  Which of the two static trees answers a request.

  There are two, and both are legitimate:

      <release>/lib/sukhi_fedi-<vsn>/priv/static/   ← baked, ships with the release
      $STATIC_OVERRIDE_DIR                          ← pushed, `make push-static`

  The override exists so a CSS or SPA change can land by rsync alone, with
  no rebuild and no restart. Which means the two can disagree, and something
  has to choose.

  ## How it chooses

  By **when each copy was built**, not by when its files last touched a
  disk. `npm run build` leaves a `.static-build.json` behind (web/scripts/
  static-manifest.mjs) and it travels with the tree — into the image, into
  the release tarball, across the rsync. The newer build wins, as a whole
  tree rather than file by file, so an index.html and the chunks it names
  always come from the same build.

  It used to compare mtimes, and that was wrong in a way that took ten days
  to notice: DeployEx unpacks a release tarball on every deploy, so every
  baked file was stamped `now` and no push could ever win. mtime answers
  "last written here", which is not the question.

  Missing manifest counts as the oldest possible build. So a tree that says
  when it was built beats one that doesn't, and when neither says, the
  override wins — which is the older behaviour, and the kinder default for
  someone who put a file there on purpose.

  ## When the operator wants the last word

  `STATIC_OVERRIDE` (default `auto`):

    * `auto`   — newest build wins, as above
    * `prefer` — the override wins whenever it has the file, whatever the
      dates say. For "I know it is older, I want mine."
    * `only`   — the override is the only tree consulted; a file it does not
      have is a 404 rather than a fall-through. natadeco rides the same
      combined image, whose baked tree holds *sukhi's* frontend, and would
      rather show nothing than show the neighbour's page.

  `STATIC_OVERRIDE_ONLY=true` still means `only` — it is what natadeco is
  already set to.

  ## The paths that are never part of a build

  `styles/` and `emojis/` are pushed by hand and by the emoji importer;
  no SPA build produces them, so no build date describes them. They come
  from the override whenever it has them, in every mode. `STATIC_OVERRIDE_ALWAYS`
  (comma-separated prefixes) replaces the list.
  """

  @manifest ".static-build.json"
  @default_always ["styles/", "emojis/"]

  @doc """
  Resolve a path relative to the static root.

  Returns `{:override | :baked, absolute_path}`, or `nil` when neither tree
  has it. The tag is what the `x-static-source` response header reports.
  """
  @spec resolve(String.t()) :: {:override | :baked, String.t()} | nil
  def resolve(relative) do
    override = override_root()
    baked = baked_root()

    in_override = servable?(override, relative)
    in_baked = mode() != :only and servable?(baked, relative)

    cond do
      in_override and in_baked ->
        case tie_break(override, baked, relative) do
          :override -> {:override, Path.join(override, relative)}
          :baked -> {:baked, Path.join(baked, relative)}
        end

      in_override ->
        {:override, Path.join(override, relative)}

      in_baked ->
        {:baked, Path.join(baked, relative)}

      true ->
        nil
    end
  end

  @doc """
  The override directory.

  `:code.priv_dir/1` returns a path with the release version in it, which
  would make the bind-mount target move on every release — so the override
  lives at a fixed path instead, and deploy.yml never has to be edited.
  """
  @spec override_root() :: String.t()
  def override_root, do: System.get_env("STATIC_OVERRIDE_DIR", "/app/priv/static-override")

  @spec baked_root() :: String.t()
  def baked_root do
    System.get_env("STATIC_BAKED_DIR") || Path.join([:code.priv_dir(:sukhi_fedi), "static"])
  end

  ## ── private ──────────────────────────────────────────────────────────

  # Only reached when both trees hold the same path, which is rarer than it
  # sounds: the SPA's chunks are content-hashed, so a chunk belongs to
  # exactly one build and exactly one tree. What actually lands here is the
  # handful of stable names — index.html, favicon.png, the CSS.
  defp tie_break(override, baked, relative) do
    cond do
      mode() == :prefer -> :override
      always_from_override?(relative) -> :override
      # A tie goes to the override: pushing in the same second as a release
      # is a deliberate act, and so is pushing when neither tree says when
      # it was built.
      built_at(override) >= built_at(baked) -> :override
      true -> :baked
    end
  end

  defp always_from_override?(relative) do
    always()
    |> Enum.any?(&String.starts_with?(relative, &1))
  end

  defp always do
    case System.get_env("STATIC_OVERRIDE_ALWAYS") do
      nil -> @default_always
      "" -> []
      list -> String.split(list, ",", trim: true) |> Enum.map(&String.trim/1)
    end
  end

  defp mode do
    cond do
      System.get_env("STATIC_OVERRIDE_ONLY") == "true" -> :only
      true -> parse_mode(System.get_env("STATIC_OVERRIDE", "auto"))
    end
  end

  defp parse_mode("only"), do: :only
  defp parse_mode("prefer"), do: :prefer
  defp parse_mode(_), do: :auto

  # Read, not cached. An earlier draft memoised this on the manifest's own
  # mtime, which is the very thing this module exists to stop trusting —
  # a file rewritten inside the same second keeps its stamp and the cache
  # never notices. Two ~100-byte reads, only when both trees hold the same
  # path, is a small enough price for an answer that is always current.
  defp built_at(root) do
    with {:ok, body} <- File.read(Path.join(root, @manifest)),
         {:ok, %{"built_at" => built_at}} <- Jason.decode(body),
         true <- is_integer(built_at) do
      built_at
    else
      _ -> 0
    end
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
  defp servable?(root, relative) do
    full = Path.join(root, relative)

    with true <- String.starts_with?(Path.expand(full), Path.expand(root)),
         {:ok, %File.Stat{type: :regular, access: access}} <- File.stat(full) do
      access in [:read, :read_write]
    else
      _ -> false
    end
  end
end
