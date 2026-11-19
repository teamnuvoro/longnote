# Onboarding + paywall v2 (19–20 Nov 2026)

Owner's brief (19 Nov night): no login for v1 (paid users first; login later).
US-style onboarding that *sells* the app across several screens before the
paywall, and a longer, information-rich paywall like Summary AI's.

Reference videos studied: Summary AI and Minat (frames in /root/qa-art/login-ref/).
- Summary AI: privacy consent → optional sign-in sheet (Google / Apple / Guest)
  → 3–4 feature screens → long scrolling paywall (features, plans, reviews,
  "take a closer look", FAQ), delayed close X.
- Minat: no login at all; 7 dark feature screens with "See it in action"
  previews → paywall (week / year / month) → review ask → app.

## Onboarding (lib/features/onboarding/)
10 screens, paper-and-ink style, progress bar + back button, no swiping:

1. Welcome: recording pill over a finished note; "Every word of every meeting." (Get started)
2. What will you record? (multi-select, optional)
3. How long do they usually run? (single, optional)
4. Record: "Hours, not minutes." (or "Two hours? Four? Keep going." for long answers), locked-screen recording card with a counting timer and saved parts
5. Summarize: the sample note's summary, matched to answer 1 (meeting / lecture / interview / call / sermon / doctor visit)
6. Transcribe: speaker turns with names and times
7. Ask: a question and its answer with "Heard at 00:41:20"
8. Where your audio goes (same honest facts as before)
9. Your Longnote is ready: a checklist that ticks itself
10. Allow the microphone → paywall

Sample notes are made up (no fake reviews or ratings anywhere). All animations
are finite (tests settle). Answers are saved (kv `onboarding_uses`,
`onboarding_length`) for a later default summary style.

Analytics: `onboarding_step` {step, index} per screen (Amplitude only — the
funnel), `onboarding_completed` now carries `use_*` flags, `first_use`,
`length`. Meta still gets only CompleteRegistration.

## Paywall (lib/features/paywall/)
Top unchanged in substance (honest trial timeline, exact price + date above
the button, Restore / Terms / Privacy), but the plans now come before the
timeline so prices are visible without scrolling. New below the plans
("See everything you get"): Everything in Pro (8 tiles), How it works (3
steps), "No surprise charges" (the reminder), and 6 FAQs.
`paywall_faq_opened` {question} is logged.

Not done on purpose (honest-billing brand): no delayed close X, no weekly
plan, no fake reviews. These are easy experiments later if the owner wants.
