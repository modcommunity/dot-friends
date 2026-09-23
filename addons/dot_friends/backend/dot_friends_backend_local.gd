class_name DotFriendsBackendLocal
extends DotFriendsBackend

## One person's view of a [DotFriendsLocalHub]. Get one with [method DotFriendsLocalHub.as_user].
##
## Carries the app this person is playing, because on the site that comes from the token
## rather than from the post — a client cannot claim to be in a game it is not.

var hub: DotFriendsLocalHub = null
var user_id: String = ""
var app_id: int = 0
var app_name: String = ""


func _init(p_hub: DotFriendsLocalHub = null, p_user_id: String = "", p_app_id: int = 0, p_app_name: String = "") -> void:
	hub = p_hub
	user_id = p_user_id
	app_id = p_app_id
	app_name = p_app_name


func friends() -> DotResult:
	return hub.friends_of(user_id)


func requests() -> DotResult:
	return hub.requests_of(user_id)


func send_request(target: String) -> DotResult:
	return hub.send_request(user_id, target)


func respond(request_id: int, accept: bool) -> DotResult:
	return hub.respond(user_id, request_id, accept)


func remove_friend(target: String) -> DotResult:
	return hub.remove_friend(user_id, target)


func post_presence(body: Dictionary) -> DotResult:
	return hub.post_presence(user_id, body, app_id, app_name)


func fetch_presence(user_ids: PackedStringArray) -> DotResult:
	return hub.presence_for(user_id, user_ids)


func describe() -> String:
	return "local friends hub, as %s" % user_id
