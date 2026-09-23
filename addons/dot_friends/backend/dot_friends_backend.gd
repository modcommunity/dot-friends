class_name DotFriendsBackend
extends RefCounted

## Where a friends list and its presence actually live. Every change is asked of this,
## and every answer is the site's.
##
## Two implementations: [DotFriendsBackendApp] speaks to website-city as the signed-in
## player, and [DotFriendsBackendLocal] runs the same rules in-process, for a LAN, an
## offline build and the suite. A game holds one and does not know which.
##
## [b]Every method may await.[/b] Call each as [code]await backend.friends()[/code] even
## against the local one, which answers at once; a caller written against the local
## backend without the [code]await[/code] would break the day it is pointed at the site.
##
## [b]Refusals carry a reason key[/b] in [member DotError.detail] —
## [code]friends.request.deny.self[/code], [code]presence.deny.detail[/code] — from either
## backend, because a client has copy for each one and a message it had to read English out
## of would leave it with none.

## Value: [code]Array[DotFriend][/code], each with their presence as this player may see it.
func friends() -> DotResult:
	return _unsupported("friends")


## Value: [code]{"incoming": Array[DotFriendRequest], "outgoing": Array[DotFriendRequest]}[/code].
func requests() -> DotResult:
	return _unsupported("requests")


## Value: [code]{id}[/code]. Asking somebody who already asked you is accepting them,
## which is what the person obviously means — the site's rule, kept.
func send_request(_user_id: String) -> DotResult:
	return _unsupported("send_request")


## Accepts or declines a request addressed to this player.
func respond(_request_id: int, _accept: bool) -> DotResult:
	return _unsupported("respond")


## Ends a friendship, from either side.
func remove_friend(_user_id: String) -> DotResult:
	return _unsupported("remove_friend")


## Posts this player's presence. [param body] is the wire body:
## [code]{status, serverId?, partyId?, joinable?, detail?}[/code]. Each post replaces the
## whole presence; a field left out is cleared. Value: [code]{ttlSec}[/code], how long the
## site keeps it without another post.
func post_presence(_body: Dictionary) -> DotResult:
	return _unsupported("post_presence")


## Value: [code]{userId: DotPresence}[/code] for those of [param user_ids] who are this
## player's friends. At most 100 per call.
func fetch_presence(_user_ids: PackedStringArray) -> DotResult:
	return _unsupported("fetch_presence")


func describe() -> String:
	return "friends backend"


func _unsupported(what: String) -> DotResult:
	return DotResult.fail(DotError.CODE_UNSUPPORTED, "This friends backend cannot %s." % what.replace("_", " "))
