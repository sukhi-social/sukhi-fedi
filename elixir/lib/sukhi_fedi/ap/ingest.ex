# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.AP.Ingest do
  @moduledoc """
  The one place an activity whose *sender is already authenticated* is
  admitted and executed. Two doors lead here and share every check after the
  door:

    * the inbox (`Web.InboxController`) — the sender proved itself with an
      HTTP signature on the POST;
    * a pull (`PullFederation.Puller`) — the activity came over TLS from the
      host we asked, which is the signer host.

  Past the door the order is fixed (CODE_STYLE §2): instance policy first
  (a suspended host never gets to make us fetch its key document), then the
  FEP-8b32 Object Integrity Proof, then classify (`fedify.inbox.v1`), then
  execute with the signer host so `Instructions.trusted_inline_origin?/2`
  can bind the claimed actor to the sender.

  The result tells the door what to answer; it never raises on a bad
  activity.
  """

  require Logger

  alias SukhiFedi.AP.Instructions
  alias SukhiFedi.Federation.FedifyClient

  @type result :: :accepted | :suppressed | {:error, :proof_failed} | {:error, {:parse, term()}}

  @doc """
  Admit and execute `raw_json`, sent by `signer_host`.

  Options:

    * `:self_domain` — our public domain (default: the configured one)
    * `:sign_as` — the signing identity for fetches the parse step makes
      (`Accounts.signing_identity/0` shape), or nil
    * `:before_parse` — a zero-arity function called once the activity is
      known to be genuine and wanted, before it is classified. The inbox
      archives the raw bytes here, so a parse failure cannot lose the record.
  """
  @spec run(map(), String.t() | nil, keyword()) :: result()
  def run(raw_json, signer_host, opts \\ []) when is_map(raw_json) do
    if policy(raw_json) == :reject do
      # Accept-and-drop so the blocked peer cannot tell it is being filtered:
      # no handlers, no archive. A `:silence`d host falls through and is kept
      # off the home/public surfaces downstream.
      :suppressed
    else
      case proof_verdict(raw_json) do
        :failed ->
          # A proof we can check did not check out. Downgrade safety: a
          # broken proof must not fall through to signature-only handling.
          {:error, :proof_failed}

        verdict ->
          if f = opts[:before_parse], do: f.()
          parse_and_execute(raw_json, signer_host, verdict == :author_signed, opts)
      end
    end
  end

  defp parse_and_execute(raw_json, signer_host, author_signed?, opts) do
    self_domain = Keyword.get(opts, :self_domain) || Application.get_env(:sukhi_fedi, :domain)

    payload =
      case opts[:sign_as] do
        nil -> %{raw: raw_json, selfDomain: self_domain}
        sign_as -> %{raw: raw_json, signAs: sign_as, selfDomain: self_domain}
      end

    case FedifyClient.inbox(payload) do
      {:ok, instruction} ->
        Instructions.execute(instruction, signer_host, author_signed?)
        :accepted

      {:error, reason} ->
        {:error, {:parse, reason}}
    end
  end

  # FEP-8b32 verdict, and the one place it is read:
  #
  #   :author_signed — a proof verified. `Oip.verify_inbound/1` binds the
  #     proof key's `controller` to the activity's own `actor`, so this
  #     says the *author* signed these exact bytes. Unlike the HTTP
  #     signature, that survives being forwarded by a third party, which
  #     is what lets a relayed post be believed without re-fetching it.
  #   :unproven — no proof, or only cryptosuites we don't implement.
  #   :failed — a proof we *can* check did not check out.
  @spec proof_verdict(term()) :: :author_signed | :unproven | :failed
  def proof_verdict(raw_json) when is_map(raw_json) do
    case SukhiFedi.Fedi.Oip.verify_inbound(raw_json) do
      :ok ->
        :author_signed

      :no_proof ->
        :unproven

      :no_checkable_proof ->
        Logger.info(
          "ingest: only unsupported-cryptosuite proofs on #{raw_json["id"]}; relying on the sender"
        )

        :unproven

      {:error, reason} ->
        Logger.warning(
          "ingest: object integrity proof failed (#{inspect(reason)}) on #{raw_json["id"]}"
        )

        :failed
    end
  end

  def proof_verdict(_), do: :unproven

  # The instance policy for the activity's actor host (the one place that
  # decision lives is `Moderation.instance_policy/1`). `:reject` is the only
  # value acted on here; `:silence`/`:pass` materialize.
  @spec policy(map()) :: :reject | :silence | :pass
  def policy(raw_json) when is_map(raw_json) do
    case raw_json |> Map.get("actor") |> actor_uri() |> uri_host() do
      host when is_binary(host) -> SukhiFedi.Addons.Moderation.instance_policy(host)
      _ -> :pass
    end
  end

  defp actor_uri(uri) when is_binary(uri), do: uri
  defp actor_uri(%{"id" => id}) when is_binary(id), do: id
  defp actor_uri(_), do: nil

  defp uri_host(uri) when is_binary(uri) do
    case URI.parse(uri) do
      %URI{host: h} when is_binary(h) and h != "" -> String.downcase(h)
      _ -> nil
    end
  end

  defp uri_host(_), do: nil
end
