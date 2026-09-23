@tool
class_name DotFriendsConfig
extends DotConfig

## Timings for the player's friends list and their own presence.
##
## The one number that is not ours is the presence TTL: the site forgets a presence about
## 120 seconds after the last post, and a player whose client heartbeats slower than that
## blinks offline to every friend between posts. [method validate] refuses it.

## The site's presence lifetime, mirrored. The site's own answer ([code]ttlSec[/code])
## overrides it at runtime; this is what is assumed before the first answer.
const PRESENCE_TTL_SEC := 120.0

## Seconds between polls of the friends list. Relaxed on purpose: every signed-in player
## polls this, and "Sam came online" thirty seconds late costs nobody anything.
@export_range(5.0, 600.0, 0.5) var poll_sec: float = 30.0

## Seconds between polls of pending requests. A request is an inbox, not a status.
@export_range(5.0, 3600.0, 1.0) var requests_poll_sec: float = 60.0

## Seconds between presence posts when nothing has changed. Well under the TTL, so one
## lost post does not take the player offline: at 45 against 120, two can be lost.
@export_range(5.0, 110.0, 1.0) var heartbeat_sec: float = 45.0

## Seconds a change waits before it is posted, so a burst — joining a server sets the
## server, then the party, then joinable — goes out as one post rather than three. Counted
## from the FIRST change of the burst, so a stream of changes cannot postpone it forever.
@export_range(0.0, 10.0, 0.05) var presence_debounce_sec: float = 0.75


func env_prefix() -> String:
	return "DOT_FRIENDS_"


func cli_prefix() -> String:
	return "--friends-"


func validate() -> DotResult:
	if heartbeat_sec * 2.0 > PRESENCE_TTL_SEC:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"a presence heartbeat of %.0fs leaves room for no lost post inside the site's %.0fs lifetime" % [heartbeat_sec, PRESENCE_TTL_SEC],
			"the player would blink offline to every friend whenever one post was late"
		)
	if presence_debounce_sec >= heartbeat_sec:
		return DotResult.fail(DotError.CODE_INVALID, "the presence debounce is longer than the heartbeat")
	return DotResult.success(null)


func describe_lines(_redact_sensitive: bool = true) -> PackedStringArray:
	var out := PackedStringArray()
	out.append("friends: poll %.1fs, requests %.0fs, presence heartbeat %.0fs, debounce %.2fs" % [
		poll_sec, requests_poll_sec, heartbeat_sec, presence_debounce_sec,
	])
	return out
