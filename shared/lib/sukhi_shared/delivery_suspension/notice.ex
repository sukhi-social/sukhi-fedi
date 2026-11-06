# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiShared.DeliverySuspension.Notice do
  @moduledoc """
  A FEP-f799 `DeliverySuspension` notice, in the shape the rest of the code
  trusts: what `parse/2` returns has passed the **form** checks (spec draft
  §6.3–6.4) and nothing else. That it is genuine (signature or proof), that
  its controller may speak for the target (§7), and that it is new rather than
  stale (§6.6–6.7) are other modules' jobs; this one is pure.

  FEP-f799 is a DRAFT and its property names may change. Every name the wire
  uses is a module attribute below, and nothing outside this module spells
  them.

  The struct carries both what the document says and what we decide on
  accepting it (`effective_start`, `accepted_at`, `cancelled_at`,
  `proof_expires_at`); `parse/2` leaves the second group `nil`, and a notice
  with no `accepted_at` is never in effect (`Gate`).
  """

  alias SukhiShared.DeliverySuspension.{Origin, Policy}

  # ── the wire names, in one place ─────────────────────────────────────────
  @type_name "DeliverySuspension"
  @k_type "type"
  @k_id "id"
  @k_controller "attributedTo"
  @k_target_inbox "targetInbox"
  @k_target_origin "targetOrigin"
  @k_revision "revision"
  @k_status "status"
  @k_published "published"
  @k_announcement "announcement"
  @k_start "startTime"
  @k_end "endTime"
  @k_summary "summary"
  @k_url "url"

  @max_revision 9_007_199_254_740_991

  @enforce_keys [:id, :controller, :target_kind, :target, :revision, :published]
  defstruct [
    :id,
    :controller,
    :target_kind,
    :target,
    :revision,
    :published,
    :announcement,
    :start_time,
    :end_time,
    :summary,
    :url,
    status: :active,
    # decided on accepting, not read from the document:
    effective_start: nil,
    proof_expires_at: nil,
    accepted_at: nil,
    cancelled_at: nil
  ]

  @type target_kind :: :inbox | :origin
  @type t :: %__MODULE__{
          id: String.t(),
          controller: String.t(),
          target_kind: target_kind(),
          target: String.t(),
          revision: pos_integer(),
          published: DateTime.t(),
          announcement: String.t() | nil,
          start_time: DateTime.t() | nil,
          end_time: DateTime.t() | nil,
          summary: String.t() | nil,
          url: String.t() | nil,
          status: :active | :cancelled,
          effective_start: DateTime.t() | nil,
          proof_expires_at: DateTime.t() | nil,
          accepted_at: DateTime.t() | nil,
          cancelled_at: DateTime.t() | nil
        }

  @doc "The `type` a notice carries on the wire."
  @spec type_name() :: String.t()
  def type_name, do: @type_name

  @doc """
  Is `value` (a decoded JSON term) a notice by its `type`? A `type` may be one
  string or a list that contains it.
  """
  @spec notice?(term()) :: boolean()
  def notice?(%{} = map), do: has_type?(map, @type_name)
  def notice?(_), do: false

  @doc false
  # Shared with `Gate.exempt?/1`: does `map["type"]` name `wanted`?
  @spec has_type?(map(), String.t()) :: boolean()
  def has_type?(map, wanted) when is_map(map) do
    case Map.get(map, @k_type) do
      ^wanted -> true
      list when is_list(list) -> wanted in list
      _ -> false
    end
  end

  @doc """
  The form checks, in order. `{:error, reason}` names the first that fails;
  the reason goes to telemetry, never into a response.
  """
  @spec parse(term(), Policy.t()) :: {:ok, t()} | {:error, atom()}
  def parse(document, policy \\ Policy.default())

  def parse(%{} = document, %Policy{} = policy) do
    with :ok <- check_depth(document, policy),
         :ok <- check_type(document),
         {:ok, id} <- https_url(document, @k_id, :bad_id),
         {:ok, controller} <- actor_uri(Map.get(document, @k_controller)),
         {:ok, {kind, target}} <- target(document),
         {:ok, revision} <- revision(Map.get(document, @k_revision)),
         {:ok, status} <- status(Map.get(document, @k_status)),
         {:ok, published} <- required_time(document, @k_published),
         {:ok, start_time} <- optional_time(document, @k_start),
         {:ok, end_time} <- optional_time(document, @k_end),
         :ok <- check_order(start_time, end_time),
         {:ok, announcement} <- announcement(Map.get(document, @k_announcement)),
         :ok <- check_owned(controller, [id, announcement]) do
      {:ok,
       %__MODULE__{
         id: id,
         controller: controller,
         target_kind: kind,
         target: target,
         revision: revision,
         published: published,
         announcement: announcement,
         start_time: start_time,
         end_time: end_time,
         status: status,
         summary: text(Map.get(document, @k_summary)),
         url: text(Map.get(document, @k_url))
       }}
    end
  end

  def parse(_document, _policy), do: {:error, :not_an_object}

  @doc """
  Levels of nesting in a decoded term: a flat object is 1, an object in an
  object 2. (The byte scan in `HttpFetch` bounds a body before decoding; this
  measures a map already decoded, so the notice's own limit — 8, smaller than
  the inbox's — holds wherever the map came from.)
  """
  @spec depth(term()) :: non_neg_integer()
  def depth(%{} = map),
    do: 1 + (map |> Map.values() |> Enum.map(&depth/1) |> Enum.max(fn -> 0 end))

  def depth(list) when is_list(list),
    do: 1 + (list |> Enum.map(&depth/1) |> Enum.max(fn -> 0 end))

  def depth(_scalar), do: 0

  @doc """
  The members a later revision may not change: `id`, `attributedTo`,
  `published`, `announcement` (present or not, and its value), and the target
  (its kind and value). Anything else may move with a higher `revision`.
  """
  @spec same_immutable?(t(), t()) :: boolean()
  def same_immutable?(%__MODULE__{} = old, %__MODULE__{} = new) do
    old.id == new.id and old.controller == new.controller and
      DateTime.compare(old.published, new.published) == :eq and
      old.announcement == new.announcement and
      old.target_kind == new.target_kind and old.target == new.target
  end

  # ── the checks ───────────────────────────────────────────────────────────

  defp check_depth(document, %Policy{notice_max_depth: limit}) do
    if depth(document) <= limit, do: :ok, else: {:error, :too_deep}
  end

  defp check_type(document) do
    if has_type?(document, @type_name), do: :ok, else: {:error, :wrong_type}
  end

  defp https_url(document, key, error) do
    case Map.get(document, key) do
      url when is_binary(url) -> url_ok(url, error)
      _ -> {:error, error}
    end
  end

  defp url_ok(url, error) do
    case Origin.of_delivery_url(url) do
      {:ok, _origin} -> {:ok, url}
      :error -> {:error, error}
    end
  end

  # `attributedTo`: one actor, as an id or as an object with an id.
  defp actor_uri(uri) when is_binary(uri), do: url_ok(uri, :bad_controller)
  defp actor_uri(%{@k_id => uri}) when is_binary(uri), do: url_ok(uri, :bad_controller)
  defp actor_uri(_), do: {:error, :bad_controller}

  # Exactly one of the two, and a target we can match on.
  defp target(document) do
    inbox = Map.get(document, @k_target_inbox)
    origin = Map.get(document, @k_target_origin)

    case {inbox, origin} do
      {nil, nil} -> {:error, :no_target}
      {i, o} when not is_nil(i) and not is_nil(o) -> {:error, :two_targets}
      {inbox, nil} when is_binary(inbox) -> inbox_target(inbox)
      {nil, origin} when is_binary(origin) -> origin_target(origin)
      _ -> {:error, :bad_target}
    end
  end

  # The inbox is compared as written, so it must be a URL we can read an
  # origin from; we keep the string untouched.
  defp inbox_target(inbox) do
    case Origin.of_delivery_url(inbox) do
      {:ok, _origin} -> {:ok, {:inbox, inbox}}
      :error -> {:error, :bad_target}
    end
  end

  defp origin_target(origin) do
    case Origin.normalize(origin) do
      {:ok, normalized} -> {:ok, {:origin, normalized}}
      :error -> {:error, :bad_target}
    end
  end

  defp revision(n) when is_integer(n) and n >= 1 and n <= @max_revision, do: {:ok, n}
  defp revision(_), do: {:error, :bad_revision}

  defp status("active"), do: {:ok, :active}
  defp status(nil), do: {:ok, :active}
  defp status("cancelled"), do: {:ok, :cancelled}
  defp status(_), do: {:error, :bad_status}

  # RFC 3339 with a zone: `from_iso8601` refuses a missing offset.
  defp required_time(document, key) do
    case parse_time(Map.get(document, key)) do
      {:ok, time} -> {:ok, time}
      _ -> {:error, :bad_time}
    end
  end

  defp optional_time(document, key) do
    case Map.get(document, key) do
      nil -> {:ok, nil}
      value -> required_time(%{key => value}, key)
    end
  end

  defp parse_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, time, _offset} -> {:ok, time}
      {:error, _} -> :error
    end
  end

  defp parse_time(_), do: :error

  defp check_order(%DateTime{} = start, %DateTime{} = finish) do
    if DateTime.compare(finish, start) == :gt, do: :ok, else: {:error, :end_before_start}
  end

  defp check_order(_start, _finish), do: :ok

  defp announcement(nil), do: {:ok, nil}
  defp announcement(uri) when is_binary(uri), do: url_ok(uri, :bad_announcement)
  defp announcement(%{@k_id => uri}) when is_binary(uri), do: url_ok(uri, :bad_announcement)
  defp announcement(_), do: {:error, :bad_announcement}

  # The notice's own id and its announcement must live on the controller's
  # origin: a controller cannot publish a notice, or point at a Create, that
  # another server hosts.
  defp check_owned(controller, urls) do
    {:ok, home} = Origin.of_delivery_url(controller)

    owned? =
      urls
      |> Enum.reject(&is_nil/1)
      |> Enum.all?(fn url -> Origin.of_delivery_url(url) == {:ok, home} end)

    if owned?, do: :ok, else: {:error, :id_not_owned}
  end

  # `summary` and `url` are shown to people later; here they are only kept
  # as text. Sanitizing is the display layer's rule (same as any remote post).
  defp text(value) when is_binary(value), do: value
  defp text(_), do: nil
end
