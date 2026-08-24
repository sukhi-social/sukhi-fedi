# SPDX-License-Identifier: AGPL-3.0-or-later
#
# With path deps only the top project's config is evaluated, so pull in
# each project's own config file — they stay the single source of
# truth. Each one ends by importing its own "#{config_env()}.exs",
# which resolves relative to that file. App env keys are namespaced
# per app (:sukhi_fedi / :sukhi_delivery / :sukhi_api), so the three
# merge cleanly.
import Config

import_config "../../elixir/config/config.exs"
import_config "../../delivery/config/config.exs"
import_config "../../api/config/config.exs"
