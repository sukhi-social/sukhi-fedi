# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Fedi.DeliverySuspension.Control do
  @moduledoc """
  Does this controller really speak for this target? (FEP-f799 spec draft §7.)

  A notice says "`targetInbox` / `targetOrigin` is resting", signed by a
  controller. Anyone can write that about anyone, so the target has to point
  back. Three kinds of target, three ways, **all read fresh over HTTPS** (what
  a notice carries inside itself is never evidence):

    * **a personal inbox** — the controller's actor document has this URL as
      its `inbox`, and the inbox collection's `inboxOf` is that actor;
    * **a shared inbox** — the inbox collection's `deliveryController` (one
      actor) is the controller, and the controller's `endpoints.sharedInbox`
      is this URL. `inboxOf` is not accepted in its place;
    * **an origin** — WebFinger asked of the origin itself (the port too;
      `resource` is the origin): the `subject` is that origin, exactly one
      link of the `deliveryController` rel says who, and that actor lists the
      origin in `controlledOrigin`. The links the answer returns are looked at
      one by one: a `rel` filter in the query is not believed.

  The answer is `:ok`, or one of two *different* errors, because they mean
  different things for a notice we already hold:

    * `{:error, {:unlinked, why}}` — we read the documents and the link is not
      there. Whoever relied on this controller stops being believed now.
    * `{:error, {:unreachable, why}}` — we could not read them (timeout, 5xx,
      404, 410, too large, not JSON …). That is neither a cancellation nor a
      reason to extend anything: a notice already accepted keeps its own end.

  Every attempt is recorded (`Store.put_evidence/4`): when it last confirmed,
  when it last tried, and what went wrong. After a failure the same target is
  not asked again for 30 seconds (`{:unreachable, :throttled}`), so a flood of
  notices is not a flood of fetches.

  The `Receiver` asks only for what starts or extends a suspension, and takes
  the check as a function; `verify/3` is the real one, with `:http` to stand in
  for the network in tests.
  """

  alias SukhiFedi.Fedi.DeliverySuspension.{Fetch, Store}
  alias SukhiShared.DeliverySuspension.{Notice, Policy}

  # Draft names, in one place.
  @k_inbox_of "inboxOf"
  @k_delivery_controller "deliveryController"
  @k_controlled_origin "controlledOrigin"
  @rel_delivery_controller "https://w3id.org/fep/f799#deliveryController"

  @type why :: atom() | {atom(), term()}
  @type result :: :ok | {:error, {:unlinked, why()}} | {:error, {:unreachable, atom()}}

  @spec verify(Notice.t(), DateTime.t(), keyword()) :: result()
  def verify(%Notice{} = notice, %DateTime{} = now, opts \\ []) do
    opts = Keyword.put_new(opts, :policy, Policy.default())

    if recently_failed?(notice, now) do
      # Asking again at once would let a stream of notices turn this server
      # into a stream of fetches. Not recorded: it is not an attempt.
      {:error, {:unreachable, :throttled}}
    else
      {kind, result} = check(notice, opts)
      record(kind, notice, now, result)
      result
    end
  end

  # A failed attempt this recent is the answer for now.
  @throttle_s 30

  defp recently_failed?(notice, now) do
    Enum.any?(kinds(notice), fn kind ->
      case Store.get_evidence(kind, notice.target, notice.controller) do
        {:ok, %{failure: failure, attempted_at: %DateTime{} = at}} when not is_nil(failure) ->
          DateTime.diff(now, at, :second) < @throttle_s

        _ ->
          false
      end
    end)
  end

  @doc "The evidence rows a notice may have, by kind (a personal or a shared inbox is not known until it is read)."
  @spec kinds(Notice.t()) :: [atom()]
  def kinds(%Notice{target_kind: :origin}), do: [:origin]
  def kinds(%Notice{target_kind: :inbox}), do: [:inbox, :shared_inbox]

  # ── the three checks ─────────────────────────────────────────────────────

  defp check(%Notice{target_kind: :origin} = notice, opts) do
    {:origin, origin_check(notice, opts)}
  end

  defp check(%Notice{target_kind: :inbox} = notice, opts) do
    with {:ok, actor} <- actor(notice, opts) do
      cond do
        actor["inbox"] == notice.target -> {:inbox, personal_inbox(notice, opts)}
        shared_inbox_of(actor) == notice.target -> {:shared_inbox, shared_inbox(notice, opts)}
        true -> {:inbox, {:error, {:unlinked, :not_the_actors_inbox}}}
      end
    else
      {:error, _} = error -> {:inbox, error}
    end
  end

  defp personal_inbox(notice, opts) do
    with {:ok, collection} <- collection(notice, opts),
         true <- owner_ids(collection[@k_inbox_of]) == [notice.controller] || unlinked(:inbox_of) do
      :ok
    end
  end

  defp shared_inbox(notice, opts) do
    with {:ok, collection} <- collection(notice, opts),
         true <-
           owner_ids(collection[@k_delivery_controller]) == [notice.controller] ||
             unlinked(:delivery_controller) do
      :ok
    end
  end

  defp origin_check(%Notice{target: origin, controller: controller} = notice, opts) do
    url = origin <> "/.well-known/webfinger?resource=" <> URI.encode_www_form(origin)

    with {:ok, %{document: jrd}} <- fetch(url, :webfinger, opts),
         true <- jrd["subject"] == origin || unlinked(:subject),
         {:ok, href} <- single_controller_link(jrd),
         true <- href == controller || unlinked(:link_names_another),
         {:ok, actor} <- actor(notice, opts),
         true <-
           origin in owner_ids(actor[@k_controlled_origin]) || unlinked(:origin_not_controlled) do
      :ok
    end
  end

  # Exactly one link of the rel, looked at ourselves.
  defp single_controller_link(%{"links" => links}) when is_list(links) do
    case for(%{"rel" => @rel_delivery_controller, "href" => href} <- links, do: href) do
      [href] when is_binary(href) -> {:ok, href}
      _ -> unlinked(:not_exactly_one_link)
    end
  end

  defp single_controller_link(_jrd), do: unlinked(:not_exactly_one_link)

  # ── reading ──────────────────────────────────────────────────────────────

  defp actor(%Notice{controller: controller}, opts) do
    with {:ok, %{document: document}} <- fetch(controller, :activity, opts),
         true <- document["id"] == controller || unlinked(:actor_id) do
      {:ok, document}
    end
  end

  defp collection(%Notice{target: target}, opts) do
    with {:ok, %{document: document}} <- fetch(target, :activity, opts),
         true <- document["id"] == target || unlinked(:collection_id) do
      {:ok, document}
    end
  end

  # Fresh every time: no etag, no cache. A failure is "could not read".
  defp fetch(url, kind, opts) do
    case Fetch.get(url, kind, Keyword.take(opts, [:policy, :http])) do
      {:ok, ok} -> {:ok, ok}
      {:error, why} -> {:error, {:unreachable, why}}
    end
  end

  defp unlinked(why), do: {:error, {:unlinked, why}}

  defp shared_inbox_of(%{"endpoints" => %{"sharedInbox" => url}}) when is_binary(url), do: url
  defp shared_inbox_of(_actor), do: nil

  # A member that names actors: one id, or an object with an id, or a list of
  # either. Returns the ids as strings.
  defp owner_ids(nil), do: []
  defp owner_ids(value) when is_binary(value), do: [value]
  defp owner_ids(%{"id" => id}) when is_binary(id), do: [id]
  defp owner_ids(list) when is_list(list), do: Enum.flat_map(list, &owner_ids/1)
  defp owner_ids(_), do: []

  # ── evidence ─────────────────────────────────────────────────────────────

  defp record(kind, %Notice{target: target, controller: controller}, now, result) do
    attrs =
      case result do
        :ok ->
          %{verified_at: now, attempted_at: now, failure: :none}

        {:error, {:unlinked, _}} ->
          %{attempted_at: now, failure: :unlinked}

        {:error, {:unreachable, why}} ->
          %{attempted_at: now, failure: why}
      end

    _ = Store.put_evidence(kind, target, controller, attrs)
    :ok
  end
end
