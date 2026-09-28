class_name DotFriendsBackendApp
extends DotFriendsBackend

## website-city, as the signed-in player.
##
## [b]The app API's envelope, not the integration API's.[/b] [code]{ok: true, data}[/code]
## on success and [code]{ok: false, code, message, retryAfter?}[/code] on failure, as
## [code]src/types/app-api/contract.ts[/code] defines it. The site's refusal key arrives as
## [code]code[/code] and lands in [member DotError.detail], where the local backend puts
## its own. The routes are in [code]docs/backbone-contract.md[/code].
##
## [b]Neither dot-auth nor its client is named.[/b] Give it [member client] — any object
## with [code]post_app(path, body)[/code] and [code]get_app(path, query)[/code], which is
## dot-auth's [code]DotAuthClient[/code] — and the token, its refresh and the envelope are
## handled there, once, for every addon that speaks the app API. [member token_fn] with a
## [DotHttp] is the fallback for a game without dot-auth, and [member request_fn] replaces
## the transport entirely, which is how the suite drives it.

const CHANNEL := "friends.app"

## What the site allows in one [code]GET presence[/code].
const PRESENCE_BATCH_MAX := 100

const _NO_ROUTES := "the site has no app friends routes yet; see dot-friends' docs/backbone-contract.md"

## Anything with [code]post_app(path, body)[/code] and [code]get_app(path, query)[/code]
## returning the envelope's data. Preferred over [member token_fn] when set.
var client: Object = null

## Where [code]/api/app/v1[/code] is, e.g. [code]https://tmc.example/api/app/v1[/code].
var api_base: String = ""

## [code]func() -> String[/code]: the current access token.
var token_fn: Callable = Callable()

## Does the requests. Needs to be in the tree; a game adds it once.
var http: DotHttp = null

## [code]func(method: String, path: String, body: Dictionary) -> DotResult[/code] answering
## with the raw envelope (or a failed [DotResult] from [method DotError.from_http]),
## replacing the HTTP call entirely. The suite uses it; so can a game with its own transport.
var request_fn: Callable = Callable()

## Whether the last request failed at the SERVICE rather than being refused by it, so an
## outage is logged on its edges: the client posts presence every 45 seconds, and a WARN
## per post while the site is down would bury the line that says when it went.
var _failing: bool = false

## Whether a bare 404 has said the site has no friends routes. Kept apart from
## [member _failing] because it is not an outage and is not logged as one. See [method _call].
var _no_routes: bool = false

## Codes the site uses to say no. Those are the rules working and are not the service failing.
const _REFUSALS := [
	DotError.CODE_CONFLICT, DotError.CODE_AUTH, DotError.CODE_RATE_LIMITED,
	DotError.CODE_INVALID, DotError.CODE_FORBIDDEN,
]


func _init(p_api_base: String = "", p_http: DotHttp = null, p_token_fn: Callable = Callable()) -> void:
	api_base = p_api_base
	http = p_http
	token_fn = p_token_fn


func friends() -> DotResult:
	var res := await _call("GET", "friends")
	if not res.ok:
		return res
	return DotFriend.list_from(res.value)


func requests() -> DotResult:
	var res := await _call("GET", "friends/requests")
	if not res.ok:
		return res
	return DotFriendRequest.lists_from(res.value)


func send_request(user_id: String) -> DotResult:
	if user_id == "":
		return DotResult.fail(DotError.CODE_INVALID, "Nobody to send a request to.", "friends.request.deny.notFound")
	return await _call("POST", "friends/request", {"userId": user_id})


func respond(request_id: int, accept: bool) -> DotResult:
	return await _call("POST", "friends/respond", {"requestId": request_id, "accept": accept})


func cancel_request(request_id: int) -> DotResult:
	return await _call("POST", "friends/cancel", {"requestId": request_id})


func remove_friend(user_id: String) -> DotResult:
	return await _call("POST", "friends/remove", {"userId": user_id})


func post_presence(body: Dictionary) -> DotResult:
	# Refused here as well as on the site: a post the site will refuse is a heartbeat that
	# did not happen, and the player goes offline to everybody 120 seconds later for a
	# reason nobody will think to look for.
	if str(body.get("detail", "")).length() > DotPresence.DETAIL_MAX:
		return DotResult.fail(DotError.CODE_INVALID, "That presence line is too long.", "presence.deny.detail")
	var res := await _call("POST", "presence", body)
	if not res.ok:
		return res
	var data: Variant = res.value
	var ttl := 0
	if data is Dictionary:
		ttl = DotPresence._int((data as Dictionary).get("ttlSec"))
	return DotResult.success({"ttlSec": ttl})


func fetch_presence(user_ids: PackedStringArray) -> DotResult:
	if user_ids.is_empty():
		return DotResult.success({})
	if user_ids.size() > PRESENCE_BATCH_MAX:
		return DotResult.fail(DotError.CODE_INVALID, "At most 100 people at once.", "presence.deny.batch")
	var res := await _call("GET", "presence", {}, {"userIds": ",".join(user_ids)})
	if not res.ok:
		return res
	var out := {}
	if res.value is Dictionary:
		var data: Dictionary = res.value
		for k in data:
			out[str(k)] = DotPresence.from_dict(data[k])
	return DotResult.success(out)


func describe() -> String:
	return "website-city at %s" % (api_base if api_base != "" else "(through the auth client)")


## One request, unwrapped from the app API's envelope. Value: the envelope's [code]data[/code].
##
## Logged here because every call in this class passes through it. A refusal is DEBUG; the
## service failing — the network, a 5xx, an answer that is not an envelope — is WARN when it
## starts, DEBUG while it lasts and INFO when a call succeeds again. WARN rather than ERROR:
## a friends list is an extra on top of playing.
##
## [b]A site with no friends routes is ONE INFO line, and nothing more.[/b] It is not an
## outage — it is the site as deployed today, and nothing anybody can fix from here — so a
## WARN for it was a warning on every sign-in against every site without the routes, and a
## caller that switches friends off for the session (dot-server-deploy's shell does, on the
## first bare 404) logged its own line after it: two lines for one fact.
func _call(method: String, path: String, body: Dictionary = {}, query: Dictionary = {}) -> DotResult:
	var res := await _call_inner(method, path, body, query)

	if res.ok:
		if _failing or _no_routes:
			_failing = false
			_no_routes = false
			DotLog.info(CHANNEL, "the friends service is answering again", {"api": api_base})
		return res

	var fields := {
		"call": "%s %s" % [method, path],
		"code": res.code(),
		"error": res.error.message if res.error != null else "",
		"site_code": res.error.detail if res.error != null else "",
	}

	if _is_missing_route(res):
		if _no_routes:
			DotLog.debug(CHANNEL, "the site still has no friends routes", fields)
		else:
			_no_routes = true
			fields["api"] = api_base
			DotLog.info(CHANNEL, "the site does not serve the friends routes yet; friends are unavailable", fields)
	elif res.code() in _REFUSALS:
		DotLog.debug(CHANNEL, "the friends service refused", fields)
	elif _failing:
		DotLog.debug(CHANNEL, "the friends service is still failing", fields)
	else:
		_failing = true
		fields["api"] = api_base
		DotLog.warn(CHANNEL, "the friends service is failing", fields)

	return res


## A 404 with no site code is a site that has not grown the routes: an outage in all but
## name, and logged as one rather than as a refusal nobody reads at DEBUG.
func _is_missing_route(res: DotResult) -> bool:
	return res.error != null and res.error.http_status == 404 and res.error.message.contains("no app friends routes")


func _call_inner(method: String, path: String, body: Dictionary = {}, query: Dictionary = {}) -> DotResult:
	if request_fn.is_valid() or client == null:
		var full := path
		if not query.is_empty():
			var parts := PackedStringArray()
			for k in query:
				parts.append("%s=%s" % [str(k).uri_encode(), str(query[k]).uri_encode()])
			full += "?" + "&".join(parts)
		var raw: DotResult = null
		if request_fn.is_valid():
			raw = await request_fn.call(method, full, body)
		else:
			raw = await _http_call(method, full, body)
		if not raw.ok:
			return _explain(raw)
		if not (raw.value is Dictionary):
			return DotResult.fail(DotError.CODE_PARSE, "The friends service answered with something that is not an object.")
		var env: Dictionary = raw.value
		if env.get("ok") == false:
			return _refusal(env, 0)
		return DotResult.success(env.get("data"))

	# Through dot-auth: the envelope is already unwrapped, and a refusal's site code is
	# already in the error's detail.
	var res: DotResult = null
	if method == "GET":
		res = await client.call("get_app", path, query)
	else:
		res = await client.call("post_app", path, body)
	if not res.ok and res.error != null and res.error.http_status == 404 and res.error.detail == "":
		return _hint_404(res)
	return res


func _http_call(method: String, path: String, body: Dictionary) -> DotResult:
	if http == null:
		return DotResult.fail(DotError.CODE_STATE, "no HTTP client")
	if not token_fn.is_valid():
		return DotResult.fail(DotError.CODE_AUTH, "Sign in to see your friends.")
	var token := str(token_fn.call())
	if token == "":
		return DotResult.fail(DotError.CODE_AUTH, "Sign in to see your friends.")
	var url := api_base.trim_suffix("/") + "/" + path
	var headers := {"Authorization": "Bearer %s" % token}
	if method == "GET":
		return await http.get_json(url, headers)
	return await http.post_json(url, body, headers)


## A non-2xx carries the envelope in its body; lift the site's code and message out of it.
func _explain(raw: DotResult) -> DotResult:
	var e := raw.error
	if e == null:
		return raw
	var parsed: Variant = _envelope_of(e.detail)
	if parsed is Dictionary and (parsed as Dictionary).has("code"):
		return _refusal(parsed as Dictionary, e.http_status, e.code)
	if e.http_status == 404:
		return _hint_404(raw)
	return raw


## [method DotResult.wrap] keeps the code and the status and moves the cause into the
## detail — which is where a refusal key would go, and a 404 with no envelope has none.
func _hint_404(res: DotResult) -> DotResult:
	var wrapped := res.wrap(_NO_ROUTES)
	wrapped.error.detail = ""
	return wrapped


func _refusal(env: Dictionary, status: int, fallback_code: String = DotError.CODE_CONFLICT) -> DotResult:
	var site_code := str(env.get("code", ""))
	var message := str(env.get("message", "The friends service refused."))
	var code := fallback_code
	if status == 0:
		code = DotError.CODE_CONFLICT
		# `token_expired` too: an expired token is the one refusal a client can fix by
		# signing in again, and read as a conflict it was shown as a refusal to argue with.
		if site_code == "unauthorized" or site_code == "wrong_credential" \
				or site_code == "token_expired":
			code = DotError.CODE_AUTH
		elif site_code.begins_with("rate"):
			code = DotError.CODE_RATE_LIMITED
	var err := DotError.make(code, message, site_code)
	err.http_status = status
	if env.get("retryAfter") != null:
		err.retry_after = float(env["retryAfter"])
	return DotResult.failure(err)

## A refusal's body as a Dictionary, or null — without the engine's own ERROR line.
##
## The detail is only ever an envelope when it is a JSON object. A transport failure
## ("engine error 3") and a proxy's HTML error page are text, and [code]JSON.parse_string[/code]
## prints an unsuppressible ERROR for each before answering null — found by driving the
## backend at a live site whose request failed before it was sent.
static func _envelope_of(detail: String) -> Variant:
	if not detail.strip_edges().begins_with("{"):
		return null
	var json := JSON.new()
	if json.parse(detail) != OK:
		return null
	return json.data
