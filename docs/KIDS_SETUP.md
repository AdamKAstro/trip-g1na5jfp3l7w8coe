# Kids itinerary and packing

This is not live until the migration below is applied on the existing Supabase project and the site is deployed. This branch does not merge or deploy.

## What kids can do

The same site (GitHub Pages) grows a kids area. Itinerary is the first tab. Packing is the second.

- Each child opens a link Mum or Dad shares. The link signs them in and stays on that phone. There is no code and no password to type.
- They can add, edit, check, uncheck and delete packing rows, with undo.
- Changes are queued on the phone first. The screen says **Saving…**, **Saved**, **On this phone — not saved to the family list yet**, or **Couldn't save — will keep trying**. **Saved** appears only after the server accepts the queue.
- The queue is in IndexedDB, so a refresh or a closed browser keeps offline edits and retries them. Retries use the same operation id, so a dropped response cannot duplicate a row.
- If two phones edit the same row, the older version does not overwrite the newer one. The phone that lost shows “Kept the newer change from the other phone”.
- Itinerary is read-only for kids. The last successful copy stays on the phone and is labelled **Offline · itinerary last synced …**.
- Seasonal average daytime high and overnight low (°C) sit beside each stop, labelled **Seasonal average · not a forecast**, with the station, period and source in a disclosure. Stops without a reliable normal say **Typical temperature unavailable**.
- Cruise port days are only the published 3–10 January 2027 Star of the Seas sailing that matches the family list (departure, CocoCay on 9 January, return on 10 January). Clock times that sources disagree on are omitted. No extra ports were added.

Parents open **Kids** in the filter bar. They can edit the itinerary and every packing list, and create invite codes. Temperatures are a separate lookup. Editing a day does not rewrite them.

## What this migration changes in the parent database

It does not edit `is_trip_member()`, `items_stamp()`, `suggestions_guard()`, or their triggers. It does not replace `items_select`, `items_update`, or any suggestions policy. Those policies already require `is_trip_member()`, and that function is only the two parent emails, so a child sign-in does not pass them.

It adds one restrictive policy on `items` and one on `suggestions`. A JWT whose `app_metadata.trip_role` is `child` fails those policies even if that email were later added to `is_trip_member()`.

It replaces `block_other_signups()` only. The trigger on `auth.users` stays. Parent emails still pass. Every other email is still rejected unless the claim function has set a transaction-local flag and the new row is one of the four child addresses with `trip_role` `child`. Inserting a child address as a parent is still rejected. Anonymous clients have no insert grant on `auth.users`, so they cannot use that flag themselves.

There are no views or materialized views on the parent tables. The new packing write function is security definer and checks the parent allow-list or the signed child id before it writes. It never reads `items` or `suggestions`. Invite codes are stored as SHA-256 only. Passwords are passed as function arguments and stored with bcrypt. A failed guess is counted, and the guess itself is not stored. Thirty failures in ten minutes pause new attempts. A child cannot create codes, cannot update `auth.users`, and cannot choose another child’s id. The id in the token is written by the claim function from the invite row.

## What kids cannot do

Database policies enforce this. Hiding buttons is not the control.

- They are not trip members. `is_trip_member()` is still only Adam and Erin’s emails.
- A restrictive policy also refuses any JWT whose `app_metadata.trip_role` is `child` on `items` and `suggestions`.
- There is no anon access to itinerary, packing, climate, invites or the parent tables.
- Packing writes go through `apply_packing_op`. Direct insert/update/delete is not granted.
- Itinerary writes require `is_trip_member()`.
- Child identity comes from `app_metadata` set by the invite function, not from a name picker and not from editable user metadata.
- No location, no messaging, no Grok account, no parent password.

Signup stays closed. `block_other_signups` still rejects every email except the two parents, unless the invite function has just set a transaction-local flag and the email is one of the four kid addresses below.

## Apply the database update

In the Supabase SQL editor for project `zfgdqsoibiaclwpothio`, run the whole file:

`supabase/migrations/20261109010000_kids_area.sql`

Then run:

`supabase/verify/kids_policy_checks.sql`

Both should finish without an error. The verify script only reads. It does not create accounts.

Do not put the service role key in the website. The page keeps the existing publishable key.

Realtime: the migration adds `packing_items` and `trip_itinerary` to `supabase_realtime` when that publication exists. Kids clients subscribe with their own JWT, and realtime follows the same select policies.

## Give a child their phone

1. Parent signs in and opens **Kids**.
2. Pick the child and tap **Share link**. The phone’s share sheet opens. If it doesn’t, the link is copied.
3. The child taps that link once. They land on the itinerary and stay signed in.
4. The same link works again on a new phone. **Cancel link / make new link** turns the old one off, signs out phones already using it, and makes another.
5. The screen shows when the current link was made.

The link’s secret is only in the `#k=` part of the address. It is stored on the server as a hash. Applying `supabase/migrations/20261109133000_kids_share_links.sql` is required before Share link works. Then run `supabase/verify/kids_link_checks.sql`.

The child emails are not inboxes:

- liam@kids.usa-trip.invalid
- ana@kids.usa-trip.invalid
- harriet@kids.usa-trip.invalid
- claudia@kids.usa-trip.invalid

Lost password: Mum or Dad generates a new code. Claiming it sets a new password on that same child account. It cannot reset a parent password.

Add the site to the home screen from the child’s account sheet. iPhone: Safari, Share, Add to Home Screen. Android: Chrome menu, Install app.

## Itinerary and weather

The migration seeds a short plan taken from the family list, without booking codes, prices or passport details. Sebastian is only 1 January, the morning on the water. Other east-coast nights were not pinned down, so they are not seeded. Re-running the seed does not overwrite days or packing ticks you have changed. Climate numbers are updated in place and are not copied onto the day title.

If the migration has not been applied, kids see an empty itinerary that says the plan is not on the phone yet. The page does not invent a backup list of bookings.

Weather sources:

- Singapore December and January: NEA Guidebook on Climate of Singapore, Changi, mean daily max/min for 1982–2008. https://www.nea.gov.sg/docs/default-source/resource/guidebook-on-climate-of-singapore.pdf
- New York, Washington Reagan, Miami, Vero Beach, Melbourne (for Cocoa Beach / Port Canaveral), Orlando, Bennington (nearest 1991–2020 normal to Mount Snow): NOAA NCEI U.S. Climate Normals. https://www.ncei.noaa.gov/products/land-based-station/us-climate-normals
- Bennington is an airport station. The slopes are higher and typically colder. The screen says so. It is not a summit figure.
- Costa Maya, Roatan, Cozumel, CocoCay and sea days: unavailable. Nearby cities were not substituted.
- Figures on the card are the normals rounded to the nearest °C. The disclosure shows the station’s own units.

Cruise day list, checked against the family list’s departure, CocoCay date and return morning:

- https://www.cruiseally.com/cruise-lines/royal-caribbean-international/star-of-the-seas/7-night-cruise-port-january-3-2027/321769
- https://www.cruisetimetables.com/cruisesonstaroftheseas-03jan2027.html

## Tests already run here

- `node --test tests/kids-sync.test.js tests/kids-climate.test.js` — queue, reload, duplicate retry, two-session conflict, climate rounding and citations.
- Local Postgres: `supabase/tests/local_prelude.sql`, the migration, then `supabase/tests/kids_rls.sql`, then `supabase/verify/kids_policy_checks.sql`. Checks include child versus parent versus anon, sibling rows, a forged child id, invite minting, bcrypt storage, signup-flag escalation, the 30-guess pause, idempotent ops and conflicts.

The hosted project was not migrated, so this is not a live test of the production API.

## Not done on purpose

- No deploy and no merge.
- No change to parent to-do behaviour aside from the Kids chip, the child signup exception, and the restrictive policies.
- Optional activities that were still undecided (a Keys night, unbought shows) are not listed as the plan.
