# One-shot: fire `Update {Person}` to every known follower's inbox (+ relays)
# for a local account, without changing any profile field. Use to nudge a
# remote server with a stale cached actor -- they refresh the cached
# publicKey and HTTP-sig verification recovers.
#
#   bin/sukhi_fedi eval 'SukhiFedi.Release.run_script("broadcast_actor_update", ["nyanrus"])'
[username] = args

SukhiFedi.Accounts.broadcast_actor_update(username)
