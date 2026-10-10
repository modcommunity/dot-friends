# Design

Why dot-friends is shaped the way it is, and why the obvious alternative is wrong in each case. The wire is in [backbone-contract.md](backbone-contract.md).

## Why this exists

website-city has had friends for a long time (`UserFriendship`, one row per pair, requests with a decline cooldown, a friends dock) but only through tRPC behind the website's session cookie, which a game client does not hold. It had no presence in the sense a game needs: the dock infers "active / idle / away" from the last page visit, which says nothing about which server somebody is on or whether they can be joined. The app routes and the presence table were specified with this addon and written on the site at the same time.

## The request rules are the site's, read rather than guessed

`DotFriendsLocalHub` follows the site's friend router: asking somebody who already asked you **accepts** them ("what the user obviously means"); only the declined sender waits seven days, and the one who declined may always ask; a re-request re-uses the row, turned round to face the new asker; only the addressee may answer, and everything else is "not found" rather than "not yours", so a requester cannot decline their own request into a cooldown against the person they asked; removing deletes the row; a sender may withdraw a pending request (`cancel_request`), leaving no cooldown. Request ids are the site's integers (`UserFriendship.id`), so `DotFriendRequest.id` is an `int` and goes back as `requestId` unchanged.

It is a copy for the reason dot-party's local hub is: a LAN with no website still has to answer these questions, and a game developed against one set of rules must not meet a different set on launch day.

## Offline is a blank

An expired presence, an explicit "offline" post and a member who hides their activity all read the same: every field null, not joinable, no timestamp. The alternative ("offline, last on server 12") is a hidden player whose server is shown to everybody. `DotPresence.has_destination()` is false for all three, so nothing downstream can follow one.

## Presence is posted on a heartbeat and on an edge

45 s against the site's 120 s leaves room for two lost posts; `DotFriendsConfig.validate()` refuses a heartbeat over half the lifetime, and the client shortens the heartbeat to 40% of any shorter `ttlSec` the site answers with.

A change waits `presence_debounce_sec` counted from the **first** change of a burst, so joining a server (server, then party, then joinable) is one post, and a stream of changes cannot postpone the post forever. A burst that ends where it started posts nothing. `go_offline()` posts at once and stops the heartbeat, because a game that just quits leaves its friends a two-minute window to try to join a player who is gone.

## `same_as` ignores `updatedAt`

The timestamp moves on every heartbeat. Diffing on it would announce "presence changed" for every friend every 45 seconds.

## The first snapshot is quiet; requests are not

A game that toasted "came online" for every friend already online at launch would open on a wall of toasts, so the first list emits only `friends_changed`. A pending request is an inbox rather than a status (one that arrived while the game was closed is still news), so `request_received` fires for each the first time it is seen, launch included. Answered ones are forgotten, because the site re-uses a row's id when a declined sender asks again a week later.

## `join` asks before it goes

The list is polled every 30 s. `join()` spends one `GET presence` on the one friend first, and refuses on what is true now rather than on what the list said: a party that ended, a friend who turned joinable off, or a friendship that ended since the last poll. It prefers the party (`join_party_fn`) and falls back to the server (`connect_fn`), also when the party refuses, since the player asked to be where their friend is, keeping the party's refusal in the value as `partyRefused`. With neither route possible it refuses with `friends.join.deny.unsupported` rather than pretending.

## `GET presence` leaves strangers out rather than answering offline

"Offline" still confirms that an id is somebody. The hub omits non-friends, and the site does the same.

## Refusals carry keys, and `detail` stays a key

The site's app routes send refusal keys from its `locales/en/friends.json`; the hub uses the same ones, and the `friends.join.deny.*` keys are this addon's own, for `join()`. `DotResult.wrap` puts the cause in `detail`, which is where a refusal key lives, so the app backend's 404 handling clears `detail` rather than wrapping: a caller that treats `detail` as an i18n key must never be handed `"[invalid] Not found."`.

## A site without the routes is one INFO line

A bare 404 is a site that does not serve the routes, not an outage. `_call` says so once at INFO, then DEBUG, on a flag of its own (`_no_routes`) so a real outage later is still a WARN; a call that succeeds afterwards says "answering again", as it does after an outage.

## No native shadowing

`connect_fn` is deliberately not `connect`, and the client has no `is_connected`: both are `Object` methods. Check a new member name against ClassDB's lists for `Node`, `RefCounted` and `Resource` ([gdscript-hazards.md](../../../docs/gdscript-hazards.md)).

## Deliberately not here

- **The site's routes.** website-city is its own repository; they are documented in its `docs/api/app-social.md`. Deployment is the operator's.
- **Blocking, friend search and suggestions.** The site has all three behind tRPC; none is in the app contract yet. A game that needs one adds a route to the contract first.
- **A friends UI.** dot-ui draws; this emits.
- **Push.** The site pushes nothing to a game, so this polls. A socket would replace the poll in `DotFriendsClient` and nothing else.
- **Turning a server id into an address.** A presence carries the site's server id; `connect_fn` is the game's, usually through dot-browser or the site's connect route.
