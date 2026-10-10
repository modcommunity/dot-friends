# History

What building it found. The lessons that still apply are rules in [CLAUDE.md](../CLAUDE.md) and [design.md](design.md).

## Site rules the specification did not spell out

All found by reading the site's router rather than the specification: a request to somebody who asked you is an accept, the decline cooldown binds only the declined sender, and a re-request re-uses and re-orients the row. A hub without them would have refused crossed requests as `pending` and could have put the wrong person on cooldown. Request ids are integers on the site; the specification's `{id}` did not say which, and a string id sent back to a zod `number()` would be refused. The suite checks `requestId` goes out as an integer.

## Keys before there were keys

The site's friend procedures threw English messages, not keys, so the hub's refusal keys started as a proposal with nothing to check them against. The app routes later shipped keys in `locales/en/friends.json`, and the hub's match them. When the site and this addon are built at the same time, compare the keys first once both exist.

## The suite's expiry check failed first, correctly

"A friend whose presence expired goes offline" advanced 100 s past a heartbeat made at +30, so the friend still had 20 s left. The addon was right; the test's arithmetic was not. It now advances past the lifetime from the last post, with a comment saying which post.

## A wrapped 404 put text where a key belongs

Read in dot-party's app backend, not found by running: its 404 hint wrapped the result, so `error.detail` became `"[invalid] Not found."`, and a caller treating `detail` as an i18n key looked that up. dot-friends clears `detail` and the suite checks a bare 404 "invents no key"; dot-party has since stopped wrapping too.

## A missing route logged a warning nobody could act on

A bare 404 was routed into the outage branch, so every sign-in against a site without the routes logged "the friends service is failing" at WARN, and the shell then logged its own "off for this session" after it: two lines for one fact. Now one INFO line on its own flag; the suite counts the lines at INFO and above across three calls.

## Every guard was armed

Removing the debounce aborted a section part-way (an index past the end of the post list), which only the checks total reported. Skipping `join`'s fresh presence, diffing on `updatedAt`, and not collapsing a burst that returns to where it started each failed checks. A guard nobody has seen fail is not known to guard anything.
