extends Node

## Exercises dot-friends with no network: a hub, several people, their clients, and a fake site.
##
## [b]Section 1 parses the contract's own JSON[/b], field for field, because a parser checked
## only against JSON this suite wrote from the parser would agree with itself about a shape
## the site does not send.
##
## [b]Sections 6 and 7 are the ones to keep.[/b] 6 is the promise that a player stays online to
## their friends — a heartbeat inside the site's lifetime, a change posted once rather than
## three times — and 7 is the promise that "join" takes somebody to where their friend is,
## or says honestly why it cannot.
##
## [codeblock]
## godot --headless --path . res://examples/friends_selftest.tscn
## [/codeblock]

const SECTIONS := 9
const CHECKS := 125

var _passed := 0
var _failed := 0
var _section_count := 0

## Captured by lambdas, so a container rather than a scalar.
var _now: Array[int] = [1_790_000_000]


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	await _run()


func _run() -> void:
	_line("dot-friends self-test")
	_line("")

	_test_shapes()
	_test_requests()
	_test_presence_privacy()
	_test_ttl()
	await _test_client_diff()
	await _test_presence_posting()
	await _test_join()
	await _test_app_backend()
	_test_config()

	_line("")
	_line("%d sections, %d passed, %d failed" % [_section_count, _passed, _failed])

	if _section_count != SECTIONS:
		_line("ERROR: %d of %d sections ran." % [_section_count, SECTIONS])
		get_tree().quit(1)
		return

	if _passed + _failed != CHECKS:
		_line(
			"ERROR: %d checks ran, %d expected. A section aborted part-way."
			% [_passed + _failed, CHECKS]
		)
		get_tree().quit(1)
		return

	get_tree().quit(1 if _failed > 0 else 0)


# --- 1 ----------------------------------------------------------------------

## `GET friends` data, in the shape docs/backbone-contract.md states.
const SITE_FRIENDS := """[
  { "userId": "clx1", "displayName": "Ashley", "avatarUrl": "https://cdn.tmc.example/a/clx1.png",
    "presence": { "status": "in_game", "appId": 3, "appName": "Arena", "serverId": 4821,
      "serverName": "Arena #1", "partyId": "9007199254740993", "joinable": true,
      "detail": "Round 3 of 5", "updatedAt": "2026-09-23T20:00:00.000Z" } },
  { "userId": "clx2", "displayName": "Bo", "avatarUrl": null,
    "presence": { "status": "offline", "appId": null, "appName": null, "serverId": null,
      "serverName": null, "partyId": null, "joinable": false, "detail": null, "updatedAt": null } },
  { "userId": "clx3", "displayName": "Cy", "avatarUrl": null,
    "presence": { "status": "away", "appId": null, "appName": null, "serverId": null,
      "serverName": null, "partyId": null, "joinable": false, "detail": null,
      "updatedAt": "2026-09-23T19:58:00.000Z" } }
]"""

const SITE_REQUESTS := """{
  "incoming": [ { "id": 41, "userId": "clx7", "displayName": "Dee", "createdAt": "2026-09-22T10:00:00.000Z" } ],
  "outgoing": [ { "id": 40, "userId": "clx8", "displayName": "Eve", "createdAt": "2026-09-21T10:00:00.000Z" } ]
}"""


func _test_shapes() -> void:
	_section("The contract's shapes, read as the site sends them")

	var listed := DotFriend.list_from(JSON.parse_string(SITE_FRIENDS))
	_check(listed.ok and (listed.value as Array).size() == 3, "the documented GET friends answer parses, all three rows")
	var ash: DotFriend = (listed.value as Array)[0]
	var p := ash.presence
	_check(ash.user_id == "clx1" and ash.avatar_url.ends_with("clx1.png"), "a friend keeps their id and avatar")
	_check(p.status == DotPresence.Status.IN_GAME and p.app_id == 3 and p.app_name == "Arena", "in_game, in which app")
	_check(p.server_id == 4821 and p.server_name == "Arena #1", "on which server, as the site's integer id")
	_check(p.party_id == "9007199254740993", "a party id past 2^53 survives, because it is a string")
	_check(p.joinable and p.detail == "Round 3 of 5", "joinable, with the game's line")
	_check(p.updated_at == 1790193600, "an ISO time with milliseconds and a Z reads as the right second")
	var bo: DotFriend = (listed.value as Array)[1]
	_check(bo.avatar_url == "" and not bo.is_online() and bo.presence.updated_at == 0, "every null reads as empty, never as the text <null>")
	_check(not bo.presence.has_destination(), "and an offline presence goes nowhere")
	_check(((listed.value as Array)[2] as DotFriend).presence.status == DotPresence.Status.AWAY, "away is its own status")
	_check(not DotFriend.from_dict({"displayName": "ghost"}).ok, "a friend with no user id is refused rather than kept as a ghost")
	var one_bad := DotFriend.list_from([{"userId": "a"}, {"displayName": "ghost"}, "junk"])
	_check(one_bad.ok and (one_bad.value as Array).size() == 1, "and one bad row costs that row, not the list")
	_check(DotPresence.from_dict(null).status == DotPresence.Status.OFFLINE, "a null presence is offline")
	var future := DotPresence.from_dict({"status": "busy"})
	_check(future.status == DotPresence.Status.ONLINE and future.status_raw == "busy", "a status this version does not know reads as online, and keeps its name")

	var reqs := DotFriendRequest.lists_from(JSON.parse_string(SITE_REQUESTS))
	var inc: Array = (reqs.value as Dictionary)["incoming"]
	var outg: Array = (reqs.value as Dictionary)["outgoing"]
	_check(reqs.ok and inc.size() == 1 and outg.size() == 1, "the documented GET friends/requests answer parses")
	var r: DotFriendRequest = inc[0]
	_check(r.id == 41 and r.user_id == "clx7" and not r.outgoing, "an incoming request names its sender, with the site's integer id")
	_check((outg[0] as DotFriendRequest).outgoing and (outg[0] as DotFriendRequest).user_id == "clx8", "an outgoing one names its addressee")

	var back := ash.copy()
	_check(back.presence.same_as(ash.presence) and back.presence.updated_at == ash.presence.updated_at, "a friend round-trips through its own dictionary")
	_check(str(DotPresence.format_time(1790193600))[10] == "T", "and writes times with the T, as RFC 3339 wants")


# --- 2 ----------------------------------------------------------------------

func _test_requests() -> void:
	_section("Friend requests follow the site's rules")

	var hub := _hub()
	var ada := hub.as_user("ada", "Ada")
	var bo := hub.as_user("bo", "Bo")
	var cy := hub.as_user("cy", "Cy")
	hub.as_user("dee", "Dee")

	var me := ada.send_request("ada")
	_check(not me.ok and me.error.detail == "friends.request.deny.self", "nobody can add themselves")
	var ghost := ada.send_request("nobody")
	_check(not ghost.ok and ghost.error.detail == "friends.request.deny.notFound", "nor somebody who does not exist")
	hub.set_accepting_requests("dee", false)
	var shut := ada.send_request("dee")
	_check(not shut.ok and shut.error.detail == "friends.request.deny.closed", "nor somebody who has turned requests off")

	var sent := ada.send_request("bo")
	_check(sent.ok and int((sent.value as Dictionary)["id"]) > 0, "a request is sent, and has an id")
	var twice := ada.send_request("bo")
	_check(not twice.ok and twice.error.detail == "friends.request.deny.pending", "a second request while one is pending is refused")
	var bo_in: Array = (bo.requests().value as Dictionary)["incoming"]
	_check(bo_in.size() == 1 and (bo_in[0] as DotFriendRequest).user_id == "ada", "the addressee sees it as incoming, from the sender")
	_check(((ada.requests().value as Dictionary)["outgoing"] as Array).size() == 1, "the sender sees it as outgoing")
	var wrong := cy.respond(int((sent.value as Dictionary)["id"]), true)
	_check(not wrong.ok and wrong.error.detail == "friends.respond.deny.notFound", "somebody else cannot answer it")
	var own := ada.respond(int((sent.value as Dictionary)["id"]), false)
	_check(not own.ok, "nor can its sender decline it into a cooldown")

	var mutual := bo.send_request("ada")
	_check(mutual.ok and hub.are_friends("ada", "bo"), "asking somebody who already asked you accepts them")
	_check(hub.are_friends("bo", "ada"), "and a friendship is the same from both sides")
	_check((ada.friends().value as Array).size() == 1 and (bo.friends().value as Array).size() == 1, "each lists the other")
	var dup := ada.send_request("bo")
	_check(not dup.ok and dup.error.detail == "friends.request.deny.already", "friends cannot ask again")

	var to_cy := ada.send_request("cy")
	cy.respond(int((to_cy.value as Dictionary)["id"]), false)
	_check(not hub.are_friends("ada", "cy"), "a declined request makes no friendship")
	var again := ada.send_request("cy")
	_check(not again.ok and again.error.detail == "friends.request.deny.cooldown", "the declined sender waits before asking again")
	_check(cy.send_request("ada").ok, "but the one who declined may always ask")
	var both: Dictionary = ada.requests().value
	_check((both["incoming"] as Array).size() == 1 and (both["outgoing"] as Array).is_empty(), "and the row turns round to face whoever asked last")
	ada.respond(int(((both["incoming"] as Array)[0] as DotFriendRequest).id), true)
	_check(hub.are_friends("ada", "cy"), "which the other side can then accept")

	_now[0] += DotFriendsLocalHub.REREQUEST_COOLDOWN_SEC + 1
	hub.as_user("eve", "Eve")
	var to_eve := ada.send_request("eve")
	hub.as_user("eve").respond(int((to_eve.value as Dictionary)["id"]), false)
	_now[0] += DotFriendsLocalHub.REREQUEST_COOLDOWN_SEC + 1
	var later := ada.send_request("eve")
	_check(later.ok and int((later.value as Dictionary)["id"]) == int((to_eve.value as Dictionary)["id"]), "a week later the sender may ask again, on the same row as the site does")

	_check(bo.remove_friend("ada").ok and not hub.are_friends("ada", "bo"), "either side can end a friendship")
	var gone := bo.remove_friend("ada")
	_check(not gone.ok and gone.error.detail == "friends.remove.deny.notFriends", "and ending one that does not exist is refused")
	_check(ada.send_request("bo").ok, "after which a new request starts from nothing")


# --- 3 ----------------------------------------------------------------------

func _test_presence_privacy() -> void:
	_section("Presence is shown to friends only, and hidden means offline")

	var hub := _hub()
	hub.server_names[4821] = "Arena #1"
	var ada := hub.as_user("ada", "Ada", 3, "Arena")
	var bo := hub.as_user("bo", "Bo")
	var cy := hub.as_user("cy", "Cy")
	_befriend(hub, "ada", "bo")

	var posted := ada.post_presence({"status": "in_game", "serverId": 4821, "partyId": "4471", "joinable": true, "detail": "Round 3"})
	_check(posted.ok and int((posted.value as Dictionary)["ttlSec"]) == 120, "a post is accepted with the site's lifetime")
	var seen: DotPresence = (bo.fetch_presence(PackedStringArray(["ada"])).value as Dictionary)["ada"]
	_check(seen.status == DotPresence.Status.IN_GAME and seen.server_id == 4821 and seen.party_id == "4471", "a friend sees where they are")
	_check(seen.app_name == "Arena" and seen.server_name == "Arena #1", "in which app, from the token rather than the post, and the server's name")
	_check(seen.updated_at == _now[0], "stamped when it was posted")
	var list_row: DotFriend = (bo.friends().value as Array)[0]
	_check(list_row.presence.same_as(seen), "the friends list and the presence route agree")

	var stranger: Dictionary = cy.fetch_presence(PackedStringArray(["ada"])).value
	_check(stranger.is_empty(), "a stranger asking for it gets nothing back, not even offline")
	_check(hub.presence_seen_by("cy", "ada").status == DotPresence.Status.OFFLINE, "and is shown offline wherever it would be drawn")

	hub.set_activity_hidden("ada", true)
	var hidden: DotPresence = (bo.fetch_presence(PackedStringArray(["ada"])).value as Dictionary)["ada"]
	_check(hidden.status == DotPresence.Status.OFFLINE, "hiding activity is offline to friends too")
	_check(not hidden.has_destination() and not hidden.joinable and hidden.updated_at == 0 and hidden.app_name == "", "with nothing left in it that says otherwise")
	hub.set_activity_hidden("ada", false)
	_check((bo.fetch_presence(PackedStringArray(["ada"])).value as Dictionary)["ada"].status == DotPresence.Status.IN_GAME, "and unhiding shows them again")

	var long_line := ada.post_presence({"status": "online", "detail": "x".repeat(129)})
	_check(not long_line.ok and long_line.error.detail == "presence.deny.detail", "a line over 128 characters is refused")
	var nonsense := ada.post_presence({"status": "asleep"})
	_check(not nonsense.ok and nonsense.error.detail == "presence.deny.status", "as is a status that is not one")
	var many := PackedStringArray()
	for i in range(101):
		many.append("u%d" % i)
	var batch := bo.fetch_presence(many)
	_check(not batch.ok and batch.error.detail == "presence.deny.batch", "and a hundred and one people at once")

	ada.post_presence({"status": "offline", "serverId": 4821, "joinable": true})
	var off: DotPresence = (bo.fetch_presence(PackedStringArray(["ada"])).value as Dictionary)["ada"]
	_check(off.status == DotPresence.Status.OFFLINE and not off.joinable and off.server_id == 0, "posting offline clears everything, whatever else the post said")


# --- 4 ----------------------------------------------------------------------

func _test_ttl() -> void:
	_section("A presence lives 120 seconds past its last post")

	var hub := _hub()
	var ada := hub.as_user("ada", "Ada")
	hub.as_user("bo", "Bo")
	_befriend(hub, "ada", "bo")

	ada.post_presence({"status": "online"})
	_now[0] += 119
	_check(hub.presence_seen_by("bo", "ada").is_online(), "at 119 seconds they are still online")
	_now[0] += 1
	_check(not hub.presence_seen_by("bo", "ada").is_online(), "at 120 they are offline, with nobody having said so")
	ada.post_presence({"status": "away"})
	_check(hub.presence_seen_by("bo", "ada").status == DotPresence.Status.AWAY, "a new post brings them back")
	_now[0] += 60
	ada.post_presence({"status": "away"})
	_now[0] += 100
	_check(hub.presence_seen_by("bo", "ada").is_online(), "and a heartbeat inside the lifetime keeps them there")
	_now[0] += 21
	hub.tick()
	_check(hub.describe_lines()[0].ends_with("0 presences"), "an expired presence is forgotten by the hub's tick")


# --- 5 ----------------------------------------------------------------------

func _test_client_diff() -> void:
	_section("The client turns each snapshot into signals")

	var hub := _hub()
	var ada_backend := hub.as_user("ada", "Ada")
	var bo := hub.as_user("bo", "Bo")
	var cy := hub.as_user("cy", "Cy")
	var dee := hub.as_user("dee", "Dee")
	_befriend(hub, "ada", "bo")
	_befriend(hub, "ada", "cy")
	bo.post_presence({"status": "online"})

	var client := _client(ada_backend)
	var ev: Array = []
	client.friend_added.connect(func(f: DotFriend) -> void: ev.append("added:" + f.user_id))
	client.friend_removed.connect(func(f: DotFriend) -> void: ev.append("removed:" + f.user_id))
	client.friend_online.connect(func(f: DotFriend) -> void: ev.append("online:" + f.user_id))
	client.friend_offline.connect(func(f: DotFriend) -> void: ev.append("offline:" + f.user_id))
	client.friend_presence_changed.connect(func(f: DotFriend, _old: DotPresence) -> void: ev.append("changed:" + f.user_id))
	client.request_received.connect(func(r: DotFriendRequest) -> void: ev.append("request:" + r.user_id))
	var snapshots: Array = []
	client.friends_changed.connect(func(list: Array) -> void: snapshots.append(list.size()))

	await client.refresh()
	_check(client.loaded and client.friends.size() == 2, "the first poll loads the list")
	_check(ev.is_empty() and snapshots == [2], "quietly: no 'came online' for everybody already online at launch")
	_check(client.online_friends().size() == 1 and client.find_friend("bo").is_online(), "but it knows who is")

	cy.post_presence({"status": "in_game", "serverId": 12})
	ev.clear()
	await client.refresh()
	_check(ev == ["online:cy", "changed:cy"], "a friend coming online is announced once, then as a change")

	bo.post_presence({"status": "online", "detail": "In the menu"})
	ev.clear()
	await client.refresh()
	_check(ev == ["changed:bo"], "a new line is a change and not a coming-online")

	_now[0] += 30
	bo.post_presence({"status": "online", "detail": "In the menu"})
	ev.clear()
	await client.refresh()
	_check(ev.is_empty(), "a heartbeat that moves only the timestamp is nothing")

	# bo's last post was the heartbeat above; 121 seconds past it, and cy keeps posting.
	_now[0] += 121
	cy.post_presence({"status": "in_game", "serverId": 12})
	ev.clear()
	await client.refresh()
	_check(ev == ["offline:bo", "changed:bo"], "a friend whose presence expired goes offline without having said so")

	dee.send_request("ada")
	ev.clear()
	await client.refresh_requests()
	_check(ev == ["request:dee"] and client.incoming.size() == 1, "a new request is announced")
	ev.clear()
	await client.refresh_requests()
	_check(ev.is_empty(), "once, not on every poll")

	var accepted := await client.accept(client.incoming[0].id)
	_check(accepted.ok and ev.has("added:dee"), "accepting it adds the friend, from the site's answer rather than an assumption")
	_check(client.incoming.is_empty() and client.friends.size() == 3, "and the inbox and the list both move")

	cy.remove_friend("ada")
	ev.clear()
	await client.refresh()
	_check(ev == ["removed:cy"], "a friend removing you is announced")
	var failures: Array = []
	client.request_failed.connect(func(what: String, _e: DotError) -> void: failures.append(what))
	var refused := await client.send_request("ada")
	_check(not refused.ok and failures == ["send_request"], "a refused action says so and leaves the list alone")

	client.queue_free()


# --- 6 ----------------------------------------------------------------------

## A local backend that remembers every post and can answer with a different lifetime.
class CountingBackend:
	extends DotFriendsBackendLocal
	var posts: Array = []
	var ttl_override: int = 0

	func post_presence(body: Dictionary) -> DotResult:
		posts.append(body.duplicate())
		var res := hub.post_presence(user_id, body, app_id, app_name)
		if res.ok and ttl_override > 0:
			return DotResult.success({"ttlSec": ttl_override})
		return res


func _test_presence_posting() -> void:
	_section("Presence is posted on a heartbeat and once per burst of changes")

	var hub := _hub()
	hub.as_user("ada", "Ada")
	var bo := hub.as_user("bo", "Bo")
	_befriend(hub, "ada", "bo")
	var counting := CountingBackend.new()
	counting.hub = hub
	counting.user_id = "ada"
	counting.app_id = 3
	counting.app_name = "Arena"

	var client := _client(counting)
	client.config.presence_debounce_sec = 0.5
	client.advance(0.2)
	_check(counting.posts.is_empty(), "nothing is posted inside the debounce")
	client.advance(0.4)
	_check(counting.posts.size() == 1 and counting.posts[0]["status"] == "online", "then the first presence goes out")
	_check(bo.fetch_presence(PackedStringArray(["ada"])).value["ada"].is_online(), "and a friend sees it")

	client.set_server(4821)
	client.advance(0.2)
	client.set_party("4471")
	client.advance(0.2)
	client.set_joinable(true)
	_check(counting.posts.size() == 1, "a burst of three changes posts nothing while it is still arriving")
	client.advance(0.2)
	_check(counting.posts.size() == 2, "and one post half a second after its first change, not after its last")
	var body: Dictionary = counting.posts[1]
	_check(body["serverId"] == 4821 and body["partyId"] == "4471" and body["joinable"] == true, "carrying all three")
	var seen: DotPresence = bo.fetch_presence(PackedStringArray(["ada"])).value["ada"]
	_check(seen.server_id == 4821 and seen.party_id == "4471" and seen.joinable, "which is what the friend now sees")

	client.set_joinable(false)
	client.set_joinable(true)
	client.advance(1.0)
	_check(counting.posts.size() == 2, "a burst that ends where it started posts nothing")

	var too_long := client.set_detail("x".repeat(129))
	_check(not too_long.ok and too_long.error.detail == "presence.deny.detail", "a line over the site's limit is refused at the setter")
	client.advance(1.0)
	_check(counting.posts.size() == 2, "and marks nothing to post")

	client.advance(42.0)
	_check(counting.posts.size() == 2, "no heartbeat before the interval")
	client.advance(2.0)
	_check(counting.posts.size() == 3 and counting.posts[2] == counting.posts[1], "the heartbeat repeats the same presence at 45 seconds")
	_check(client.heartbeat_interval() * 2.0 < DotFriendsConfig.PRESENCE_TTL_SEC, "well inside the site's lifetime, with room for a lost post")

	counting.ttl_override = 30
	client.set_detail("Round 2")
	client.advance(0.6)
	_check(counting.posts.size() == 4 and is_equal_approx(client.heartbeat_interval(), 12.0), "a shorter lifetime from the site shortens the heartbeat to match")
	client.advance(12.1)
	_check(counting.posts.size() == 5, "and the next beat comes on the shorter one")

	var off := await client.go_offline()
	_check(off.ok and counting.posts.size() == 6 and counting.posts[5] == {"status": "offline"}, "going offline posts at once, and nothing but the status")
	client.advance(100.0)
	_check(counting.posts.size() == 6, "and an offline player does not heartbeat")
	_check(not bo.fetch_presence(PackedStringArray(["ada"])).value["ada"].is_online(), "so the friend sees them go at once, not two minutes later")

	client.queue_free()


# --- 7 ----------------------------------------------------------------------

func _test_join() -> void:
	_section("Joining a friend: their party first, then their server, or an honest no")

	var hub := _hub()
	var ada_backend := hub.as_user("ada", "Ada")
	for pair in [["bo", "Bo"], ["cy", "Cy"], ["dee", "Dee"], ["eve", "Eve"], ["fay", "Fay"]]:
		hub.as_user(str(pair[0]), str(pair[1]))
		_befriend(hub, "ada", str(pair[0]))
	hub.as_user("bo").post_presence({"status": "in_game", "serverId": 4821, "partyId": "4471", "joinable": true})
	hub.as_user("cy").post_presence({"status": "in_game", "serverId": 7, "joinable": true})
	hub.as_user("dee").post_presence({"status": "in_game", "serverId": 9, "joinable": false})
	hub.as_user("fay").post_presence({"status": "online", "partyId": "5000", "joinable": true})

	var client := _client(ada_backend)
	await client.refresh()
	var party_calls: Array = []
	var server_calls: Array = []
	var party_answer: Array = [DotResult.success({"partyId": "4471"})]
	client.join_party_fn = func(pid: String, f: DotFriend) -> DotResult:
		party_calls.append([pid, f.user_id])
		return party_answer[0]
	client.connect_fn = func(sid: int, f: DotFriend) -> DotResult:
		server_calls.append([sid, f.user_id])
		return DotResult.success(null)

	var via_party := await client.join("bo")
	_check(via_party.ok and via_party.value["via"] == "party" and party_calls == [["4471", "bo"]], "a joinable party is joined")
	_check(server_calls.is_empty(), "and the server is left to the party, rather than connected to twice")

	party_answer[0] = DotResult.fail(DotError.CODE_CONFLICT, "That party is full.", "party.join.deny.full")
	var fallback := await client.join("bo")
	_check(fallback.ok and fallback.value["via"] == "server" and server_calls == [[4821, "bo"]], "a party that refuses falls back to the friend's server")
	_check((fallback.value["partyRefused"] as DotError).detail == "party.join.deny.full", "and says why it went the long way round")

	var server_only := await client.join("cy")
	_check(server_only.ok and server_only.value["serverId"] == 7, "a friend on a server with no party is followed to the server")

	var closed := await client.join("dee")
	_check(not closed.ok and closed.error.detail == "friends.join.deny.notJoinable", "a friend who is not joinable is refused, with a key")
	var asleep := await client.join("eve")
	_check(not asleep.ok and asleep.error.detail == "friends.join.deny.offline", "an offline friend is refused as offline")
	var stranger := await client.join("zed")
	_check(not stranger.ok and stranger.error.detail == "friends.join.deny.notFriend", "somebody not on the list is refused as not a friend")

	var no_party_fn := _client(ada_backend)
	await no_party_fn.refresh()
	no_party_fn.connect_fn = client.connect_fn
	var cannot := await no_party_fn.join("fay")
	_check(not cannot.ok and cannot.error.detail == "friends.join.deny.unsupported", "a party-only friend in a game that cannot join parties is refused as unsupported")
	var still := await no_party_fn.join("bo")
	_check(still.ok and still.value["via"] == "server", "while a friend with a server is still followed without the party")

	# The list says joinable; the friend changed their mind since.
	hub.as_user("cy").post_presence({"status": "in_game", "serverId": 7, "joinable": false})
	_check(client.find_friend("cy").presence.joinable, "the client's list still says cy is joinable")
	var stale := await client.join("cy")
	_check(not stale.ok and stale.error.detail == "friends.join.deny.notJoinable", "but join asks first, and is refused on what is true now")
	_check(not client.find_friend("cy").presence.joinable, "and the list is corrected on the way")

	hub.remove_friend("ada", "bo")
	var unfriended := await client.join("bo")
	_check(not unfriended.ok and unfriended.error.detail == "friends.join.deny.notFriend", "a friendship ended since the last poll is refused too")

	client.connect_fn = func(_sid: int, _f: DotFriend) -> DotResult:
		return DotResult.fail(DotError.CODE_NETWORK, "Could not reach the server.")
	hub.as_user("cy").post_presence({"status": "in_game", "serverId": 7, "joinable": true})
	var unreachable := await client.join("cy")
	_check(not unreachable.ok and unreachable.error.code == DotError.CODE_NETWORK, "a connect that fails is the game's failure, passed back as it was")

	client.queue_free()
	no_party_fn.queue_free()


# --- 8 ----------------------------------------------------------------------

class FakeAuthClient:
	extends RefCounted
	var calls: Array = []
	var answer: DotResult = DotResult.success(null)

	func get_app(path: String, query: Dictionary = {}) -> DotResult:
		calls.append(["GET", path, query])
		return answer

	func post_app(path: String, body: Dictionary) -> DotResult:
		calls.append(["POST", path, body])
		return answer


func _test_app_backend() -> void:
	_section("The app backend speaks the app API's envelope")

	var sent: Array = []
	var answers: Array = []
	var app := DotFriendsBackendApp.new("https://tmc.example/api/app/v1")
	app.request_fn = func(method: String, path: String, body: Dictionary) -> DotResult:
		sent.append([method, path, body])
		return answers.pop_front()

	answers.append(DotResult.success({"ok": true, "data": JSON.parse_string(SITE_FRIENDS)}))
	var listed := await app.friends()
	_check(listed.ok and (listed.value as Array).size() == 3 and sent[0][0] == "GET" and sent[0][1] == "friends", "GET friends comes back as friends")

	answers.append(DotResult.success({"ok": true, "data": JSON.parse_string(SITE_REQUESTS)}))
	var reqs := await app.requests()
	_check(reqs.ok and sent[1][1] == "friends/requests" and ((reqs.value as Dictionary)["incoming"] as Array).size() == 1, "GET friends/requests comes back as requests")

	answers.append(DotResult.success({"ok": true, "data": {"id": 42}}))
	var made := await app.send_request("clx9")
	_check(made.ok and int((made.value as Dictionary)["id"]) == 42 and sent[2][1] == "friends/request" and sent[2][2] == {"userId": "clx9"}, "POST friends/request with the site's field name")

	answers.append(DotResult.success({"ok": true, "data": null}))
	await app.respond(41, true)
	_check(sent[3][2] == {"requestId": 41, "accept": true} and sent[3][2]["requestId"] is int, "POST friends/respond sends the request id as the integer the site gave")

	answers.append(DotResult.success({"ok": true, "data": null}))
	var removed := await app.remove_friend("clx2")
	_check(removed.ok and sent[4][1] == "friends/remove" and sent[4][2] == {"userId": "clx2"}, "POST friends/remove")

	answers.append(DotResult.success({"ok": true, "data": {"ttlSec": 120}}))
	var body := {"status": "in_game", "serverId": 4821, "joinable": true}
	var posted := await app.post_presence(body)
	_check(posted.ok and int((posted.value as Dictionary)["ttlSec"]) == 120 and sent[5][2] == body, "POST presence sends the body as given and returns the lifetime")

	answers.append(DotResult.success({"ok": true, "data": {"clx1": {"status": "online"}, "clx2": null}}))
	var pres := await app.fetch_presence(PackedStringArray(["clx1", "clx2"]))
	var path := str(sent[6][1])
	_check(path.begins_with("presence?userIds=") and path.get_slice("=", 1).uri_decode() == "clx1,clx2", "GET presence names its people as one comma-separated query")
	_check(pres.ok and (pres.value["clx1"] as DotPresence).is_online() and not (pres.value["clx2"] as DotPresence).is_online(), "and each comes back as a presence, a null one as offline")

	var n := sent.size()
	var many := PackedStringArray()
	for i in range(101):
		many.append("u%d" % i)
	var too_many := await app.fetch_presence(many)
	var too_long := await app.post_presence({"status": "online", "detail": "x".repeat(129)})
	_check(not too_many.ok and not too_long.ok and too_long.error.detail == "presence.deny.detail" and sent.size() == n, "a batch or a line the site would refuse is refused before a request is made")

	answers.append(DotResult.success({"ok": false, "code": "friends.request.deny.self", "message": "You cannot add yourself."}))
	var self_req := await app.send_request("me")
	_check(not self_req.ok and self_req.error.detail == "friends.request.deny.self" and self_req.error.message == "You cannot add yourself.", "a refusal keeps the site's key and its message")

	answers.append(DotResult.failure(DotError.from_http(409, "{\"ok\":false,\"code\":\"friends.request.deny.pending\",\"message\":\"A request is already pending.\"}")))
	var pending := await app.send_request("clx9")
	_check(not pending.ok and pending.error.detail == "friends.request.deny.pending" and pending.error.http_status == 409, "so does one that arrives as a non-2xx with the envelope in its body")

	answers.append(DotResult.failure(DotError.from_http(429, "{\"ok\":false,\"code\":\"rate_limited\",\"message\":\"Slow down.\",\"retryAfter\":12}")))
	var slow := await app.post_presence({"status": "online"})
	_check(not slow.ok and slow.error.retry_after == 12.0 and slow.error.code == DotError.CODE_RATE_LIMITED, "a 429 keeps its retry-after")

	answers.append(DotResult.failure(DotError.from_http(404, "")))
	var missing := await app.friends()
	_check(not missing.ok and missing.error.message.contains("no app friends routes yet") and missing.error.detail == "", "a bare 404 says the site has not grown the routes, and invents no key")

	var auth := FakeAuthClient.new()
	var via_auth := DotFriendsBackendApp.new()
	via_auth.client = auth
	auth.answer = DotResult.success({"clx1": {"status": "away"}})
	var through := await via_auth.fetch_presence(PackedStringArray(["clx1"]))
	_check(through.ok and auth.calls[0][0] == "GET" and auth.calls[0][1] == "presence" and (auth.calls[0][2] as Dictionary)["userIds"] == "clx1", "through dot-auth's client, the query goes as a query")
	auth.answer = DotResult.failure(DotError.make(DotError.CODE_FORBIDDEN, "This member is not accepting friend requests.", "friends.request.deny.closed"))
	var closed := await via_auth.send_request("clx9")
	_check(not closed.ok and closed.error.detail == "friends.request.deny.closed" and auth.calls[1][2] == {"userId": "clx9"}, "and a refusal keeps the site's key")
	auth.answer = DotResult.failure(DotError.from_http(404, ""))
	var auth_404 := await via_auth.friends()
	_check(not auth_404.ok and auth_404.error.message.contains("no app friends routes yet"), "and a bare 404 through it gets the same hint")


# --- 9 ----------------------------------------------------------------------

func _test_config() -> void:
	_section("The config refuses a heartbeat the site's lifetime cannot absorb")

	var c := DotFriendsConfig.new()
	_check(c.validate().ok, "the defaults are valid")
	c.heartbeat_sec = 70.0
	_check(not c.validate().ok, "a heartbeat over half the 120-second lifetime is refused")
	c.heartbeat_sec = 45.0
	c.presence_debounce_sec = 50.0
	_check(not c.validate().ok, "as is a debounce longer than the heartbeat")


# --- helpers ------------------------------------------------------------------

func _hub() -> DotFriendsLocalHub:
	var hub := DotFriendsLocalHub.new()
	hub.now_fn = func() -> int: return _now[0]
	return hub


func _befriend(hub: DotFriendsLocalHub, a: String, b: String) -> void:
	var sent := hub.send_request(a, b)
	hub.respond(b, int((sent.value as Dictionary)["id"]), true)


## A client in the tree with processing off: the suite moves its clock with advance().
func _client(backend: DotFriendsBackend) -> DotFriendsClient:
	var c := DotFriendsClient.new()
	c.backend = backend
	add_child(c)
	c.set_process(false)
	return c


func _section(title: String) -> void:
	_section_count += 1
	_line("-- %d. %s" % [_section_count, title])


func _check(ok: bool, what: String) -> void:
	if ok:
		_passed += 1
		_line("   ok    %s" % what)
	else:
		_failed += 1
		_line("   FAIL  %s" % what)


func _line(s: String) -> void:
	print(s)
