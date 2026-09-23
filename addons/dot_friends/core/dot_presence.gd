class_name DotPresence
extends RefCounted

## Where one person is right now, as the backbone reports it to their friends.
##
## The fields and their names follow website-city's app API ([code]GET friends[/code],
## [code]GET presence[/code]) deliberately: a game-side model that renamed them would need
## a translation table, and a translation table is a second copy of a schema that changes
## on the site's schedule rather than ours.
##
## [b]Offline is a blank, not a last-known place.[/b] A presence that expired, or belongs to
## somebody who hides their activity, arrives with every field null — so nothing here may
## read "offline, but last on server 12" into it. A hidden player who showed their server
## while "offline" would not be hidden.
##
## [b]Ids are the site's types.[/b] [member server_id] is [code]Server.id[/code], an integer,
## as dot-party has it; [member party_id] is a decimal [b]string[/b], because a party id can
## pass 2^53 and JSON would round it into somebody else's party.

enum Status { OFFLINE, ONLINE, IN_GAME, AWAY }

## The wire names, indexed by [enum Status].
const STATUS_NAMES := ["offline", "online", "in_game", "away"]

## The site's limit on [member detail].
const DETAIL_MAX := 128

var status: Status = Status.OFFLINE

## The status exactly as it arrived. Differs from [code]STATUS_NAMES[status][/code] only
## when the site sent one this version does not know — see [method parse_status].
var status_raw: String = "offline"

## The app (game) the player's token belongs to. 0 when none.
var app_id: int = 0
var app_name: String = ""

## The site's server id. 0 when not on one.
var server_id: int = 0
var server_name: String = ""

## The dot-party party id, a decimal string. Empty when in none.
var party_id: String = ""

## Whether friends may join: their party if [member party_id] is set, otherwise their server.
var joinable: bool = false

## A line the game wrote, e.g. "Round 3 of 5". At most [constant DETAIL_MAX] characters.
var detail: String = ""

## Unix seconds of the last post the site accepted. 0 when unknown or offline.
var updated_at: int = 0


static func offline() -> DotPresence:
	return DotPresence.new()


## Unknown statuses read as ONLINE, not OFFLINE. An unknown status is the site having
## grown one ("busy", say); a person who sent it is certainly there, and showing them as
## offline would hide exactly the friends a newer site had something to say about.
static func parse_status(s: String) -> Status:
	var i := STATUS_NAMES.find(s.strip_edges().to_lower())
	if i >= 0:
		return i as Status
	return Status.OFFLINE if s.strip_edges() == "" else Status.ONLINE


static func status_name(s: Status) -> String:
	return STATUS_NAMES[s]


## Reads a presence object exactly as the site sends it. Tolerant of absent and null
## fields — every one of them is nullable in the contract — and of a null presence, which
## is offline.
static func from_dict(d: Variant) -> DotPresence:
	var p := DotPresence.new()
	if not (d is Dictionary):
		return p
	var src: Dictionary = d
	p.status_raw = _str(src.get("status"))
	if p.status_raw == "":
		p.status_raw = "offline"
	p.status = parse_status(p.status_raw)
	p.app_id = _int(src.get("appId"))
	p.app_name = _str(src.get("appName"))
	p.server_id = _int(src.get("serverId"))
	p.server_name = _str(src.get("serverName"))
	p.party_id = _str(src.get("partyId"))
	p.joinable = src.get("joinable") == true
	p.detail = _str(src.get("detail"))
	p.updated_at = parse_time(src.get("updatedAt"))
	return p


func to_dict() -> Dictionary:
	return {
		"status": status_raw if status_raw != "" else STATUS_NAMES[status],
		"appId": app_id if app_id > 0 else null,
		"appName": app_name if app_name != "" else null,
		"serverId": server_id if server_id > 0 else null,
		"serverName": server_name if server_name != "" else null,
		"partyId": party_id if party_id != "" else null,
		"joinable": joinable,
		"detail": detail if detail != "" else null,
		"updatedAt": format_time(updated_at),
	}


func copy() -> DotPresence:
	return DotPresence.from_dict(to_dict())


func is_online() -> bool:
	return status != Status.OFFLINE


## Whether there is anything a friend could join, before asking whether they may.
func has_destination() -> bool:
	return party_id != "" or server_id > 0


## Whether two presences say the same thing to a person looking at them.
##
## [member updated_at] is left out on purpose: it moves on every heartbeat, and a client
## that diffed on it would announce "presence changed" every 45 seconds for every friend.
func same_as(other: DotPresence) -> bool:
	if other == null:
		return false
	return status_raw == other.status_raw \
		and app_id == other.app_id and app_name == other.app_name \
		and server_id == other.server_id and server_name == other.server_name \
		and party_id == other.party_id and joinable == other.joinable \
		and detail == other.detail


func describe() -> String:
	if status == Status.OFFLINE:
		return "offline"
	var parts := PackedStringArray([status_raw])
	if app_name != "":
		parts.append("in %s" % app_name)
	if server_id > 0:
		parts.append("on %s" % (server_name if server_name != "" else "server %d" % server_id))
	if party_id != "":
		parts.append("party %s" % party_id)
	if joinable:
		parts.append("joinable")
	if detail != "":
		parts.append("\"%s\"" % detail)
	return ", ".join(parts)


## An ISO 8601 string, a number of Unix seconds, or null, as Unix seconds (0 for none).
##
## The backbone sends ISO strings; a local hub and a suite send numbers. Both, because the
## alternative is two parsers and the one that is not tested drifting.
static func parse_time(v: Variant) -> int:
	if v == null:
		return 0
	if v is int or v is float:
		return int(v)
	var s := str(v).strip_edges()
	if s == "":
		return 0
	if s.is_valid_int():
		return s.to_int()
	# Time.get_unix_time_from_datetime_string wants no fraction and no zone.
	var core := s.replace("Z", "")
	var dot := core.find(".")
	if dot >= 0:
		core = core.substr(0, dot)
	var plus := core.find("+", 10)
	if plus >= 0:
		core = core.substr(0, plus)
	return int(Time.get_unix_time_from_datetime_string(core))


## Unix seconds as the ISO string the backbone sends, or null for none.
##
## The second argument of [code]get_datetime_string_from_unix_time[/code] is
## [code]use_space[/code], not "utc" — passing true would drop the [code]T[/code].
static func format_time(t: int) -> Variant:
	if t <= 0:
		return null
	return Time.get_datetime_string_from_unix_time(t) + "Z"


## null reads as "", never as the string "<null>".
static func _str(v: Variant) -> String:
	return "" if v == null else str(v)


## A number, a decimal string or null, as an int (0 for none or nonsense).
static func _int(v: Variant) -> int:
	if v is int or v is float:
		return int(v)
	if v is String and (v as String).is_valid_int():
		return (v as String).to_int()
	return 0
