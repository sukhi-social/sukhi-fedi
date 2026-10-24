# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule PullFederation.Proof do
  @moduledoc """
  A signature on each activity (the shape of FEP-8b32 `eddsa-jcs-2022`),
  so an activity authenticates itself wherever it travels: in a pull
  stream, a push body, or a copy served by someone else.

  `sign/4` adds `:actor` and `:proof` (`%{key: key_id, sig: bytes}`).
  The signed bytes cover every field except `:proof`, `:actor` included,
  so an activity cannot be relabelled to another actor.

  `verifier/1` returns the single check `Puller` runs on every activity,
  pulled or pushed (`Puller.apply_activity/3`). The key is looked up by
  *actor*, from `keys` (`actor => public key`, standing in for the actor
  document, fetched once per actor and cached). A stream's origin therefore
  cannot forge activities of an actor whose key it does not hold.

  The prototype canonicalises with Erlang's deterministic term encoding;
  a real implementation uses JCS (RFC 8785) as `Fedi.Oip` does.
  """

  def keypair do
    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
    %{public: pub, private: priv}
  end

  def sign(activity, actor, key_id, private) do
    doc = activity |> Map.drop([:proof]) |> Map.put(:actor, actor)
    sig = :crypto.sign(:eddsa, :none, message(doc), [private, :ed25519])
    Map.put(doc, :proof, %{key: key_id, sig: sig})
  end

  @doc "`keys` is `%{actor => public_key}`; the result is `(activity -> :ok | :error)`."
  def verifier(keys) do
    fn
      %{actor: actor, proof: %{sig: sig}} = act ->
        with {:ok, pub} <- Map.fetch(keys, actor),
             true <-
               :crypto.verify(:eddsa, :none, message(Map.delete(act, :proof)), sig, [
                 pub,
                 :ed25519
               ]) do
          :ok
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp message(doc), do: :erlang.term_to_binary(doc, [:deterministic])
end
