This is the **friends** asset for TMC's **Dot** collection. It adds a player's friends list to a game, fully integrated with the TMC website's friends: who is online, what they are playing, on which server and in which party, whether they can be joined — and a "join" button that takes a player to where their friend is.

This collection of assets provides modular building blocks for creating games and applications within the TMC ecosystem, ensuring consistency and interoperability across all `dot-*` assets. This includes core functionality, networking, authentication, cloud integration, and more.

**These assets are COMPLETELY OPEN SOURCE**. You are free to use, modify, and distribute them under the terms of the MIT license. The only thing not open source is the back-end web infrastructure. So if you opt into using your own authentication backend instead of integrating with TMC, you will need to build and integrate your own back-end infrastructure.

## From Maintainer & WARNING
This asset, along with all the others, was built initially with **Claude Code** and will continue to be maintained and extended using it. This is because I (`gamemann`) cannot build the entire TMC platform alone (I wish I could lol).

**Please treat this as partially tested.** Every asset has its own headless test suite and those suites pass, but very little of this has been in front of real players yet. Expect rough edges, and please report anything you run into.

## The website owns the friends list; the game keeps a copy

Friendships live on the TMC website. That is where requests are sent and answered and where a friendship ends, and every game holds a snapshot that is only as fresh as its last poll. Every change is asked of a `DotFriendsBackend`, and the answer is what the website now says.

There are two backends, and a game holds one without knowing which:

| | |
| --- | --- |
| `DotFriendsBackendApp` | The website, as the signed-in player. |
| `DotFriendsBackendLocal` | The website's rules, run in-process, for a LAN, an offline build and the test suite. |

Refusals carry a reason key (`friends.request.deny.pending`, `presence.deny.detail`) in `DotError.detail`, from either backend, so a game can show its own text for each.

## Presence

A player's **presence** is what their friends see: offline, online, in game or away, which game, which server, which party, whether they can be joined, and one line the game writes ("Round 3 of 5").

`DotFriendsClient` posts it for you. It posts on a heartbeat, well inside the two minutes the website keeps a presence, and it posts straight away when something changes — but a burst of changes (joining a server sets the server, then the party, then "joinable") goes out as one post. A player who closes the game should be sent offline with `go_offline()`, or their friends will see them online for up to two more minutes.

A player who hides their activity on the website appears offline to everybody, and nothing else about where they are is shown.

## Joining a friend

`join(friend_user_id)` checks the friend's presence fresh — the list can be half a minute old — and then:

- joins their **party** if it is joinable and the game can join parties, or
- connects to their **server** if the game can connect to one (also when the party refuses, because the player asked to be where their friend is), or
- refuses with a reason: not a friend, offline, not joinable, or somewhere this game cannot follow.

dot-friends does not depend on [dot-party](https://github.com/modcommunity/dot-party) or on any connect code. You hand it two functions:

```gdscript
var friends := DotFriendsClient.new()
var app := DotFriendsBackendApp.new()
app.client = auth          # dot-auth's DotAuthClient: it holds the token and refreshes it
friends.backend = app
friends.join_party_fn = func(party_id: String, _friend: DotFriend) -> DotResult:
    return await party.join(party_id)          # a DotPartyClient, if the game has parties
friends.connect_fn = func(server_id: int, _friend: DotFriend) -> DotResult:
    return await game.connect_to_server(server_id)
add_child(friends)

friends.friend_online.connect(func(f: DotFriend): hud.toast("%s is online" % f.display_name))
friends.request_received.connect(func(r: DotFriendRequest): hud.toast("%s wants to be friends" % r.display_name))
party.joined_party.connect(func(p): friends.set_party(p.id))
```

## Events

`friend_added`, `friend_removed`, `friend_online`, `friend_offline`, `friend_presence_changed`, `request_received`, `requests_changed`, `friends_changed`, `presence_posted` and `request_failed`. The first poll after launch is quiet apart from `friends_changed`, so a game does not open with a "came online" toast for every friend already playing. Pending requests are announced the first time they are seen, including at launch.

## Installing

Copy `addons/dot_friends/` and [`dot-core`](https://github.com/modcommunity/dot-core)'s `addons/dot_core/` into your project and enable it in **Project → Project Settings → Plugins**.

## Dependencies

[dot-core](https://github.com/modcommunity/dot-core). Nothing else. dot-auth's client, dot-party's client and the game's connect code are reached by duck typing and never named.

## Licence

MIT. See [LICENSE](LICENSE).
