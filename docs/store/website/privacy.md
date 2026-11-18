# Longnote Privacy Policy

**Last updated: 19 November 2026**

Longnote is an iPhone app that records long conversations and turns them into transcripts and summaries. This policy explains what data the app uses, where it goes, and how long it is kept. If anything is unclear, email us at support@novaralabs.in.

## 1. Who we are

Longnote is made by **Novara Labs LLP**, a limited liability partnership registered in India ("we", "us").

- Contact for privacy questions, requests and complaints: **support@novaralabs.in**
- We are the "data controller" (GDPR) and the "Data Fiduciary" (India's DPDP Act) for the data described here, except where this policy says Meta acts as a controller (section 7).
- The same email is our grievance contact under Indian law.

## 2. The short version

- **No account.** We never ask for your name, email or phone number.
- **Your notes live on your phone.** Recordings, transcripts and summaries are stored on your iPhone.
- **Audio leaves your phone only to be transcribed.** We delete it from our servers and from our speech-to-text provider once the transcript is made.
- **Transcript text is sent to OpenAI** to write summaries and answer your questions. OpenAI does not train on it, but may keep it for up to 30 days for abuse checks.
- **We use Amplitude for app analytics.** It never receives your audio, transcripts, summaries or note titles.
- **We use Meta (Facebook) to measure our ads.** Meta receives a few events, such as an install, a trial start or a purchase. It never receives your recordings or notes. If you allow tracking when iOS asks, Meta also receives your device's advertising ID.
- **No ads inside the app. We do not sell your data.**
- One switch in Settings, **Share usage analytics**, turns off both Amplitude and Meta.

## 3. What we collect, and what we do not

### We collect

| Data | Why | Where it is kept |
|---|---|---|
| A random anonymous ID, made when you first open the app | To link your processing jobs and usage to your phone without an account | Our backend (Supabase) |
| Audio of a recording, compressed | Only to make the transcript | Our backend, then Soniox. Deleted after the transcript is made (section 5) |
| Transcript text, including any speaker names you add | To show it to you, and to make summaries and answer "Ask" questions | Your phone. Briefly on our backend until your phone collects it. Sent to OpenAI for summaries and Ask |
| Job status records (for example "uploading", "done", "failed", the language you chose, error codes, number of retries) | To run and retry processing | Our backend |
| Usage counts (minutes of audio processed, number of Ask questions) | Cost control and protection against abuse | Our backend |
| A scrambled (hashed) form of your IP address, with daily counts | Protection against abuse | Our backend, for 2 days |
| Crash and error reports (error type, short message, technical stack trace, recent screen names, device and app version) | To find and fix bugs | Our backend |
| A push notification token (if you allow notifications) | To tell you "your note is ready" | Our backend, and Apple |
| App usage events (section 6) | To understand what works and fix problems | Amplitude |
| Ad measurement events (section 7) | To measure which of our ads bring people to Longnote | Meta |
| Your device advertising ID (IDFA), **only if you allow tracking** | Ad measurement and improving our ads (section 7) | Meta |
| Basic technical data: IP address, device model, iOS version, app version, language, time of request | Needed to deliver any internet request; security and debugging | Short-lived server logs at our providers; Amplitude (IP address not stored); Meta |
| Subscription events (trial started, subscription bought, purchase restored, with price and currency) | To unlock paid features, to measure revenue, and to measure our ads | Apple; your phone; Amplitude; Meta (trial started and subscription bought only) |

### We do not collect

- Your name, email address, phone number or contacts.
- Your payment card details. Apple handles all payments. We never see them.
- Your precise location.
- Your audio, transcript text, summary text, note titles or questions in our analytics or ad measurement. These never go to Amplitude or Meta.

We do not sell your personal data. We do not show ads in the app.

## 4. How your data flows

1. **Recording.** Recording starts only when you tap **Start** on the recording screen. The app saves audio on your phone while it records, so a crash or a phone call does not lose it.
2. **Upload.** When you ask for a transcript, the app compresses the audio and uploads it over an encrypted connection (HTTPS) to a private storage bucket on our backend, hosted by **Supabase** on Amazon Web Services in the United States (us-east-1).
3. **Speech-to-text.** Our backend gives **Soniox** a short-lived private link to the audio. Soniox turns the speech into text and labels the speakers.
4. **Clean-up.** When the transcript is ready, our backend deletes the audio from our storage and asks Soniox to delete both the audio and the transcript on its side.
5. **Back to your phone.** Your phone downloads the transcript. Our backend then deletes its copy of the transcript.
6. **Summaries and Ask.** The app sends the transcript text (not the audio) through our backend to **OpenAI**, which writes the summary or answers your question. The result comes back to your phone. We do not keep the summary or your question on our servers, apart from a short cache of up to 30 minutes so a repeated request does not run twice.

**On-device mode.** In **Settings > Transcription** you can choose to transcribe on the phone instead. In that mode the audio never leaves your phone for transcription, and summaries are made on your phone (with Apple Intelligence where your iPhone supports it, otherwise a basic offline summary). If you use Ask, the transcript text is still sent to OpenAI.

**iCloud backup.** Your notes are part of your iPhone's own iCloud backup if you have it turned on. That is Apple's storage under your Apple ID, not ours.

**Sharing.** If you share or export a note (PDF, text or audio), it goes wherever you send it. That is up to you and the app you share to.

## 5. How long we keep data

| Data | How long |
|---|---|
| Recordings, transcripts, summaries on your phone | Until you delete them in the app, or delete the app |
| Audio on our backend | Deleted as soon as the transcript is made or the job fails. Anything left over is deleted by our automatic clean-up within 24 hours |
| Audio and transcript at Soniox | We ask Soniox to delete them as soon as the transcript is made. If that request ever fails, Soniox deletes them automatically after 30 days |
| Transcript copy on our backend | Deleted as soon as your phone confirms it has it. Otherwise deleted 24 hours after your phone first downloads it, or 7 days after the job if it is never collected |
| Transcript text, questions and answers at OpenAI | Not used to train OpenAI's models. OpenAI may keep them for **up to 30 days** to detect abuse, and then deletes them, unless the law requires longer |
| Job status records | 30 days |
| Usage counts | 90 days |
| Hashed IP address and daily counts | 2 days |
| Crash and error reports | 30 days |
| Anonymous ID and push token | While you use the app. Removed when you ask us to delete your data (section 10). If the app is not used for 90 days, the anonymous ID and its records are deleted |
| Server logs at our providers (IP address, time, request path) | A short time, usually days, for security and debugging |
| Amplitude analytics events | Up to 12 months, then deleted |
| Meta ad measurement events and advertising ID | As set out in [Meta's Privacy Policy](https://www.facebook.com/privacy/policy) |

## 6. Analytics (Amplitude)

We use **Amplitude** to understand how the app is used, so we can fix problems and improve it.

**What we send:** app events such as app opened, onboarding completed, recording started, recording finished (length), recording interrupted or recovered after a crash, processing failed or retried, transcript or summary viewed, note exported, paywall viewed, your answer to the tracking prompt, restore purchase tapped, trial started, and subscription bought (with price and currency). Each event carries basic device data (device model, iOS version, app version, language, country).

**What we never send:** audio, transcript text, summary text, your questions to Ask, note titles, speaker names, or anything that names you.

**How it is linked:** events are tied to your anonymous ID and a random Amplitude device ID. They are not tied to your name or email (we do not have them). We do not give Amplitude your advertising ID (IDFA). We set the app so Amplitude does not store your IP address.

**Where:** Amplitude stores this data in its data centres in the United States. We keep it for up to 12 months.

**Your choice:** you can turn analytics off at any time in **Settings > Share usage analytics**. After that, the app stops logging new events for Amplitude; anything already waiting to upload may still be sent within about a minute.

## 7. Ad measurement (Meta)

We advertise Longnote on Facebook and Instagram. We use the **Meta App Events SDK** (Meta Platforms, Inc. and Meta Platforms Ireland Limited, "Meta") to measure which ads bring people to the app, and to improve our ads.

**What we send to Meta:** only these events:

- the app was installed or opened;
- onboarding was completed;
- a free trial was started (with currency);
- a subscription was bought (with price and currency).

Meta's SDK also sends basic technical data with each event, such as device model, iOS version, app version, language, time zone and the IP address of the connection, and a random ID that the SDK creates for the app.

**What we never send to Meta:** recordings, audio, transcripts, summaries, note titles, note content, your questions, speaker names, your anonymous ID, or your name or email. We have turned off Meta's automatic event logging, so Meta receives only the events listed above.

**The tracking prompt.** After the welcome screens, the app shows Apple's App Tracking Transparency prompt once.

- **If you allow tracking**, Meta may also receive your device's advertising identifier (IDFA). Meta can then link these events with information it has from other apps and websites, for example if you use Facebook or Instagram, to measure and improve our ads. Under Apple's rules this is "tracking".
- **If you ask the app not to track**, we do not collect or share your IDFA. Meta still receives the events above without the IDFA. Our ad results are then measured through Apple's SKAdNetwork and Meta's aggregated measurement, which report results in combined form.

You can change your answer at any time in **iPhone Settings > Privacy & Security > Tracking**.

**Who controls this data.** We decide which events are sent. Meta uses the data it receives to provide measurement to us, and also for its own purposes, such as improving its ad systems and security. For those uses Meta acts as an independent controller under its own terms. Meta's use of the data, and how long it keeps it, are described in [Meta's Privacy Policy](https://www.facebook.com/privacy/policy).

**Your choices:**

- Turn off **Settings > Share usage analytics** in Longnote. After that, the app stops logging new events for Meta (and Amplitude); anything already waiting to upload may still be sent within about a minute.
- Ask the app not to track, or turn off tracking in iPhone Settings, to stop the IDFA being shared.
- Because we do not give Meta any ID that links these events to you, a deletion request to us cannot delete data Meta already holds. To ask Meta about its data, use the tools in Meta's Privacy Policy.

## 8. Who processes your data

We use these companies to run Longnote.

| Company | What it does for us | Data it receives | Where | Uses your data to train AI? |
|---|---|---|---|---|
| **Supabase, Inc.** (USA) | Backend hosting: anonymous sign-in, database, temporary audio storage, server functions | Anonymous ID, audio (temporary), transcript (temporary), job records, usage counts, hashed IP, crash reports, push token, technical logs | USA (AWS us-east-1) | No. Supabase processes our data only on our instructions |
| **Soniox, Inc.** (USA) | Speech-to-text with speaker labels | Audio, and the transcript it creates (temporary) | USA | No. Soniox states it does not use customer content to train or improve its models |
| **OpenAI, L.L.C.** (USA) | Summaries and answers to Ask questions | Transcript text, your question, the summary style and language you chose | USA | No. OpenAI states data sent to its API is not used to train its models. Kept up to 30 days for abuse checks |
| **Amplitude, Inc.** (USA) | Product analytics | App events and basic device data (section 6). No content | USA | Used only to provide analytics to us |
| **Meta Platforms, Inc.** (USA) and **Meta Platforms Ireland Limited** | Ad measurement | Ad measurement events, basic technical data, and the IDFA if you allow tracking (section 7). No content | USA and other countries | Meta acts as an independent controller for its own uses; see [Meta's Privacy Policy](https://www.facebook.com/privacy/policy) |
| **Apple Inc.** (USA) | App Store payments and subscriptions; push notifications; SKAdNetwork ad measurement | Your purchase (Apple handles it under its own privacy policy); push token and the "note ready" message | Worldwide | Apple's own policy applies |

Supabase, Soniox, OpenAI and Amplitude act as our processors: they may only use your data to provide their service to us.

## 9. Subscriptions and payments

Subscriptions are sold and billed by Apple through the App Store. Apple handles your payment details under its own privacy policy. We receive only the subscription status (for example: trial, active, expired) so the app knows what to unlock. We record trial and subscription events, with price and currency, in Amplitude to measure revenue. We also send "trial started" and "subscription bought" events to Meta to measure our ads (section 7).

## 10. Your choices and rights

You can:

- **Delete a note.** Delete it in the app. It is removed from your phone. (Our servers do not keep notes.)
- **Delete your account.** If you have signed in with an account, go to **Settings > Account > Delete account**. This deletes your account and everything our backend holds for it, asks Amplitude to delete your analytics events, and signs you out. We confirm by email if you gave us one.
- **Delete all your data without an account.** Email support@novaralabs.in with the Support ID shown in **Settings > Privacy**. We will:
  - delete your anonymous ID, job records, usage counts and push token from our backend;
  - ask Amplitude to delete all analytics events linked to your IDs (Amplitude completes this within about 30 days);
  - confirm by email within 30 days.
  Notes, transcripts, summaries and audio on your phone are removed when you delete them in the app or delete the app.
- Data already sent to OpenAI for abuse checks is deleted by OpenAI within 30 days. Data at Soniox is already deleted, or is deleted within 30 days. Data at Meta is handled under Meta's policy (section 7).
- **Delete the app.** This removes everything stored on your phone. It does not remove server records, so email us first (with your Support ID) if you want those removed now. Records of an unused install are deleted after 90 days anyway.
- **Turn off analytics and ad measurement** in **Settings > Share usage analytics** (sections 6 and 7).
- **Stop tracking** in **iPhone Settings > Privacy & Security > Tracking** (section 7).
- **Turn off notifications** in iPhone Settings.
- **Email us** at support@novaralabs.in to access, correct or delete your data, to object to processing, or to ask a question. Because we have no account, please include the support ID shown in **Settings > Privacy**, so we can find your records. We reply within 30 days.

**If you are in the EU, UK or EEA (GDPR):** you have the right to access, correct, delete, restrict, object to, and port your data, and to withdraw consent. Our legal bases are:

- to provide the service you asked for (contract), for transcription, summaries and Ask;
- our legitimate interest in running a secure, reliable app, improving it, and measuring our ads, for analytics, ad measurement events without the IDFA, crash reports and logs (you can turn analytics and ad measurement off at any time);
- your consent, for sharing your IDFA with Meta when you allow tracking (you can withdraw it in iPhone Settings);
- legal obligations.

For the collection and sending of events to Meta, we and Meta may be joint controllers. Meta is responsible for its own processing after it receives the data. You can complain to your local data protection authority.

**If you are in California (CCPA/CPRA):** you have the right to know, delete and correct your personal information, to opt out of its "sale" or "sharing", and to not be discriminated against for using these rights. We do not sell personal information. When you allow tracking, sending your IDFA and ad measurement events to Meta may count as "sharing" for cross-context behavioural advertising under California law. You can opt out at any time by turning off tracking in iPhone Settings, or by turning off **Settings > Share usage analytics** in the app. We do not use sensitive personal information to infer things about you.

**If you are in India (DPDP Act 2023):** we process your data to provide the service you asked for, and you can withdraw your consent at any time (for example by turning off **Share usage analytics**, turning off tracking, asking us to delete your data, or deleting the app). You have the right to access a summary of your data, to correct and erase it, to nominate another person to use your rights if you die or cannot act, and to raise a grievance with us at support@novaralabs.in. If you are not satisfied with our reply, you may complain to the Data Protection Board of India.

## 11. Recording other people

Longnote records whatever your microphone hears, including other people. In many places the law requires that everyone being recorded knows about it or agrees to it. **You are responsible for getting consent where the law requires it.** Do not use Longnote to record people secretly.

## 12. Children

Longnote is not directed at children under 13, and we do not knowingly collect data from them. In India, users under 18 should use the app only with a parent's or guardian's consent. If you believe a child has used the app, email us and we will delete the related data.

## 13. International transfers

We are based in India. Our service providers are in the United States, and Meta processes data in the United States and other countries, so your data is processed outside your country. We rely on our providers' data protection terms, including the EU Standard Contractual Clauses where they apply, to protect data sent from the EU, UK and EEA.

## 14. Security

- All data in transit uses encryption (HTTPS/TLS).
- Audio is stored in a private bucket. Only our server functions can read it, and Soniox gets a short-lived link.
- Our secret API keys are kept on our servers, never in the app.
- On the server, each anonymous ID can only see its own records.
- IP addresses used for abuse limits are stored only in scrambled (hashed) form.
- On your phone, your notes are protected by iOS file protection and your passcode.

No system is perfectly secure. If a breach affects your data, we will tell you and the authorities as the law requires.

## 15. Changes to this policy

We will update this page when our practices change and show the new date at the top. If a change is significant (for example, a new provider that receives your content), we will tell you in the app before it takes effect.

## 16. Contact

Novara Labs LLP
Registered address: C/o Sanjay Ram Mandir, Main Road, Hinganghat, Wardha, Maharashtra 442301, India
Email: **support@novaralabs.in**
