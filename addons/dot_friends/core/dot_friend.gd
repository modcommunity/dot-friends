class_name DotFriend
extends RefCounted

## One accepted friend, and where they are, as [code]GET friends[/code] returns them.
##
## [member user_id] is the backbone's user id — the same string dot-party's members carry
## and the one a dot-server session sees as [code]backbone:<user_id>[/code]. Friends are
## matched by it and never by name, because a display name is the one field a stranger
## can copy.

var user_id: String = ""
var display_name: String = ""

## Empty when the site has none for them.
var avatar_url: String = ""

var presence: DotPresence = DotPresence.new()


static func of(p_user_id: String, p_name: String, p_presence: DotPresence = null) -> DotFriend:
	var f := DotFriend.new()
	f.user_id = p_user_id
	f.display_name = p_name
	f.presence = p_presence if p_presence != null else DotPresence.offline()
	return f


## Reads one row of [code]GET friends[/code]. A row with no user id is refused rather than
## kept: it could never be matched against a presence, a request or a party member.
static func from_dict(d: Dictionary) -> DotResult:
	var f := DotFriend.new()
	f.user_id = DotPresence._str(d.get("userId"))
	if f.user_id == "":
		return DotResult.fail(DotError.CODE_PARSE, "a friend with no user id", str(d))
	f.display_name = DotPresence._str(d.get("displayName"))
	f.avatar_url = DotPresence._str(d.get("avatarUrl"))
	f.presence = DotPresence.from_dict(d.get("presence"))
	return DotResult.success(f)


## Reads the whole [code]GET friends[/code] array. One bad row is skipped rather than
## failing the list: a friends list missing one person is still a friends list, and one
## that fails outright shows nobody.
static func list_from(v: Variant) -> DotResult:
	if not (v is Array):
		return DotResult.fail(DotError.CODE_PARSE, "The friends list is not a list.")
	var out: Array[DotFriend] = []
	for row in (v as Array):
		if not (row is Dictionary):
			continue
		var parsed := DotFriend.from_dict(row as Dictionary)
		if parsed.ok:
			out.append(parsed.value)
	return DotResult.success(out)


func to_dict() -> Dictionary:
	return {
		"userId": user_id,
		"displayName": display_name,
		"avatarUrl": avatar_url if avatar_url != "" else null,
		"presence": presence.to_dict(),
	}


func copy() -> DotFriend:
	return DotFriend.from_dict(to_dict()).value


func is_online() -> bool:
	return presence.is_online()


func describe() -> String:
	return "%s (%s): %s" % [display_name, user_id, presence.describe()]
