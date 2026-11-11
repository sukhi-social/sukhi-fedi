# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Fedi.DeliverySuspension.Hint do
  @moduledoc """
  A delivery answered with `Link: <notice>; rel="…#deliverySuspension"`
  (`SukhiShared.DeliverySuspension.Hint`; the delivery node passes the address
  on). This goes and looks.

  The Link is **a hint, not an authority**. What is fetched is judged by the
  same `Receiver` as a notice that came to the inbox, and no more kindly:

    * the document must say it is that URL (`id` = the Link's target), and
      be a `DeliverySuspension`;
    * it is read as if it had been signed by the host it was served from, so
      the controller (`attributedTo`) has to be on that host, and the notice's
      `id` has to be the controller's own: a server cannot point us at someone
      else's notice, or have us believe a document served from elsewhere;
    * a notice we did not know is not taken until `Control` has confirmed the
      controller speaks for the target by reading the web fresh: a hint on its
      own suspends nothing;
    * what we already hold is compared as usual (a cancellation is final, an
      older revision is stale, the same content changes nothing).

  The fetch is `Fetch` (HTTPS, public addresses, 64 KiB, depth 8, 10 s).
  The delivery node makes the job unique by address for ten minutes, so a
  server that says it on every answer costs one fetch. A document that cannot
  be read is tried again (an `:unavailable` server may be the one that is
  resting); one that is read and refused is not.

  Without the graph store there is nowhere to keep a notice, and the job does
  nothing.
  """

  use Oban.Worker, queue: :suspension_hint, max_attempts: 3

  require Logger

  alias SukhiFedi.Fedi.DeliverySuspension.{Fetch, Receiver}
  alias SukhiFedi.Graph
  alias SukhiShared.DeliverySuspension.{Notice, Origin}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"url" => url}}) when is_binary(url) do
    if Graph.enabled?() do
      case run(url, DateTime.utc_now()) do
        {:error, {:unreachable, :unavailable}} -> {:error, "notice unavailable"}
        _ -> :ok
      end
    else
      :ok
    end
  end

  def perform(_job), do: :ok

  @doc """
  Fetch the notice at `url` and hand it to the `Receiver`. Returns the
  `Receiver`'s answer, or `{:error, {:unreachable, why}}` / `{:error, why}`
  for what happened before it. Options are `Receiver`'s (`:control`, `:policy`,
  `:fetch_key`), `:http` for the transport (tests), and `:now`.
  """
  @spec run(String.t(), DateTime.t(), keyword()) :: Receiver.result() | {:error, term()}
  def run(url, %DateTime{} = now, opts \\ []) do
    result =
      with {:ok, %{document: document, url: final}} <- read(url, opts),
           :ok <- says_it_is(document, url),
           :ok <- same_origin(final, url),
           {:ok, controller} <- controller(document) do
        activity = %{
          "id" => url <> "#hint",
          "type" => "Create",
          "actor" => controller,
          "object" => document
        }

        Receiver.handle(
          activity,
          Keyword.merge(
            [signer_host: URI.parse(final).host, now: now],
            Keyword.take(opts, [:control, :policy, :fetch_key])
          )
        )
      end

    announce(url, result)
    result
  end

  defp read(url, opts) do
    case Fetch.get(url, :activity, Keyword.take(opts, [:policy, :http])) do
      {:ok, ok} -> {:ok, ok}
      {:error, why} -> {:error, {:unreachable, why}}
      :not_modified -> {:error, {:unreachable, :unavailable}}
    end
  end

  defp says_it_is(%{"id" => url} = document, url) do
    if Notice.notice?(document), do: :ok, else: {:error, :not_a_notice}
  end

  defp says_it_is(_document, _url), do: {:error, :id_is_not_the_link}

  # A redirect may move the document inside the origin it was promised from,
  # not out of it.
  defp same_origin(final, url) do
    if Origin.of_delivery_url(final) == Origin.of_delivery_url(url),
      do: :ok,
      else: {:error, :moved_to_another_origin}
  end

  defp controller(%{"attributedTo" => id}) when is_binary(id), do: {:ok, id}
  defp controller(%{"attributedTo" => %{"id" => id}}) when is_binary(id), do: {:ok, id}
  defp controller(_document), do: {:error, :no_controller}

  # Refused before the Receiver is what the Receiver's own log line is for what
  # it refuses: one place to look either way.
  defp announce(url, result) do
    {status, detail} =
      case result do
        {:ok, outcome} -> {:ok, outcome}
        {:error, why} -> {:error, why}
        :pass -> {:error, :not_ours}
      end

    :telemetry.execute([:sukhi_fedi, :delivery_suspension, :hint], %{count: 1}, %{
      status: status,
      detail: detail
    })

    if status == :error,
      do: Logger.info("delivery_suspension: hint #{inspect(url)} not taken: #{inspect(detail)}")

    :ok
  end
end
