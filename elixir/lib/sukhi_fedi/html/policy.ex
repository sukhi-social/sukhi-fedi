# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule SukhiFedi.HTML.Policy do
  @moduledoc """
  The allow-list, as data. Everything a sanitiser needs to know and nothing
  about how it works — so every implementation (`HTML.Sanitizer.*`) is built
  from this one table and none can disagree with another about what is
  allowed.

  Mirrors Mastodon's permitted tag set, plus `ruby`/`rt`/`rp` (Japanese ruby
  annotations are common here). Anything not listed is dropped, including
  every event-handler and `style` attribute.

  Each tag maps to its allowed plain attributes (`attrs`) and, for the ones
  that carry a URL, which URL attributes are allowed with which schemes
  (`uri`). Links are http(s)/mailto only — that is what blocks `javascript:`
  and `data:` hrefs. `class`/`rel`/`title` stay on links because mentions,
  hashtags and link cards style off them; mentions and hashtags wrap their
  text in `<span class="...">`.
  """

  @type tag_spec :: %{required(:attrs) => [String.t()], optional(:uri) => %{String.t() => [String.t()]}}

  @plain ~w(p br b strong i em u s del ins sub sup code pre blockquote ul ol li ruby rt rp h1 h2 h3 h4)

  @spec tags() :: %{String.t() => tag_spec()}
  def tags do
    @plain
    |> Map.new(&{&1, %{attrs: []}})
    |> Map.put("a", %{
      attrs: ["name", "title", "class", "rel"],
      uri: %{"href" => ["http", "https", "mailto"]}
    })
    |> Map.put("span", %{attrs: ["class"]})
  end
end
