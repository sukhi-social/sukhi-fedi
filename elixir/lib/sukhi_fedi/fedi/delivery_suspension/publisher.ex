# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Fedi.DeliverySuspension.Publisher do
  @moduledoc """
  The telling side of FEP-f799 (docs/DELIVERY_SUSPENSION.md): sukhi saying, before
  maintenance, "we are resting for a while".

  Everything here is **made before the work and signed then**, so that nothing
  is needed from the application, or from the private key, while it sleeps:

    * `prepare/1` builds the whole set from a few facts and the controller's
      Ed25519 key, and returns it as files (path → bytes). Nothing is written
      or sent here.
    * The notice (revision 1, `active`) is what peers read. Its `endTime` is
      the expected length with room to spare (`:margin`, default 1.5×, never
      past the policy's longest suspension): a peer lets go at `endTime` on
      its own, so a job that runs long costs a little extra patience, and one
      that runs short is ended by the cancellation.
    * The cancellation is the *same* notice, `revision` raised, `status:
      cancelled`, signed now and **kept back** until the work is done. A
      cancellation is final for whoever holds it, whatever its revision, so
      it stays valid even if the rest was extended in the meantime
      (`extend/3`).
    * The Create that carries the notice to peers is one public activity,
      content unchanged; `announcement` names it, and the Undo (made now,
      sent at the end) points at it.

  What the notice says is kept to what a stranger may read: a short human
  line (`summary`), a page for the state of things (`url`). No private detail
  of the operation goes in.

  The proof is `eddsa-jcs-2022` (`Oip.sign/4`), and `prepare/1` checks its own
  work: the key must be the one the actor publishes (its public half is
  compared), and every document it makes is read back through the same
  `Receiver` another sukhi would use.
  """

  alias SukhiFedi.Fedi.Oip
  alias SukhiShared.DeliverySuspension.{Hint, Notice, Policy}
  alias SukhiShared.{JWK, Keys}

  @public "https://www.w3.org/ns/activitystreams#Public"
  @margin 1.5
  @max_summary 200

  @type target :: {:origin, String.t()} | {:inbox, String.t()}

  @doc """
  Everything for one resting, as `%{path => json_bytes}`, plus the facts the
  caller may want to show (`:notice`, `:cancel`, `:create`, `:undo` as maps).

  Options (all required unless marked):

    * `:domain` — our host (`rest.example`); the ids are minted on it
    * `:controller` — the actor that speaks (`https://rest.example/users/ops`)
    * `:private_jwk`, `:public_multibase` — that actor's Ed25519 key
    * `:target` — `{:origin, "https://rest.example"}` or `{:inbox, url}`
    * `:expected_minutes` — how long we think it takes
    * `:now` — a `DateTime`
    * `:slug` — names the files and ids (default: random)
    * `:summary`, `:url` — what people read (optional)
    * `:inbox_kind` — for an `{:inbox, url}` target, `:personal` (default) or
      `:shared`: which of the actor's inboxes it is
    * `:margin`, `:policy` (optional)
  """
  @spec prepare(keyword()) :: {:ok, map()} | {:error, term()}
  def prepare(opts) do
    policy = Keyword.get(opts, :policy, Policy.default())
    now = Keyword.fetch!(opts, :now)
    slug = Keyword.get_lazy(opts, :slug, &slug/0)
    domain = Keyword.fetch!(opts, :domain)
    controller = Keyword.fetch!(opts, :controller)

    ids = %{
      notice: "https://#{domain}/suspensions/#{slug}",
      create: "https://#{domain}/activities/suspension-#{slug}-create",
      undo: "https://#{domain}/activities/suspension-#{slug}-undo"
    }

    with {:ok, private_key} <- JWK.ed25519_private_key(Keyword.fetch!(opts, :private_jwk)),
         :ok <- same_key(private_key, Keyword.fetch!(opts, :public_multibase)),
         {:ok, summary} <- summary(opts[:summary]),
         {:ok, end_time} <- end_time(opts, now, policy),
         notice = notice(opts, ids, controller, now, end_time, summary),
         key_id = Keys.ed25519_key_id(controller),
         {:ok, active} <- Oip.sign(notice, private_key, key_id, created: iso(now)),
         {:ok, cancel} <-
           Oip.sign(cancelled(notice), private_key, key_id, created: iso(now)),
         create = create(ids, controller, active),
         undo = undo(ids, controller),
         controls = controls(opts, controller),
         :ok <- parses?(active, policy),
         :ok <- parses?(cancel, policy) do
      {:ok,
       %{
         notice: active,
         cancel: cancel,
         create: create,
         undo: undo,
         ends_at: end_time,
         controls: controls,
         files: files(slug, active, cancel, create, undo, controls)
       }}
    end
  end

  @doc """
  A later revision of an `active` notice that ends at `new_end` (an
  `Update`'s object). Only `revision`, `endTime` and the human lines move;
  what `Notice.same_immutable?/2` protects is untouched. The held-back
  cancellation does not need re-signing.
  """
  @spec extend(map(), DateTime.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def extend(%{"revision" => revision} = signed, %DateTime{} = new_end, opts) do
    policy = Keyword.get(opts, :policy, Policy.default())
    now = Keyword.fetch!(opts, :now)

    with {:ok, private_key} <- JWK.ed25519_private_key(Keyword.fetch!(opts, :private_jwk)),
         :ok <- within(new_end, now, signed, policy) do
      unsigned =
        signed
        |> Map.drop(["proof"])
        |> Map.put("revision", revision + 1)
        |> Map.put("endTime", iso(new_end))

      Oip.sign(unsigned, private_key, Keys.ed25519_key_id(signed["attributedTo"]),
        created: iso(now)
      )
    end
  end

  @doc "The `Update` that carries an extended notice."
  @spec update_activity(map(), String.t(), keyword()) :: map()
  def update_activity(notice, domain, opts \\ []) do
    slug = Keyword.get_lazy(opts, :slug, &slug/0)

    %{
      "id" => "https://#{domain}/activities/suspension-#{slug}-update-#{notice["revision"]}",
      "type" => "Update",
      "actor" => notice["attributedTo"],
      "to" => [@public],
      "object" => notice
    }
  end

  # ── pieces ───────────────────────────────────────────────────────────────

  defp notice(opts, ids, controller, now, end_time, summary) do
    target =
      case Keyword.fetch!(opts, :target) do
        {:origin, origin} -> %{"targetOrigin" => origin}
        {:inbox, inbox} -> %{"targetInbox" => inbox}
      end

    %{
      "@context" => ["https://www.w3.org/ns/activitystreams", "https://w3id.org/fep/f799"],
      "id" => ids.notice,
      "type" => Notice.type_name(),
      "attributedTo" => controller,
      "revision" => 1,
      "status" => "active",
      "published" => iso(now),
      "endTime" => iso(end_time),
      "announcement" => ids.create
    }
    |> Map.merge(target)
    |> put_text("summary", summary)
    |> put_text("url", opts[:url])
  end

  # The same notice, ended. `published` and everything immutable stay.
  defp cancelled(notice) do
    notice |> Map.put("revision", 2) |> Map.put("status", "cancelled")
  end

  defp create(ids, controller, notice) do
    %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => ids.create,
      "type" => "Create",
      "actor" => controller,
      "to" => [@public],
      "object" => notice
    }
  end

  defp undo(ids, controller) do
    %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => ids.undo,
      "type" => "Undo",
      "actor" => controller,
      "to" => [@public],
      "object" => ids.create
    }
  end

  defp files(slug, notice, cancel, create, undo, controls) do
    control_files =
      Map.new(controls, fn {path, document} -> {"public/control#{path}.json", json(document)} end)

    Map.merge(control_files, %{
      # served while resting
      "public/suspensions/#{slug}.json" => json(notice),
      # held back until the work is done
      "held/#{slug}.cancel.json" => json(cancel),
      "held/#{slug}.undo.json" => json(undo),
      # sent to peers when the resting starts
      "send/#{slug}.create.json" => json(create)
    })
  end

  @doc """
  The documents a peer reads to confirm that the controller speaks for the
  target (`Control`, spec §7), as `%{url_path => map}` — they are what has to
  be answerable **while the application sleeps**, so they are made now and
  served as static files:

    * the controller's actor, with the member that points at the target
      (`inbox` / `endpoints.sharedInbox` / `controlledOrigin`) and its
      `assertionMethod` key, so a proof of ours can still be checked;
    * for an inbox, the inbox collection with `inboxOf` (personal) or
      `deliveryController` (shared);
    * for an origin, the WebFinger answer (`/.well-known/webfinger`) with the
      one `deliveryController` link.

  Only the members the check reads, plus the key. They stand in for the live
  documents for the length of the rest; the application's own answer comes
  back when it does.
  """
  @spec controls(keyword(), String.t()) :: %{String.t() => map()}
  def controls(opts, controller) do
    key = %{
      "id" => Keys.ed25519_key_id(controller),
      "type" => "Multikey",
      "controller" => controller,
      "publicKeyMultibase" => Keyword.fetch!(opts, :public_multibase)
    }

    actor = %{
      "@context" => [
        "https://www.w3.org/ns/activitystreams",
        "https://w3id.org/security/multikey/v1"
      ],
      "id" => controller,
      "type" => "Person",
      "assertionMethod" => [key]
    }

    case Keyword.fetch!(opts, :target) do
      {:origin, origin} ->
        %{
          path_of(controller) => Map.put(actor, "controlledOrigin", [origin]),
          "/.well-known/webfinger" => %{
            "subject" => origin,
            "links" => [%{"rel" => Hint.rel_controller(), "href" => controller}]
          }
        }

      {:inbox, inbox} ->
        case Keyword.get(opts, :inbox_kind, :personal) do
          :personal ->
            %{
              path_of(controller) => Map.put(actor, "inbox", inbox),
              path_of(inbox) => %{"id" => inbox, "inboxOf" => controller}
            }

          :shared ->
            %{
              path_of(controller) => Map.put(actor, "endpoints", %{"sharedInbox" => inbox}),
              path_of(inbox) => %{"id" => inbox, "deliveryController" => controller}
            }
        end
    end
  end

  defp path_of(url), do: URI.parse(url).path

  # ── checks ───────────────────────────────────────────────────────────────

  # The key we were given is the key the actor publishes.
  defp same_key(private_key, public_multibase) when is_binary(public_multibase) do
    {public, _} = :crypto.generate_key(:eddsa, :ed25519, private_key)

    if JWK.ed25519_multibase(public) == public_multibase,
      do: :ok,
      else: {:error, :key_is_not_the_actors}
  end

  defp same_key(_private_key, _other), do: {:error, :key_is_not_the_actors}

  defp end_time(opts, now, policy) do
    minutes = Keyword.fetch!(opts, :expected_minutes)
    margin = Keyword.get(opts, :margin, @margin)

    cond do
      not (is_number(minutes) and minutes > 0) ->
        {:error, :bad_expected_minutes}

      true ->
        seconds = min(round(minutes * 60 * margin), policy.max_suspension)
        {:ok, DateTime.add(now, seconds, :second) |> DateTime.truncate(:second)}
    end
  end

  # A notice the receiver would refuse is not worth sending: read both back
  # the way a peer does.
  defp parses?(document, policy) do
    case Notice.parse(Map.delete(document, "proof"), policy) do
      {:ok, _notice} -> :ok
      {:error, reason} -> {:error, {:notice_would_be_refused, reason}}
    end
  end

  defp within(new_end, now, signed, policy) do
    {:ok, published, _} = DateTime.from_iso8601(signed["published"])
    limit = DateTime.add(published, policy.max_suspension, :second)

    cond do
      DateTime.compare(new_end, now) != :gt -> {:error, :end_in_the_past}
      DateTime.compare(new_end, limit) == :gt -> {:error, :longer_than_allowed}
      true -> :ok
    end
  end

  defp summary(nil), do: {:ok, nil}

  defp summary(text) when is_binary(text) do
    text = String.trim(text)
    if String.length(text) <= @max_summary, do: {:ok, text}, else: {:error, :summary_too_long}
  end

  defp summary(_), do: {:error, :bad_summary}

  defp put_text(map, _key, nil), do: map
  defp put_text(map, _key, ""), do: map
  defp put_text(map, key, text), do: Map.put(map, key, text)

  defp iso(%DateTime{} = dt), do: dt |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp json(document), do: Jason.encode!(document, pretty: true)

  defp slug, do: :crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false)
end
