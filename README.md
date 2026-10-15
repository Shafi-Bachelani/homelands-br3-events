# Creating Our Homelands: BR3 events

Community and events app for the Al Ansaar Association in Beckenham (BR3).

It's a plain HTML/CSS/JavaScript web app with no build step, and Netlify publishes this folder as it is.

- `data.js`: the app's content (community info, events, groups, services)
- `app.js`: every screen
- `styles.css`: the look
- `sw.js`: offline support. Bump `CACHE` whenever files change.
- `config.js`: the Supabase project URL and publishable key. Both are public by design.
- `supabase/schema.sql`: the database tables, security rules and booking functions. Paste it into the Supabase SQL Editor and run it once.
- `vendor/`: copies of supabase-js and qrcodejs, so the app doesn't depend on a CDN.

The first person to sign up becomes the admin.

## Card payments (Square)

`netlify/functions/pay.mjs` creates a Square checkout for a booking and confirms it when the person comes back. `square-webhook.mjs` marks payments made by people who closed the page early. Run `supabase/add-square.sql` once. Set these in Netlify under Project configuration, then Environment variables, never in the code:

- `SQUARE_ACCESS_TOKEN`: from the Square developer app (use the Sandbox token while testing)
- `SQUARE_ENVIRONMENT`: `sandbox` while testing, `production` for real payments
- `SUPABASE_SECRET_KEY`: Supabase, then Project Settings, API Keys, then the secret key
- `SQUARE_WEBHOOK_SIGNATURE_KEY` (optional): from the Square webhook subscription for `payment.updated`

## Copyright

Copyright (c) 2026 Al Ansaar Association. All rights reserved. See [LICENSE](LICENSE). The code is public only so the site can be updated; it is not open source.
