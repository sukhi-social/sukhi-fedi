# SPDX-License-Identifier: AGPL-3.0-or-later
# Measured cost of the signatures involved (this machine, one core).
# Run: mix run bench/sign.exs
n = 500
msg = :crypto.strong_rand_bytes(600)

time = fn f ->
  {us, _} = :timer.tc(fn -> for _ <- 1..n, do: f.() end)
  Float.round(us / n, 1)
end

{epub, epriv} = :crypto.generate_key(:eddsa, :ed25519)
esig = :crypto.sign(:eddsa, :none, msg, [epriv, :ed25519])
{rpub, rpriv} = :crypto.generate_key(:rsa, {2048, 65537})
rsig = :crypto.sign(:rsa, :sha256, msg, rpriv)

t = %{
  ed_sign: time.(fn -> :crypto.sign(:eddsa, :none, msg, [epriv, :ed25519]) end),
  ed_verify: time.(fn -> :crypto.verify(:eddsa, :none, msg, esig, [epub, :ed25519]) end),
  rsa_sign: time.(fn -> :crypto.sign(:rsa, :sha256, msg, rpriv) end),
  rsa_verify: time.(fn -> :crypto.verify(:rsa, :sha256, msg, rsig, rpub) end)
}

IO.puts("us per operation: #{inspect(t)}")
IO.puts("signature bytes: ed25519 #{byte_size(esig)} (base64 #{byte_size(Base.encode64(esig))}), rsa-2048 #{byte_size(rsig)} (base64 #{byte_size(Base.encode64(rsig))})")

# One post to D follower domains, and the same window of P posts read in one stream.
IO.puts("\nCPU per post for the whole federation (ms), per signature scheme; D = follower domains")
IO.puts("push: origin signs one HTTP request per domain (RSA), each domain verifies it")
IO.puts("pull: origin signs the activity once (Ed25519); each domain signs its pull request (RSA),")
IO.puts("      origin verifies it, domain verifies the activity (Ed25519); one pull carries P posts\n")

for d <- [10, 1_000, 100_000], p <- [1, 10] do
  push = d * (t.rsa_sign + t.rsa_verify)
  pull_origin = t.ed_sign + d * t.rsa_verify / p
  pull_recv = d * (t.rsa_sign / p + t.ed_verify)
  pull = pull_origin + pull_recv

  IO.puts(
    "  D=#{String.pad_leading(Integer.to_string(d), 6)} P=#{String.pad_leading(Integer.to_string(p), 2)}:" <>
      " push #{Float.round(push / 1000, 1)} ms (origin #{Float.round(d * t.rsa_sign / 1000, 1)})" <>
      "   pull #{Float.round(pull / 1000, 1)} ms (origin #{Float.round(pull_origin / 1000, 1)})"
  )
end
