# Longnote v1: Figma screens (16 Nov 2026)

Figma file: https://www.figma.com/design/lGFjCA8QrgEbWcjVk6CP19 (team Novara Labs LLP), page "Longnote v1".
Scope: every in-app screen after login, starting at the paywall. Onboarding/login are later.
Feature set = Minat v1.16.20 (owner's screenshots in business-discovery/utility-apps/reference-apps/ui-shots/minat-app/), own design.

## Look ("paper and ink")
- Light warm paper background (#F5F3EE), white cards, ink text (#15171C). Minat is dark + iOS blue; we are light + monochrome.
- One signal colour (#E4472B) used only for recording. Green = saved/done, amber = waiting/retry.
- Fonts: Newsreader (titles, summaries), Geist (UI), Geist Mono (times, durations). The real app uses these via google_fonts or bundled files.
- Recording screen is dark ("focus mode").
- Record = floating ink pill on the Notes tab, not a red circle in the tab bar. Tabs: Notes, Ask, Import, Settings.

## Screens (28)
| Section | Frames |
|---|---|
| 00 Foundations | palette, type, StatusBar, HomeIndicator, TabBar (4 variants), RecordPill, Button Primary/Secondary/Destructive |
| A Paywall | A1 paywall (yearly selected, trial timeline, exact charge date), A2 trial started + reminder permission |
| B Notes | B1 home (waiting/needs-attention list = retry list, processing row), B2 empty, B3 search (titles/summaries/transcripts), B4 note actions sheet |
| C Recording | C1 live, C2 paused, C3 phone-call interruption, C4 discard confirm |
| D Note | D1 processing steps, D2 summary, D3 transcript with speakers, D4 edit speaker names (+ merge), D5 share & export, D6 summary style (9 templates + own instructions), D7 full player, D8 transcription failed |
| E Ask | E1 start (note picker + starters), E2 answer with source chips, E3 choose a note |
| F Import | F1 import, F2 before we start (name, language, style), F3 copying progress |
| G Settings | G1 settings, G2 audio language (60+, auto-detect), G3 transcription & privacy (cloud vs on-phone, where audio goes), G4 plan & billing (dates, how to cancel) |

Each frame has a short note under it saying what it does and why.

## Deliberately not copied from Minat
Weekly plan, "80% off", "99% accurate / GPT-6 / 100,000 users" claims, dark+blue look, red record circle in the tab bar, emoji template list, minutes-used counter.

## Open for the owner
- Copy and prices are placeholders where dates are shown (trial dates assume a start on Sun, Nov 16).
- Template list (9) is my pick for our audiences (meetings, students, sermons); change freely.
- Not drawn yet: onboarding/login, widget/Control Center (later), dark mode for non-recording screens.
