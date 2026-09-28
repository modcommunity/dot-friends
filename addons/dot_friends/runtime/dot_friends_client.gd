class_name DotFriendsClient
extends Node

## The player's friends list kept current, their own presence kept posted, and the thing
## that takes them to where a friend is playing.
##
## [b]Polled, because the backbone pushes nothing.[/b] The list is polled at a relaxed rate
## ([member DotFriendsConfig.poll_sec], 30 s): every signed-in player of every game polls it,
## and a friend shown online half a minute late costs nobody anything. [method join] does
## not trust that snapshot — it asks for the one friend's presence first, because the party
## it names may have gone in those thirty seconds.
##
## [b]Presence is a heartbeat and an edge.[/b] The site forgets a presence about 120 seconds
## after the last post, so this posts every [member DotFriendsConfig.heartbeat_sec] (45 s)
## while nothing changes — and shortens that if the site answers with a shorter
## [code]ttlSec[/code]. A change (status, server, party, joinable, detail) is posted after
## [member DotFriendsConfig.presence_debounce_sec], counted from the first change of a
## burst: joining a server sets the server, then the party, then joinable, and three posts
## for one event is two posts the site rate-limits somebody else for. A burst that ends
## where it started posts nothing.
##
## [b]Every snapshot is diffed into signals[/b], in [method apply_friends] and
## [method apply_requests], which the suite drives directly. The first snapshot is quiet
## apart from [signal friends_changed]: a game that toasted "came online" for every friend
## already online at launch would open with a wall of toasts. Pending requests are the
## exception — they are an inbox, and one that arrived while the game was closed is still
## news — so [signal request_received] fires for each the first time it is seen.
##
## [b]Joining a friend names nothing.[/b] [member join_party_fn] is the game's "join this
## party" (usually dot-party's client, wrapped in a lambda), [member connect_fn] its "connect
## to this server". Neither type is named here, so a game without parties still follows
## friends to their server, and one without dot-party does not fail to parse.

const CHANNEL := "friends.client"

## Every snapshot, after the per-friend signals.
signal friends_changed(friends: Array)
## Somebody became a friend since the last snapshot — either side accepting.
signal friend_added(friend: DotFriend)
signal friend_removed(friend: DotFriend)
## Offline to any other status. Also fires [signal friend_presence_changed].
signal friend_online(friend: DotFriend)
## Any status to offline — including expiry, and hiding their activity.
signal friend_offline(friend: DotFriend)
## Anything a person would see changed. Not the timestamp, which moves on every heartbeat.
signal friend_presence_changed(friend: DotFriend, old: DotPresence)
## A pending request this client has not seen before.
signal request_received(request: DotFriendRequest)
signal requests_changed(incoming: Array, outgoing: Array)
## The site accepted a presence post and will keep it this long.
signal presence_posted(ttl_sec: int)
## A request to the backbone failed. The snapshot is unchanged.
signal request_failed(what: String, error: DotError)

@export var config: DotFriendsConfig = null

var backend: DotFriendsBackend = null

## [code]func(party_id: String, friend: DotFriend) -> DotResult[/code], awaited. The game's
## "join this party". dot-party's client fits in one lambda:
## [code]func(pid, _f): return await party.join(pid)[/code].
var join_party_fn: Callable = Callable()

## [code]func(server_id: int, friend: DotFriend) -> DotResult[/code], awaited. The game's
## "connect to this server"; the site's server id is all a presence carries, so turning it
## into an address is the game's (usually through dot-browser or the site's connect route).
var connect_fn: Callable = Callable()

## The current list. Empty until the first successful poll; [member loaded] says which.
var friends: Array[DotFriend] = []
var incoming: Array[DotFriendRequest] = []
var outgoing: Array[DotFriendRequest] = []
var loaded: bool = false

# This player's own presence. Set through the setters, which post it.
var status: DotPresence.Status = DotPresence.Status.ONLINE
var server_id: int = 0
var party_id: String = ""
var joinable: bool = false
var detail: String = ""

## Seconds since this node started advancing. The debounce and heartbeat are measured on it
## rather than on the wall clock, so the suite can drive both without waiting.
var _clock: float = 0.0
var _since_poll: float = INF
var _since_requests: float = INF
var _since_post: float = 0.0
var _dirty: bool = false
var _dirty_at: float = 0.0
var _posting: bool = false
var _posted_once: bool = false
var _last_posted: Dictionary = {}
var _ttl_sec: float = DotFriendsConfig.PRESENCE_TTL_SEC
var _refreshing: bool = false
var _refreshing_requests: bool = false
## request id -> true, for requests already announced.
var _seen_requests: Dictionary = {}


func _ready() -> void:
	if config == null:
		config = DotFriendsConfig.new()
	# The first presence goes out on the first advance past the debounce, carrying whatever
	# the game set before then rather than a bare "online" followed at once by the real one.
	_mark_dirty()


func _process(delta: float) -> void:
	if backend == null or Engine.is_editor_hint():
		return
	advance(delta)


## Moves this client's clock on by [param delta] and does whatever is due: a presence post,
## a heartbeat, a poll. [method _process] calls it; the suite calls it with the node's
## processing off.
func advance(delta: float) -> void:
	if config == null:
		config = DotFriendsConfig.new()
	_clock += delta
	_since_poll += delta
	_since_requests += delta
	_since_post += delta
	if backend == null:
		return

	if not _posting:
		if _dirty and _clock - _dirty_at >= config.presence_debounce_sec:
			_post_presence()
		elif _posted_once and status != DotPresence.Status.OFFLINE and _since_post >= heartbeat_interval():
			_post_presence()

	if _since_poll >= config.poll_sec:
		_since_poll = 0.0
		refresh()
	if _since_requests >= config.requests_poll_sec:
		_since_requests = 0.0
		refresh_requests()


## The heartbeat in force: the configured one, or 40% of the site's TTL if that is shorter,
## so two posts can be lost before the player blinks offline.
func heartbeat_interval() -> float:
	var hb := config.heartbeat_sec
	if _ttl_sec > 0.0:
		hb = minf(hb, _ttl_sec * 0.4)
	return hb


# --- This player's presence --------------------------------------------------

func set_status(value: DotPresence.Status) -> void:
	status = value
	_mark_dirty()


## [param value] is the site's server id; 0 for none.
func set_server(value: int) -> void:
	server_id = maxi(value, 0)
	_mark_dirty()


## [param value] is the party id, a decimal string; "" for none.
func set_party(value: String) -> void:
	party_id = value
	_mark_dirty()


func set_joinable(value: bool) -> void:
	joinable = value
	_mark_dirty()


## Refused rather than truncated when too long: a cut sentence reads as a bug in the game,
## and the caller is the one who can shorten it well.
func set_detail(value: String) -> DotResult:
	if value.length() > DotPresence.DETAIL_MAX:
		return DotResult.fail(DotError.CODE_INVALID, "That presence line is too long.", "presence.deny.detail")
	detail = value
	_mark_dirty()
	return DotResult.success(null)


## The body [code]POST presence[/code] is sent. Each post replaces the whole presence, so
## a field is left out to clear it.
func presence_body() -> Dictionary:
	var body := {"status": DotPresence.status_name(status)}
	if status == DotPresence.Status.OFFLINE:
		return body
	body["joinable"] = joinable
	if server_id > 0:
		body["serverId"] = server_id
	if party_id != "":
		body["partyId"] = party_id
	if detail != "":
		body["detail"] = detail
	return body


## Posts now, skipping the debounce. For a game about to quit, with [method go_offline].
func post_presence_now() -> DotResult:
	return await _post_presence()


## Posts "offline" at once. A game closing should await this: otherwise its friends see it
## online for up to two more minutes, and one of them tries to join.
func go_offline() -> DotResult:
	status = DotPresence.Status.OFFLINE
	return await _post_presence()


func _mark_dirty() -> void:
	# A burst that ends where it started is nothing to say.
	if _posted_once and DotValue.same_dictionary(presence_body(), _last_posted):
		_dirty = false
		return
	if not _dirty:
		_dirty = true
		_dirty_at = _clock


func _post_presence() -> DotResult:
	if backend == null:
		return DotResult.fail(DotError.CODE_STATE, "no friends backend")
	_posting = true
	# Cleared before the await, so a change made while this post is in flight marks the
	# presence dirty again rather than being lost behind it.
	_dirty = false
	var body := presence_body()
	var res: DotResult = await backend.post_presence(body)
	_posting = false
	_since_post = 0.0
	if not res.ok:
		request_failed.emit("presence", res.error)
		return res
	_posted_once = true
	_last_posted = body
	var ttl := 0
	if res.value is Dictionary:
		ttl = int((res.value as Dictionary).get("ttlSec", 0))
	if ttl > 0:
		_ttl_sec = float(ttl)
	DotLog.trace(CHANNEL, "presence posted", {"status": body["status"], "ttl": ttl})
	presence_posted.emit(ttl)
	return res


# --- The list ----------------------------------------------------------------

## Fetches the friends list and applies it. Overlapping calls are dropped rather than
## queued, because the second answer would only repeat the first.
func refresh() -> DotResult:
	if backend == null or _refreshing:
		return DotResult.success(friends)
	_refreshing = true
	var res: DotResult = await backend.friends()
	_refreshing = false
	if not res.ok:
		request_failed.emit("friends", res.error)
		return res
	apply_friends(res.value as Array)
	return DotResult.success(friends)


func refresh_requests() -> DotResult:
	if backend == null or _refreshing_requests:
		return DotResult.success(null)
	_refreshing_requests = true
	var res: DotResult = await backend.requests()
	_refreshing_requests = false
	if not res.ok:
		request_failed.emit("requests", res.error)
		return res
	apply_requests(res.value as Dictionary)
	return res


## Turns a new list into signals. Keyed by user id and compared as Strings, and announced
## in the list's own order, so two clients given the same list say the same things in the
## same order.
func apply_friends(next: Array) -> void:
	var before := {}
	for f in friends:
		before[f.user_id] = f
	var list: Array[DotFriend] = []
	var after := {}
	for v in next:
		if v is DotFriend and not after.has((v as DotFriend).user_id):
			list.append(v)
			after[(v as DotFriend).user_id] = v

	var first := not loaded
	var old_list := friends
	friends = list
	loaded = true

	if not first:
		for f in list:
			if not before.has(f.user_id):
				# Not also "online": a friend just added is news once, not twice.
				friend_added.emit(f)
				continue
			_announce_presence(f, (before[f.user_id] as DotFriend).presence)
		for f in old_list:
			if not after.has(f.user_id):
				friend_removed.emit(f)

	friends_changed.emit(friends)


func apply_requests(lists: Dictionary) -> void:
	incoming.assign(lists.get("incoming", []))
	outgoing.assign(lists.get("outgoing", []))
	var current := {}
	for r in incoming:
		current[r.id] = true
		if not _seen_requests.has(r.id):
			request_received.emit(r)
	# Forget answered ones: the site re-uses a row's id when a declined sender asks again a
	# week later, and that second request is news too.
	_seen_requests = current
	requests_changed.emit(incoming, outgoing)


func _announce_presence(f: DotFriend, old: DotPresence) -> void:
	if old.same_as(f.presence):
		return
	if not old.is_online() and f.is_online():
		friend_online.emit(f)
	elif old.is_online() and not f.is_online():
		friend_offline.emit(f)
	friend_presence_changed.emit(f, old)


func find_friend(user_id: String) -> DotFriend:
	for f in friends:
		if f.user_id == user_id:
			return f
	return null


func online_friends() -> Array[DotFriend]:
	var out: Array[DotFriend] = []
	for f in friends:
		if f.is_online():
			out.append(f)
	return out


## Asks for the presence of [param user_ids] (default: every friend) and applies it, 100 at
## a time, which is the site's limit per request.
func refresh_presence(user_ids: PackedStringArray = PackedStringArray()) -> DotResult:
	if backend == null:
		return DotResult.fail(DotError.CODE_STATE, "no friends backend")
	var ids := user_ids
	if ids.is_empty():
		for f in friends:
			ids.append(f.user_id)
	var merged := {}
	var at := 0
	while at < ids.size():
		var batch := ids.slice(at, at + DotFriendsBackendApp.PRESENCE_BATCH_MAX)
		at += batch.size()
		var res: DotResult = await backend.fetch_presence(batch)
		if not res.ok:
			request_failed.emit("presence", res.error)
			return res
		merged.merge(res.value as Dictionary, true)
	for uid in merged:
		var f := find_friend(str(uid))
		if f == null:
			continue
		var old := f.presence
		f.presence = merged[uid]
		_announce_presence(f, old)
	return DotResult.success(merged)


# --- Actions -----------------------------------------------------------------
#
# Each asks the backend and then refreshes, so the list and its signals come from what the
# backbone now says rather than from what this client assumed it would say.

func send_request(user_id: String) -> DotResult:
	return await _act("send_request", &"send_request", [user_id])


func accept(request_id: int) -> DotResult:
	return await _act("accept", &"respond", [request_id, true])


func decline(request_id: int) -> DotResult:
	return await _act("decline", &"respond", [request_id, false])


## Withdraws a request this player sent (one of [code]outgoing[/code]'s ids).
func cancel_request(request_id: int) -> DotResult:
	return await _act("cancel_request", &"cancel_request", [request_id])


func remove_friend(user_id: String) -> DotResult:
	return await _act("remove_friend", &"remove_friend", [user_id])


## Takes the player to [param friend_user_id]: into their party when it is joinable and the
## game can join parties, otherwise to their server. Value: [code]{via: "party"|"server",
## partyId|serverId}[/code].
##
## Refuses, with a key in [member DotError.detail], when they are not a friend
## ([code]friends.join.deny.notFriend[/code]), are offline ([code].offline[/code]), have not
## made themselves joinable or are somewhere nothing can follow ([code].notJoinable[/code]),
## or when this game can reach neither their party nor their server ([code].unsupported[/code]).
##
## A party that refuses — full, say — falls back to the server when there is one, because
## what the player asked for is to be where their friend is. The party's refusal is kept in
## the value as [code]partyRefused[/code] so a game can say why it went the long way round.
func join(friend_user_id: String) -> DotResult:
	var f := find_friend(friend_user_id)
	if f == null:
		return _refuse(DotError.CODE_INVALID, "That person is not on your friends list.", "friends.join.deny.notFriend")

	# The list can be thirty seconds old. One cheap request for one person is worth it
	# against sending somebody to a party that ended while they read the list.
	if backend != null:
		var fresh: DotResult = await backend.fetch_presence(PackedStringArray([friend_user_id]))
		if fresh.ok and fresh.value is Dictionary:
			var map: Dictionary = fresh.value
			if not map.has(friend_user_id):
				return _refuse(DotError.CODE_INVALID, "That person is no longer your friend.", "friends.join.deny.notFriend")
			var old := f.presence
			f.presence = map[friend_user_id]
			_announce_presence(f, old)
		elif not fresh.ok:
			DotLog.debug(CHANNEL, "could not refresh a friend's presence before joining; using the list", {
				"friend": friend_user_id, "error": str(fresh.error),
			})

	var p := f.presence
	if not p.is_online():
		return _refuse(DotError.CODE_STATE, "%s is offline." % f.display_name, "friends.join.deny.offline")
	if not p.joinable or not p.has_destination():
		return _refuse(DotError.CODE_FORBIDDEN, "%s cannot be joined right now." % f.display_name, "friends.join.deny.notJoinable")

	var party_error: DotError = null
	if p.party_id != "" and join_party_fn.is_valid():
		var joined: Variant = await join_party_fn.call(p.party_id, f)
		if not (joined is DotResult) or (joined as DotResult).ok:
			DotLog.info(CHANNEL, "joined a friend's party", {"friend": f.user_id, "party": p.party_id})
			return DotResult.success({"via": "party", "partyId": p.party_id})
		party_error = (joined as DotResult).error

	if p.server_id > 0 and connect_fn.is_valid():
		var connected: Variant = await connect_fn.call(p.server_id, f)
		if connected is DotResult and not (connected as DotResult).ok:
			return connected
		DotLog.info(CHANNEL, "followed a friend to their server", {"friend": f.user_id, "server": p.server_id})
		var value := {"via": "server", "serverId": p.server_id}
		if party_error != null:
			value["partyRefused"] = party_error
		return DotResult.success(value)

	if party_error != null:
		return DotResult.failure(party_error)
	return _refuse(DotError.CODE_UNSUPPORTED, "This game cannot follow %s there." % f.display_name, "friends.join.deny.unsupported")


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()
	out.append("friends: %d (%d online), %d incoming, %d outgoing, via %s" % [
		friends.size(), online_friends().size(), incoming.size(), outgoing.size(),
		backend.describe() if backend != null else "no backend",
	])
	out.append("  me: %s, heartbeat %.0fs%s" % [
		JSON.stringify(presence_body()), heartbeat_interval() if config != null else 0.0,
		" (change pending)" if _dirty else "",
	])
	for f in friends:
		out.append("  %s" % f.describe())
	return out


## The backend method by name rather than a bound Callable, because binding reads
## [member backend] first and a client with none would fail there instead of refusing.
func _act(what: String, method: StringName, args: Array) -> DotResult:
	if backend == null:
		return DotResult.fail(DotError.CODE_STATE, "no friends backend")
	var res: Variant = await backend.callv(method, args)
	if res is DotResult and not (res as DotResult).ok:
		request_failed.emit(what, (res as DotResult).error)
		return res
	await refresh()
	await refresh_requests()
	return res if res is DotResult else DotResult.success(res)


func _refuse(code: String, message: String, key: String) -> DotResult:
	DotLog.debug(CHANNEL, "join refused", {"reason": key})
	return DotResult.fail(code, message, key)
