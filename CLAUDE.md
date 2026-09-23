# dot-friends

The player's friends list and presence, from the TMC backbone: who is online, in which game, on which server and in which party, whether they can be joined — and "join my friend", which hands off to the game's party or connect code without naming either.

**The distributable is `addons/dot_friends/`.** It requires [dot-core](../dot-core), a separate repository, and nothing else. dot-auth's client, dot-party's client and the game's connect function are reached by duck typing and never named.

```bash
ln -s ../../dot-core/addons/dot_core addons/dot_core
```

## Why this exists, and what already existed

website-city has had friends for a long time — `UserFriendship`, one row per pair, requests with a decline cooldown, a friends dock that polls every page — but only through tRPC behind the website's session cookie, which a game client does not hold. It had **no presence at all** in the sense a game needs: the dock infers "active / idle / away" from the last page visit, which says nothing about which server somebody is on or whether they can be joined. The app routes and the presence table were specified with this addon and written on the site at the same time; [docs/backbone-contract.md](docs/backbone-contract.md) is the contract both sides were built against.

## The pieces

| | |
| --- | --- |
| `DotPresence` | Where one person is: status, app, server, party, joinable, a line of detail, when. Offline is a blank. |
| `DotFriend` | One friend and their presence, as `GET friends` returns them. |
| `DotFriendRequest` | One pending request, incoming or outgoing, with the site's integer id. |
| `DotFriendsBackend` | The interface. Every method may await; call them all with `await`. |
| `DotFriendsBackendApp` | The site as the player, through dot-auth's `post_app`/`get_app` (preferred), a token and a `DotHttp`, or `request_fn`. |
| `DotFriendsLocalHub`, `DotFriendsBackendLocal` | The site's rules in-process. LAN, offline, suites. One hub, one backend per person. |
| `DotFriendsConfig` | Poll, heartbeat and debounce timings, layered like every `DotConfig`. |
| `DotFriendsClient` | The player's node: polls, posts presence, diffs snapshots into signals, joins a friend. |

## Decisions

### The request rules are the site's, read rather than guessed

`DotFriendsLocalHub` follows `src/server/api/routers/user/social/friend.ts`: asking somebody who already asked you **accepts** them (the site's comment: "what the user obviously means"); only the declined sender waits seven days, and the one who declined may always ask; a re-request re-uses the row, turned round to face the new asker; only the addressee may answer, and everything else is "not found" rather than "not yours", so a requester cannot decline their own request into a cooldown against the person they asked; removing deletes the row. The cooldown and the row re-use were not in the specification this addon was written from; they are on the site.

### Offline is a blank

An expired presence, an explicit "offline" post and a member who hides their activity all read the same: every field null, not joinable, no timestamp. The alternative — "offline, last on server 12" — is a hidden player whose server is shown to everybody. `DotPresence.has_destination()` is false for all three, so nothing downstream can follow one.

### Presence is posted on a heartbeat and on an edge, debounced from the first change

45 s against the site's 120 s leaves room for two lost posts; `DotFriendsConfig.validate()` refuses a heartbeat over half the lifetime, and the client shortens the heartbeat to 40% of any shorter `ttlSec` the site answers with. A change waits `presence_debounce_sec` counted from the **first** change of a burst, so joining a server (server, then party, then joinable) is one post, and a stream of changes cannot postpone the post forever. A burst that ends where it started posts nothing. `go_offline()` posts at once and stops the heartbeat, because a game that just quits leaves its friends a two-minute window to try to join a player who is gone.

### `same_as` ignores `updatedAt`

The timestamp moves on every heartbeat. Diffing on it would announce "presence changed" for every friend every 45 seconds; the suite's "a heartbeat that moves only the timestamp is nothing" check fails when it is put back.

### The first snapshot is quiet; requests are not

A game that toasted "came online" for every friend already online at launch would open on a wall of toasts, so the first list emits only `friends_changed`. A pending request is an inbox rather than a status — one that arrived while the game was closed is still news — so `request_received` fires for each the first time it is seen, launch included. Answered ones are forgotten, because the site re-uses a row's id when a declined sender asks again a week later.

### `join` asks before it goes

The list is polled every 30 s. `join()` spends one `GET presence` on the one friend first, and refuses on what is true now rather than on what the list said: a party that ended, a friend who turned joinable off, or a friendship that ended since the last poll. It prefers the party (`join_party_fn`) and falls back to the server (`connect_fn`) — also when the party refuses, since the player asked to be where their friend is — keeping the party's refusal in the value as `partyRefused`. With neither route possible it refuses with `friends.join.deny.unsupported` rather than pretending.

### `GET presence` leaves strangers out rather than answering offline

"Offline" still confirms that an id is somebody. The hub omits non-friends, and the contract asks the site to do the same.

### Refusal keys are this addon's proposal

The site's friend procedures throw English messages, not keys. The keys in the contract's table are what the hub uses and what the app routes were asked to send; **they were not checked against shipped site code, because there was none yet**. When the routes land, compare the keys first.

## What building it found

**The site's friend refusals are not keys.** Every refusal in `friend.ts` is a tRPC code with an English message. dot-party could check its keys against `locales/en/party.json`; here there was nothing to check against, so the keys are a proposal and the contract says so in its own table.

**Site rules the specification did not spell out**, all from reading the router: a request to somebody who asked you is an accept, the decline cooldown binds only the declined sender, and a re-request re-uses and re-orients the row. A hub without them would have refused crossed requests as `pending` and could have put the wrong person on cooldown. Request ids are also **integers** on the site (`UserFriendship.id`); the specification's `{id}` did not say which, and a string id sent back to a zod `number()` would be refused, so `DotFriendRequest.id` is an `int` and the suite checks `requestId` goes out as one.

**The suite's own expiry check failed first, correctly.** "A friend whose presence expired goes offline" advanced 100 s past a heartbeat made at +30, so the friend still had 20 s left. The addon was right; the test's arithmetic was not. It now advances 121 s past the last post, with a comment saying which post.

**`DotResult.wrap` puts the cause in `detail`, which is where a refusal key lives.** Read in dot-party's app backend, not found by running: its 404 hint wraps the result, so `error.detail` becomes `"[invalid] Not found."`, and a caller that treats `detail` as an i18n key looks that up. Here the 404 hint clears `detail`, and the suite checks that a bare 404 "invents no key". dot-party was not changed; it is worth the same two lines there.

**Every guard was armed.** Raising CHECKS by one exits 1; removing the debounce fails three checks and aborts section 6 part-way (an index past the end of the post list), which only the CHECKS total reports — "112 checks ran, 125 expected"; skipping `join`'s fresh presence fails three; diffing on `updatedAt` fails two; not collapsing a burst that returns to where it started fails eight. Each was put back and the suite re-run clean.

**No native shadowing.** Every `func`, `var` and `signal` was compared against ClassDB's lists for `Node`, `RefCounted` and `Resource`; none collides. `connect_fn` is deliberately not `connect`, and the client has no `is_connected`.

## Things deliberately not here

- **The site's routes.** Specified, not written; website-city is its own repository.
- **Cancelling an outgoing request, blocking, friend search and suggestions.** The site has all four behind tRPC; none is in the app contract yet. A game that needs one adds a route to the contract first.
- **A friends UI.** dot-ui draws; this emits.
- **Push.** The site pushes nothing to a game, so this polls. A socket would replace the poll in `DotFriendsClient` and nothing else.
- **Turning a server id into an address.** A presence carries the site's server id; `connect_fn` is the game's, usually through dot-browser or the site's connect route.

## Validating

```bash
godot --headless --path . --import
find . -name '*.gd' -not -path './.godot/*' | while read f; do
    godot --headless --path . --check-only --script "res://${f#./}"
done
timeout 120 godot --headless --path . res://examples/friends_selftest.tscn
```

9 sections, 125 checks, no network, nothing written to `user://`, and an empty stderr. **Sections 6 and 7 are the ones to keep**: 6 is a player staying online to their friends on a heartbeat inside the site's lifetime, with a burst of changes posted once; 7 is "join" taking somebody to their friend's party or server, or saying honestly why not.
