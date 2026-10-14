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
