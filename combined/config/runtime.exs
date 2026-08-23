# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Reuse the gateway's, delivery's and api's own runtime configs verbatim
# (import_config is not allowed in runtime.exs, so go through
# Config.Reader). Inside the release image the repo tree is absent;
# the Dockerfile copies the three files under RUNTIME_CONFIG_DIR with
# the same relative layout. In local dev the repo root is the default.
import Config

dir = System.get_env("RUNTIME_CONFIG_DIR", Path.expand("../..", __DIR__))

for rel <- [
      "elixir/config/runtime.exs",
      "delivery/config/runtime.exs",
      "api/config/runtime.exs"
    ],
    {app, kv} <- Config.Reader.read!(Path.join(dir, rel), env: config_env()) do
  config app, kv
end
