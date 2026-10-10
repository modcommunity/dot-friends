# dot-friends

The player's friends list and presence, from the TMC backbone: who is online, in which game, on which server and in which party, whether they can be joined, and "join my friend", which hands off to the game's party or connect code without naming either.

Read the family [CLAUDE.md](../../CLAUDE.md) first; this file is only what is specific to friends. Anything that talks to website-city: [game-dev/docs/backbone.md](../../docs/backbone.md).

**The distributable is `addons/dot_friends/`.** It requires [dot-core](../dot-core) and nothing else (`ln -s ../../dot-core/addons/dot_core addons/dot_core`, gitignored). dot-auth's client, dot-party's client and the game's connect function are reached by duck typing and never named.

## Read before

| Read | Before |
| --- | --- |
| [docs/backbone-contract.md](docs/backbone-contract.md) | touching the app backend or the hub: routes, shapes, presence rules, refusal keys, the site rules copied here |
| [docs/design.md](docs/design.md) | anything: the site's request rules, blank offline, heartbeat and debounce, quiet first snapshot, join, keys in `detail`, what is not here |
| [docs/history.md](docs/history.md) | what building it found |

## Layout

| Path | What |
| --- | --- |
| `core/dot_presence.gd` | `DotPresence`: status, app, server, party, joinable, detail, when. Offline is a blank. `same_as`, `has_destination` |
| `core/dot_friend.gd` | `DotFriend`: one friend and their presence, as `GET friends` returns them |
| `core/dot_friend_request.gd` | `DotFriendRequest`: one pending request, incoming or outgoing; integer id |
| `backend/dot_friends_backend.gd` | `DotFriendsBackend`: the interface. Every method may await; call them all with `await` |
| `backend/dot_friends_backend_app.gd` | `DotFriendsBackendApp`: the site as the player, through dot-auth's `post_app`/`get_app` (preferred), a token and a `DotHttp`, or `request_fn` |
| `backend/dot_friends_local_hub.gd`, `dot_friends_backend_local.gd` | the site's rules in-process: LAN, offline, suites. One hub, one backend per person |
| `dot_friends_config.gd` | `DotFriendsConfig`: poll, heartbeat and debounce timings |
| `runtime/dot_friends_client.gd` | `DotFriendsClient`: the player's node. Polls, posts presence, diffs snapshots into signals, joins a friend |
| `examples/friends_selftest.tscn` | the suite; no network, nothing written to `user://` |

Paths except `examples/` and `docs/` are in `addons/dot_friends/`.

## Running and testing

The family's two steps ([game-dev/CLAUDE.md](../../CLAUDE.md#validating-anything)), then `timeout 120 godot --headless --path . res://examples/friends_selftest.tscn`; stderr should be empty. The sections to keep above all are the heartbeat one (a player stays online inside the site's lifetime, a burst of changes posted once) and the join one (their party, then their server, or an honest no).

## Rules that bite

- `DotFriendsLocalHub` is the site's friend router rule for rule; a change on the site needs the same change here, in the contract and in the suite. [contract](docs/backbone-contract.md#what-dot-friends-duplicates-on-purpose)
- Refusal keys are the site's (`locales/en/friends.json`); `friends.join.deny.*` are this addon's. Never put anything but a key in `detail`. [design](docs/design.md#refusals-carry-keys-and-detail-stays-a-key)
- Offline is blank, for expiry, an offline post and a hidden member alike. [design](docs/design.md#offline-is-a-blank)
- Heartbeat at most half the site's lifetime (`validate()`); debounce from the first change of a burst; `go_offline()` posts at once. [design](docs/design.md#presence-is-posted-on-a-heartbeat-and-on-an-edge)
- `same_as` ignores `updatedAt`. [design](docs/design.md#same_as-ignores-updatedat)
- The first snapshot emits only `friends_changed`; `request_received` fires for every request first seen, launch included. [design](docs/design.md#the-first-snapshot-is-quiet-requests-are-not)
- `join()` fetches the friend's presence first, prefers the party, falls back to the server. [design](docs/design.md#join-asks-before-it-goes)
- A bare 404 means no routes: one INFO line, not a WARN. [design](docs/design.md#a-site-without-the-routes-is-one-info-line)
- Request ids are integers; party ids are decimal strings. [contract](docs/backbone-contract.md#shapes)
- No member named after an `Object` method (`connect_fn`, never `connect`). [design](docs/design.md#no-native-shadowing)

Deliberately not here: the site's routes, blocking and search, a UI, push, server addresses. [design](docs/design.md#deliberately-not-here)
