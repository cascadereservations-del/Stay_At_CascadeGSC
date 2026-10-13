# Where notices come from (lane B, 2026-10-13)

## Automatic

- Power: `power-watch` reads SOCOTECO II's WordPress feed (socoteco2.com) every 15 minutes, matches feeder 14-3, writes `ops_notices` (type brownout, source socoteco), blocks the touched nights on our booking site and posts one OPS card. It stays the primary power source and is unchanged.
- Weather: `weather-proxy` (hourly, air quality, rain watch). Open-Meteo is free; Google hours only if Open-Meteo returns nothing.

## By hand (a person pastes a link or text to Cassy)

Both pages are Facebook pages we do not manage. Nothing scrapes them and no Graph API reader exists.

| Page | Where | What opens the card in Cassy | What is saved |
|---|---|---|---|
| GSCWD (water) | https://www.facebook.com/gscwaterdistrict/ | a message with a link to facebook.com/gscwaterdistrict, or `water notice: <pasted post text>` | notice_type water, source gscwd |
| SOCOTECO II (power backup) | https://www.facebook.com/socoteco2.EC/ | a message with a link to facebook.com/socoteco2.EC, or `brownout notice: <pasted post text>` | notice_type brownout, source staff |

- Where to send it: the **OPS group chat or the Finance group chat** only. Those are the two chats `telegram-expense` admits (`isAllowedChat`); a private DM to the bot is ignored by this route. Post the line in the group, not in a DM.
- The main path is the prefix form: copy the post text from the page and send `water notice: <text>` or `brownout notice: <text>`. Facebook's mobile "Copy link" gives `facebook.com/share/...`, `m.facebook.com/story.php...` or `fb.watch/...` with no page name, so those cannot say which page it was: a message that is ONLY such a link gets one question back ("Is this a water notice or a brownout notice?") and saves nothing. A link that names the page (`facebook.com/gscwaterdistrict/...`, `facebook.com/socoteco2.EC/...`) works when it is at the very start of the message.
- The route stays out of the way of other flows: it does not fire for a reply to one of the bot's prompts, while the bot is waiting for that person's answer, for text starting with `cassy` or a slash command, or for a photo whose caption is more than the link (a receipt photo still goes to receipt reading).
- Only these hosts count: facebook.com, www./m./web.facebook.com and fb.watch.
- Date and times are read from the pasted text. A bare link has none, so Cassy asks for them: reply with `water notice: October 16, 8:00 AM to 5:00 PM`. A brownout needs a time; a water notice with a date and no time is saved for the whole day and the card says so.
- Nothing is saved until the Save tap. The title is built from the date and times, never copied, so phone numbers, e-mails and amounts in a post cannot reach a notice.
- The app reads both page links from `app_settings.notice_sources` (returned by `notices_v1` as `sources`) to show "Check the GSCWD page" and "Check the SOCOTECO II page".

## What a hand-saved brownout does in power-watch (read from `power-watch/watch.ts`, not run)

- It is an ordinary active brownout row, source `staff`, the same row `/brownout` makes. On its next run (within about 15 minutes) power-watch ADOPTS any active brownout row it has no state for: it blocks the touched nights on our booking site (`calendar_events`, `brownout:<night>` manual rows), posts one OPS card saying what to block on Airbnb by hand, and for a guest already in the house on a touched night it posts the prep note instead of blocking.
- It does not write to Airbnb. It is not auto-released when SOCOTECO's site never lists it, because auto-release applies only to rows power-watch inserted itself; a staff row ends by its date or an Unblock tap.
- Five adoptions per run at most.

### Undoing a mistaken hand-saved brownout (read from `brownout.ts` and `plan.ts`, not run)

- The adoption card power-watch posts carries **Blocked in Airbnb** and **Undo block** buttons, but only when it actually blocked a night (`plan.ts` line 143: no blocked nights, no buttons). It does not carry **Unblock**; Unblock appears only on the cancel card (`plan.ts` line 194).
- **Undo block** (`pw:undo:<date>`, `releaseNotice(..., 'undo')`) frees the nights on our booking site and keeps the notice on the board. **Unblock** (`'unblock'`) frees the nights and deactivates the notice. So for a mistaken staff brownout, Undo block frees the nights but the notice stays active; to remove the notice itself, deactivate it in the admin dashboard (Notices) or ask Cassy. If no night was blocked, there is no button at all and the dashboard is the only way.

## To automate reading a public page

Meta's Graph API reads a page you do not manage only through the **Page Public Content Access** feature, which needs an approved Meta App Review (a Meta developer app, usually with business verification). Lloyd would have to request it; approval is Meta's decision and is not assumed. Until then the manual path above is the supported one. Scraping Facebook is not done.
