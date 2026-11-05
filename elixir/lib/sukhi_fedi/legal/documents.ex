# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.Legal.Documents do
  @moduledoc """
  The terms of service and privacy policy an instance serves, when they are its
  own.

  Terms and privacy policies differ from one instance to the next — who runs
  it, where, under which law, who to write to — so the release does not decide
  them. An operator puts their own Markdown in a directory and names it in the
  instance config:

      "legal": { "dir": "/etc/sukhi/legal" }

  holding `terms.<lang>.md` and `privacy.<lang>.md` for each language they
  offer (`ja`, `ko`, `en`), the same languages for both. They are read and
  rendered once, at boot, and kept; a request only picks one. The check is
  made here, once, and the gateway does not start on a missing directory, an
  empty or unreadable file, a document missing in a language, or a file in a
  language the pages cannot lay out: a policy page that quietly shows the wrong
  document is worse than no start.

  With no `legal.dir`, `LegalController` serves the documents bundled with the
  release (`priv/legal/`), which are the sukhi and natadeco wording and not
  anyone else's. The files are the operator's own, so their Markdown (raw HTML
  included) is rendered as written. Changing them takes a restart.
  """

  @docs [:terms, :privacy]
  @langs ~w(ja ko en)
  @key {__MODULE__, :documents}
  @opts %Earmark.Options{gfm: true, breaks: false}

  @type set :: %{terms: %{String.t() => String.t()}, privacy: %{String.t() => String.t()}}

  @doc "Languages the legal pages can be laid out in."
  @spec langs() :: [String.t()]
  def langs, do: @langs

  @doc """
  Read the operator's documents named by the instance config and keep them.
  `:bundled` when the config names no directory (and forgets any kept set).
  Raises `ArgumentError` with the next step when the directory is not usable.
  """
  @spec install!(SukhiShared.InstanceConfig.t()) :: :bundled | {:custom, String.t()}
  def install!(instance_config) do
    case SukhiShared.InstanceConfig.legal_dir(instance_config) do
      nil ->
        :persistent_term.erase(@key)
        :bundled

      dir ->
        :persistent_term.put(@key, load!(dir))
        {:custom, dir}
    end
  end

  @doc "The kept set, or `nil` when the instance serves the bundled documents."
  @spec all() :: set() | nil
  def all, do: :persistent_term.get(@key, nil)

  @doc "Read and render the documents in `dir`. Does not touch the kept set; `install!/1` does."
  @spec load!(String.t()) :: set()
  def load!(dir) do
    names =
      case File.ls(dir) do
        {:ok, names} -> names
        {:error, reason} -> fail(dir, "cannot read it (#{:file.format_error(reason)})")
      end

    found =
      for name <- Enum.sort(names),
          [_, doc, lang] <- [Regex.run(~r/\A(terms|privacy)\.([a-z]{2,3})\.md\z/, name)] do
        unless lang in @langs do
          fail(
            dir,
            "#{name}: unsupported language #{lang} (supported: #{Enum.join(@langs, ", ")})"
          )
        end

        {String.to_existing_atom(doc), lang, render!(dir, name)}
      end

    set =
      for doc <- @docs, into: %{} do
        {doc, for({^doc, lang, html} <- found, into: %{}, do: {lang, html})}
      end

    for doc <- @docs, map_size(set[doc]) == 0 do
      fail(dir, "no #{doc}.<lang>.md")
    end

    if Enum.sort(Map.keys(set.terms)) != Enum.sort(Map.keys(set.privacy)) do
      fail(
        dir,
        "terms (#{langs_of(set.terms)}) and privacy (#{langs_of(set.privacy)}) " <>
          "must cover the same languages"
      )
    end

    set
  end

  defp langs_of(docs), do: docs |> Map.keys() |> Enum.sort() |> Enum.join(", ")

  defp render!(dir, name) do
    markdown =
      case File.read(Path.join(dir, name)) do
        {:ok, body} -> body
        {:error, reason} -> fail(dir, "#{name}: cannot read it (#{:file.format_error(reason)})")
      end

    unless String.valid?(markdown), do: fail(dir, "#{name} is not UTF-8")
    if String.trim(markdown) == "", do: fail(dir, "#{name} is empty")

    case Earmark.as_html(markdown, @opts) do
      {:ok, html, _} -> String.replace(html, "​", "<wbr>")
      {:error, _, messages} -> fail(dir, "#{name} does not render: #{inspect(messages)}")
    end
  end

  defp fail(dir, why) do
    raise ArgumentError,
          "legal documents in #{dir}: #{why}. Put terms.<lang>.md and privacy.<lang>.md " <>
            "(#{Enum.join(@langs, "/")}) there, readable by the sukhi user, or remove " <>
            "legal.dir from the instance config to serve the bundled documents."
  end
end
