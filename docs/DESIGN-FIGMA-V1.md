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

## Figma node ids (fileKey lGFjCA8QrgEbWcjVk6CP19)
Foundations & components section 2:2 (TabBar set 2:165, RecordPill 2:166, Buttons 2:170/2:172/2:174).
A1 5:167 · A2 5:275 · B1 3:7 · B2 3:141 · B3 3:243 · B4 3:300 · C1 6:191 · C2 6:322 · C3 6:448 · C4 6:579 ·
D1 7:235 · D2 7:332 · D3 7:439 · D4 7:546 · D5 8:288 · D6 8:470 · D7 8:694 · D8 8:923 ·
E1 9:364 · E2 9:465 · E3 9:569 · F1 9:684 · F2 9:781 · F3 9:889 · G1 10:643 · G2 10:803 · G3 10:879 · G4 10:961
Read a frame with the Figma MCP: get_screenshot(fileKey, nodeId) for the picture, get_metadata for structure.
