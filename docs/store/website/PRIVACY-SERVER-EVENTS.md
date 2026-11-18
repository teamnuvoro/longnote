# Privacy policy: server-side subscription events (18 Nov 2026)

Why: from this build, trial / purchase / renewal events reach Meta and
Amplitude from our **server** (Apple's App Store Server Notifications V2 ->
Supabase function `appstore-notifications`), not from the app. The policy must
say so. All sentences below are already applied to `privacy.md` (this file is
the record of the exact text, for the website and for review).

| Section | Change |
|---|---|
| 2 (short version) | Meta bullet: "...such as an install, a trial start, a purchase or a renewal." New bullet: "**Apple tells our server about your subscription** (trial, purchase, renewal, refund). Our server passes trial, purchase and renewal events, with price and currency, to Meta and Amplitude, only while **Share usage analytics** is on." |
| 3 (table) | "Subscription events" row: destinations now "Apple; your phone; Amplitude". New row "Subscription notifications from Apple (trial started, subscription bought, renewed, refunded, expired, auto-renew turned on or off, billing problem; with the plan, price, currency, dates and Apple's transaction number) / To measure revenue and to measure our ads (section 9) / Our backend; Amplitude; Meta (trial started, subscription bought and renewed only)". New row "Ad measurement details: the random ID that Meta's SDK creates for the app, whether you allowed tracking, your **Share usage analytics** choice, and device details (device model, iOS version, app version, language, time zone, screen size) / So our server can send subscription events to Meta and Amplitude, and knows when it must not / Our backend; Meta (with subscription events)". |
| 5 (retention) | "Subscription notifications from Apple: 13 months, then deleted." "Subscription status (plan, trial or paid, expiry date) and ad measurement details: While you use the app. Deleted with your anonymous ID." |
| 6 (Amplitude) | "Our server also sends subscription events it receives from Apple: trial started, subscription bought, trial turned into a paid subscription, renewal, refund, expiry, auto-renew turned on or off, and billing problem (with plan, price and currency). Each event from the app carries basic device data (...). Events from our server carry the app version and no IP address." |
| 7 (Meta) | List item: "a subscription was bought or renewed (with price and currency)." New paragraph: "The app sends the first two. Trial, purchase and renewal events are sent by **our server**, after Apple tells it about your subscription, together with the random ID that Meta's SDK created for the app, whether you allowed tracking, and basic device details (device model, iOS version, app version, language, time zone, screen size). Our server never sends Meta your IP address, your IDFA, your anonymous ID or anything you recorded." Choices: "...and our server stops sending your subscription events to Meta and Amplitude..." |
| 8 (processors) | Supabase: "+ subscription notifications and status, ad measurement details". Apple: "subscription notifications to our server"; "your anonymous ID, which the app gives Apple with a purchase so Apple's notifications to our server say whose subscription it is". |
| 9 (subscriptions) | Rewritten: "When you buy, the app gives Apple your anonymous ID, so that Apple's **App Store Server Notifications** to our server say whose subscription it is. Apple then tells our server when a trial starts, a subscription is bought, renewed, refunded or expires, when auto-renew is turned on or off, and when a payment fails, with the plan, price, currency, dates and Apple's transaction number. Our server checks that each notification is really signed by Apple. While **Share usage analytics** is on, our server sends these events to **Amplitude** to measure revenue, and sends "trial started", "subscription bought" and "renewed" (with price and currency) to **Meta** to measure our ads (section 7). When the switch is off, our server records the subscription status only and sends nothing to Amplitude or Meta. No recording, transcript, summary or note content is ever part of these events." |
| 10 (deletion) | "...push token, subscription status and ad measurement details from our backend;" |

Also check (not edited from here): the App Store privacy label. Purchases >
Purchase History and Identifiers > Device ID (Meta's anonymous app ID) now also
go to Meta from our server, linked to ad measurement; "Data used to track you"
already lists purchases. launch/ files are owned by the launch session.
