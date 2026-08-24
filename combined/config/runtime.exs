# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Reuse the gateway's, delivery's and api's own runtime configs verbatim
# (import_config is not allowed in runtime.exs, so go through
# Config.Reader). Outside a repo checkout the tree is absent, so the
# three files have to be found somewhere else. In order:
#
#   1. RUNTIME_CONFIG_DIR — what combined/Dockerfile sets, pointing at
#      the copies it makes inside the image.
#   2. <release root>/runtime-configs — put there by the release's own
#      copy_runtime_configs step (mix.exs). This is the one that makes an
#      unpacked tarball work on its own, which is how DeployEx runs it.
#   3. the repo root — `make dev`, and anything else running from source.
import Config

release_root = System.get_env("RELEASE_ROOT")

dir =
  cond do
    dir = System.get_env("RUNTIME_CONFIG_DIR") -> dir
    release_root -> Path.join(release_root, "runtime-configs")
    true -> Path.expand("../..", __DIR__)
  end

for rel <- [
      "elixir/config/runtime.exs",
      "delivery/config/runtime.exs",
      "api/config/runtime.exs"
    ],
    {app, kv} <- Config.Reader.read!(Path.join(dir, rel), env: config_env()) do
  config app, kv
end
