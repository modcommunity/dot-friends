class_name DotFriendsLocalHub
extends RefCounted

## Friends and presence with no website: the backbone's rules, run in-process.
##
## For a LAN, an offline build, a game that ships its own friends screen without TMC, and
## the suite. Several [DotFriendsBackendLocal]s share one hub, each acting as one person,
## because every interesting rule here is between two people and a test with one person in
## it cannot reach any of them.
##
## [b]The request rules are website-city's[/b], read from its friend router rather than
## invented: one row per pair whoever asked first; you cannot add yourself; a person who has
## turned requests off cannot be asked; asking somebody who already asked you [b]accepts[/b]
## them rather than failing; a second request while one is pending is refused; a declined
## sender waits seven days before asking again, and only the sender — the person who
## declined may always ask; only the addressee may answer; removing needs an accepted
## friendship, from either side, and deletes the row, so both have to ask again.
##
## [b]Presence is the contract's[/b]: a post lives [constant PRESENCE_TTL_SEC] seconds and is
## then offline; a person who hides their activity is offline to everybody, with nothing
## else in the presence either; presence is only ever shown to friends.
##
## [b]Refusal keys.[/b] The site's friend procedures throw tRPC codes with English
## messages, not keys, so the keys here ([code]friends.request.deny.self[/code] and the
## rest, listed in [code]docs/backbone-contract.md[/code]) are this addon's proposal for the
## app routes. If the site ships different ones, the table and this file change together.

const CHANNEL := "friends.local"

## How long a presence post lives without another. The contract's figure.
const PRESENCE_TTL_SEC := 120

## The site's FRIEND_REREQUEST_COOLDOWN_MS, in seconds.
const REREQUEST_COOLDOWN_SEC := 7 * 24 * 60 * 60

const PRESENCE_BATCH_MAX := 100

## Unix seconds. The suite replaces it.
var now_fn: Callable = func() -> int: return int(Time.get_unix_time_from_system())

## user id -> display name. A user this hub has never heard of cannot be asked, as on the
## site, where an unknown id is "Member not found".
var names: Dictionary = {}

## user id -> avatar URL.
var avatars: Dictionary = {}

## server id -> name, so a presence on a server reads with the server's name as the site's does.
var server_names: Dictionary = {}

## user id -> true for people who have turned friend requests off.
var _closed: Dictionary = {}
## user id -> true for people who hide their activity.
var _hidden: Dictionary = {}
## request id -> {id, from, to, status: "PENDING"|"ACCEPTED"|"DECLINED", created, responded}
var _rows: Dictionary = {}
## user id -> {presence: DotPresence, expires: int}
var _presence: Dictionary = {}
var _next_id: int = 1


func as_user(user_id: String, display_name: String = "", app_id: int = 0, app_name: String = "") -> DotFriendsBackendLocal:
	names[user_id] = display_name if display_name != "" else str(names.get(user_id, user_id))
	return DotFriendsBackendLocal.new(self, user_id, app_id, app_name)


func now() -> int:
	return int(now_fn.call())


## The site's [code]allowFriendRequests[/code].
func set_accepting_requests(user_id: String, accepting: bool) -> void:
	if accepting:
		_closed.erase(user_id)
	else:
		_closed[user_id] = true


## The site's "hide my activity". A hidden person still posts; their friends just see offline.
func set_activity_hidden(user_id: String, hidden: bool) -> void:
	if hidden:
		_hidden[user_id] = true
	else:
		_hidden.erase(user_id)


# --- Requests ----------------------------------------------------------------

func send_request(me: String, target: String) -> DotResult:
	if me == target:
		return _deny(DotError.CODE_INVALID, "You cannot add yourself.", "friends.request.deny.self")
	if not names.has(target):
		return _deny(DotError.CODE_INVALID, "Member not found.", "friends.request.deny.notFound")
	if _closed.has(target):
		return _deny(DotError.CODE_FORBIDDEN, "This member is not accepting friend requests.", "friends.request.deny.closed")

	var row := _row_between(me, target)
	if not row.is_empty():
		match str(row["status"]):
			"ACCEPTED":
				return _deny(DotError.CODE_CONFLICT, "You are already friends.", "friends.request.deny.already")
			"PENDING":
				if str(row["from"]) != me:
					# They already asked: this is a yes.
					_accept(row)
					return DotResult.success({"id": int(row["id"])})
				return _deny(DotError.CODE_CONFLICT, "A request is already pending.", "friends.request.deny.pending")
			"DECLINED":
				var declined_me := str(row["from"]) == me
				if declined_me and now() - int(row["responded"]) < REREQUEST_COOLDOWN_SEC:
					return _deny(DotError.CODE_FORBIDDEN, "This request was declined recently. You can try again later.", "friends.request.deny.cooldown")
				# Re-oriented to whoever is asking now, as the site does.
				row["from"] = me
				row["to"] = target
				row["status"] = "PENDING"
				row["created"] = now()
				row["responded"] = 0
				return DotResult.success({"id": int(row["id"])})

	var id := _next_id
	_next_id += 1
	_rows[id] = {"id": id, "from": me, "to": target, "status": "PENDING", "created": now(), "responded": 0}
	DotLog.debug(CHANNEL, "friend request", {"id": id, "from": me, "to": target})
	return DotResult.success({"id": id})


## Only the addressee may answer, and only a pending request. Anything else is "not found",
## never "not yours": the site scopes the update by addressee so a requester cannot decline
## their own request into a cooldown against the person they asked.
func respond(me: String, request_id: int, accept: bool) -> DotResult:
	var row: Dictionary = _rows.get(request_id, {})
	if row.is_empty() or str(row["to"]) != me or str(row["status"]) != "PENDING":
		return _deny(DotError.CODE_INVALID, "Request not found.", "friends.respond.deny.notFound")
	if accept:
		_accept(row)
	else:
		row["status"] = "DECLINED"
		row["responded"] = now()
		DotLog.debug(CHANNEL, "friend request declined", {"id": request_id})
	return DotResult.success(null)


## Only the sender may withdraw, and only a pending request; anything else is "not found",
## as an answer is. The row goes, so nothing is left to cool down: withdrawing is not
## being declined, and the sender may ask again at once.
func cancel_request(me: String, request_id: int) -> DotResult:
	var row: Dictionary = _rows.get(request_id, {})
	if row.is_empty() or str(row["from"]) != me or str(row["status"]) != "PENDING":
		return _deny(DotError.CODE_INVALID, "Request not found.", "friends.cancel.deny.notFound")
	_rows.erase(request_id)
	DotLog.debug(CHANNEL, "friend request withdrawn", {"id": request_id})
	return DotResult.success(null)


func remove_friend(me: String, other: String) -> DotResult:
	var row := _row_between(me, other)
	if row.is_empty() or str(row["status"]) != "ACCEPTED":
		return _deny(DotError.CODE_INVALID, "You are not friends with this member.", "friends.remove.deny.notFriends")
	_rows.erase(int(row["id"]))
	DotLog.debug(CHANNEL, "friendship removed", {"a": me, "b": other})
	return DotResult.success(null)


func are_friends(a: String, b: String) -> bool:
	var row := _row_between(a, b)
	return not row.is_empty() and str(row["status"]) == "ACCEPTED"


func requests_of(me: String) -> DotResult:
	var incoming: Array[DotFriendRequest] = []
	var outgoing: Array[DotFriendRequest] = []
	for row in _sorted_rows():
		if str(row["status"]) != "PENDING":
			continue
		var mine := str(row["from"]) == me
		if not mine and str(row["to"]) != me:
			continue
		var other := str(row["to"]) if mine else str(row["from"])
		var r := DotFriendRequest.new()
		r.id = int(row["id"])
		r.user_id = other
		r.display_name = str(names.get(other, other))
		r.created_at = int(row["created"])
		r.outgoing = mine
		if mine:
			outgoing.append(r)
		else:
			incoming.append(r)
	return DotResult.success({"incoming": incoming, "outgoing": outgoing})


## Everybody [param me] is friends with, each with their presence as [param me] may see it.
## Ordered online first and then by name, so a list rendered as it arrives answers "who can
## I play with" before "who do I know".
func friends_of(me: String) -> DotResult:
	var out: Array[DotFriend] = []
	for row in _sorted_rows():
		if str(row["status"]) != "ACCEPTED":
			continue
		var other := ""
		if str(row["from"]) == me:
			other = str(row["to"])
		elif str(row["to"]) == me:
			other = str(row["from"])
		else:
			continue
		var f := DotFriend.of(other, str(names.get(other, other)), presence_seen_by(me, other))
		f.avatar_url = str(avatars.get(other, ""))
		out.append(f)
	out.sort_custom(func(a: DotFriend, b: DotFriend) -> bool:
		if a.is_online() != b.is_online():
			return a.is_online()
		return a.display_name.naturalnocasecmp_to(b.display_name) < 0)
	return DotResult.success(out)


# --- Presence ----------------------------------------------------------------

func post_presence(me: String, body: Dictionary, app_id: int = 0, app_name: String = "") -> DotResult:
	var status_name := str(body.get("status", ""))
	if not DotPresence.STATUS_NAMES.has(status_name):
		return _deny(DotError.CODE_INVALID, "That is not a presence status.", "presence.deny.status")
	var detail := DotPresence._str(body.get("detail"))
	if detail.length() > DotPresence.DETAIL_MAX:
		return _deny(DotError.CODE_INVALID, "That presence line is too long.", "presence.deny.detail")

	var p := DotPresence.new()
	p.status_raw = status_name
	p.status = DotPresence.parse_status(status_name)
	if p.is_online():
		p.app_id = app_id
		p.app_name = app_name
		p.server_id = DotPresence._int(body.get("serverId"))
		p.server_name = str(server_names.get(p.server_id, "")) if p.server_id > 0 else ""
		p.party_id = DotPresence._str(body.get("partyId"))
		p.joinable = body.get("joinable") == true
		p.detail = detail
		p.updated_at = now()
	_presence[me] = {"presence": p, "expires": now() + PRESENCE_TTL_SEC}
	return DotResult.success({"ttlSec": PRESENCE_TTL_SEC})


## [param target]'s presence as [param viewer] may see it: offline, and blank, unless they
## are friends, [param target] has posted within the TTL, and does not hide their activity.
func presence_seen_by(viewer: String, target: String) -> DotPresence:
	if viewer != target and not are_friends(viewer, target):
		return DotPresence.offline()
	if _hidden.has(target):
		return DotPresence.offline()
	var entry: Dictionary = _presence.get(target, {})
	if entry.is_empty() or now() >= int(entry["expires"]):
		return DotPresence.offline()
	var p: DotPresence = entry["presence"]
	return p.copy()


## [code]GET presence?userIds=[/code]. People who are not [param me]'s friends are left out
## of the answer rather than shown offline: "offline" would still confirm that the id is
## somebody, and the route is for friends.
func presence_for(me: String, user_ids: PackedStringArray) -> DotResult:
	if user_ids.size() > PRESENCE_BATCH_MAX:
		return _deny(DotError.CODE_INVALID, "At most 100 people at once.", "presence.deny.batch")
	var out := {}
	for uid in user_ids:
		if are_friends(me, uid):
			out[uid] = presence_seen_by(me, uid)
	return DotResult.success(out)


## Forgets presences past their TTL. Reads already treat them as offline; this only keeps
## a long-running LAN hub from holding every visitor it ever had.
func tick() -> void:
	var t := now()
	for uid in _presence.keys():
		if t >= int((_presence[uid] as Dictionary)["expires"]):
			_presence.erase(uid)


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()
	var friendships := 0
	var pending := 0
	for row in _rows.values():
		if str(row["status"]) == "ACCEPTED":
			friendships += 1
		elif str(row["status"]) == "PENDING":
			pending += 1
	out.append("friends hub: %d people, %d friendships, %d pending, %d presences" % [
		names.size(), friendships, pending, _presence.size(),
	])
	return out


# --- Internals ---------------------------------------------------------------

func _accept(row: Dictionary) -> void:
	row["status"] = "ACCEPTED"
	row["responded"] = now()
	DotLog.debug(CHANNEL, "friendship accepted", {"a": row["from"], "b": row["to"]})


func _row_between(a: String, b: String) -> Dictionary:
	for row in _rows.values():
		if (str(row["from"]) == a and str(row["to"]) == b) or (str(row["from"]) == b and str(row["to"]) == a):
			return row
	return {}


## Rows in id order, so two lists built from one hub agree about order.
func _sorted_rows() -> Array:
	var ids := _rows.keys()
	ids.sort()
	var out: Array = []
	for id in ids:
		out.append(_rows[id])
	return out


static func _deny(code: String, message: String, key: String) -> DotResult:
	return DotResult.fail(code, message, key)
