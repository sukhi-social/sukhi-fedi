# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule Mix.Tasks.Sukhi.Suspension.Prepare do
  @moduledoc """
  Make the FEP-f799 notices for a maintenance, **before** the work
  (docs/DELIVERY_SUSPENSION.md, "告げる側").

      mix sukhi.suspension.prepare --account ops --minutes 60 --out ./suspension

  Options:

      --account NAME     the local account that speaks (required); its Ed25519 key signs
      --minutes N        how long we think it takes (required); the notice ends with room to spare
      --out DIR          where the files go (required)
      --origin URL       what rests (default: this whole server, https://DOMAIN)
      --inbox URL        rest one inbox instead of the origin
      --summary TEXT     one human line (≤ 200 characters)
      --url URL          a page for the state of things
      --margin X         room to spare, a multiplier (default 1.5)
      --domain HOST      default: the configured DOMAIN

  Writes under DIR:

      public/suspensions/<slug>.json   the notice. Serve it where it can be read while we sleep
      send/<slug>.create.json          the Create, sent to peers when the resting starts
      held/<slug>.cancel.json          the cancellation, signed now. Publish it when the work is done
      held/<slug>.undo.json            the Undo of the Create, sent after

  Nothing is sent or published here. The private key is read once, now; it is
  not needed while the application sleeps.
  """

  use Mix.Task

  @shortdoc "Make FEP-f799 maintenance notices (signed ahead of the work)"

  @impl Mix.Task
  def run(args) do
    {opts, _argv, _} =
      OptionParser.parse(args,
        strict: [
          account: :string,
          minutes: :float,
          out: :string,
          origin: :string,
          inbox: :string,
          summary: :string,
          url: :string,
          margin: :float,
          domain: :string
        ]
      )

    with {:ok, name} <- required(opts, :account),
         {:ok, minutes} <- required(opts, :minutes),
         {:ok, out} <- required(opts, :out) do
      Mix.Task.run("app.config")
      {:ok, _} = Application.ensure_all_started(:sukhi_fedi)
      prepare(name, minutes, out, opts)
    else
      {:error, key} -> Mix.raise("--#{key} is required (see `mix help sukhi.suspension.prepare`)")
    end
  end

  defp prepare(name, minutes, out, opts) do
    domain = opts[:domain] || Application.get_env(:sukhi_fedi, :domain)

    account = SukhiFedi.Accounts.by_local_username(name)

    unless account && account.ed25519_private_key_jwk do
      Mix.raise("no local account #{inspect(name)} with an Ed25519 key")
    end

    target =
      cond do
        opts[:inbox] -> {:inbox, opts[:inbox]}
        true -> {:origin, opts[:origin] || "https://#{domain}"}
      end

    result =
      SukhiFedi.Fedi.DeliverySuspension.Publisher.prepare(
        domain: domain,
        controller: "https://#{domain}/users/#{name}",
        private_jwk: account.ed25519_private_key_jwk,
        public_multibase: account.ed25519_public_multibase,
        target: target,
        expected_minutes: minutes,
        now: DateTime.utc_now(),
        summary: opts[:summary],
        url: opts[:url],
        margin: opts[:margin] || 1.5
      )

    case result do
      {:ok, made} ->
        for {path, bytes} <- made.files do
          full = Path.join(out, path)
          File.mkdir_p!(Path.dirname(full))
          File.write!(full, bytes)
          Mix.shell().info("wrote #{full}")
        end

        Mix.shell().info("The notice ends at #{DateTime.to_iso8601(made.ends_at)} on its own.")

      {:error, reason} ->
        Mix.raise("could not prepare: #{inspect(reason)}")
    end
  end

  defp required(opts, key) do
    case opts[key] do
      nil -> {:error, key}
      value -> {:ok, value}
    end
  end
end
