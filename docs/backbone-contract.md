# The backbone contract

What dot-friends speaks. Every route is under `/api/app/v1`, authenticated by the player's app token (`Authorization: Bearer <AppToken>`), and in the app API's envelope: `{ ok: true, data }` or `{ ok: false, code, message, retryAfter? }` (`src/types/app-api/contract.ts`). For a refusal, `code` is an i18n key. Each route must allow `GAME` tokens, because that is the token a game holds.

These routes were specified alongside this addon and were being written on the site at the same time. **When this was written, none of them was served yet**, so `DotFriendsBackendApp` turns a bare 404 into "the site has no app friends routes yet" rather than into a refusal.

## Routes

| Route | Body / query | `data` | Used by |
| --- | --- | --- | --- |
| `GET friends` | — | `[Friend]` | `DotFriendsBackendApp.friends`, polled every 30 s |
| `GET friends/requests` | — | `{ incoming: [Request], outgoing: [Request] }` | `requests`, polled every 60 s |
| `POST friends/request` | `{ userId }` | `{ id }` | `send_request` |
| `POST friends/respond` | `{ requestId, accept }` | `null` | `respond` |
| `POST friends/remove` | `{ userId }` | `null` | `remove_friend` |
| `POST presence` | `{ status, serverId?, partyId?, joinable?, detail? }` | `{ ttlSec }` | `post_presence`, on a heartbeat and on change |
| `GET presence?userIds=a,b` | at most 100 ids, comma-separated | `{ [userId]: Presence }` | `fetch_presence`, before every join |

### Shapes

```
Friend   = { userId, displayName, avatarUrl | null, presence: Presence }
Presence = { status: "offline" | "online" | "in_game" | "away",
             appId | null, appName | null, serverId | null, serverName | null,
             partyId | null, joinable: bool, detail | null, updatedAt: ISO | null }
Request  = { id, userId, displayName, createdAt }
```

- `serverId` is the site's `Server.id`, an integer, as dot-party already has it.
- `partyId` is a **decimal string**, as dot-party's party ids are: they can pass 2^53, and JSON would round one into somebody else's party.
- `Request.id` is the site's `UserFriendship.id`, an integer. It goes back as `requestId` exactly as it came.
- `Request.userId` is the **other** person: the sender of an incoming request, the addressee of an outgoing one.
- `appId` and `appName` come from the **token**, never from the post. A client cannot claim to be in a game it is not.

### Presence rules

- A presence lives `ttlSec` (about 120) after the last post, then reads as offline. The client heartbeats every 45 s, or at 40% of whatever `ttlSec` the site answers with if that is shorter, so two posts can be lost before a player blinks offline.
- **Each post replaces the whole presence.** A field left out is cleared, so leaving a server is a post without `serverId`.
- `detail` is at most 128 characters.
- An offline presence is **blank**: every nullable field null, `joinable` false, `updatedAt` null. That goes for expiry, for posting `offline`, and for a member who hides their activity (who appears offline to everybody, friends included). A hidden player whose presence still carried their server would not be hidden.
- Presence is shown to friends only. `GET presence` **leaves out** anybody who is not a friend rather than answering offline for them, because "offline" would still confirm that the id is somebody.

## Refusal keys

The site's existing friend procedures (`src/server/api/routers/user/social/friend.ts`) throw tRPC codes with English messages, not keys. These are the keys `DotFriendsLocalHub` uses, proposed for the app routes. **If the site ships different ones, this table and the hub change together**, and so does the suite section that checks them.

| Key | When | Site rule it mirrors |
| --- | --- | --- |
| `friends.request.deny.self` | asking yourself | `You cannot add yourself.` |
| `friends.request.deny.notFound` | no such member, or blocked — never distinguished | `Member not found.` |
| `friends.request.deny.closed` | the member has turned requests off | `allowFriendRequests` |
| `friends.request.deny.already` | already friends | `You are already friends.` |
| `friends.request.deny.pending` | you already asked and they have not answered | `A request is already pending.` |
| `friends.request.deny.cooldown` | they declined you less than seven days ago | `FRIEND_REREQUEST_COOLDOWN_MS` |
| `friends.respond.deny.notFound` | not a pending request addressed to you | `Request not found.` |
| `friends.remove.deny.notFriends` | not friends | `You are not friends with this member.` |
| `presence.deny.status` | not one of the four statuses | — |
| `presence.deny.detail` | `detail` over 128 characters | — |
| `presence.deny.batch` | more than 100 ids | — |

And these are the client's own, never sent by the site: `friends.join.deny.notFriend`, `.offline`, `.notJoinable`, `.unsupported`.

## What dot-friends duplicates on purpose

`DotFriendsLocalHub` is the site's friend router, rule for rule: one row per pair whoever asked first; **asking somebody who already asked you accepts them** rather than failing; only the declined sender waits the seven days, and the person who declined may always ask; a re-request after a decline re-uses the row and turns it round to face whoever asked last; only the addressee may answer, and anything else is "not found" rather than "not yours"; removing deletes the row, so both have to ask again.

It is a copy for the reason dot-party's `CanJoinParty` is: a LAN with no website still has to answer these questions, and a game developed against one set of rules must not meet a different set on launch day. **A change to any of these rules on the site needs the same change here.**
