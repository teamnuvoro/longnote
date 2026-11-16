# Handoff, 16 Nov 2026 (evening): Longnote v1 built, build 105 on TestFlight

- Branch `v1-build` (pushed; not merged to master). Build 105 = commit 80b6bea + docs, TestFlight processing VALID.
- Supabase project renamed "Longnote", Serial Stories data archived to the Storage Box (`archive/serial-stories-supabase-20261116.tar.zst.gpg`) then wiped.
- Backend: docs/BACKEND-API.md (Soniox stt-async-v6 + OpenAI gpt-5.4-mini; anonymous auth; limits; deletion). 60-min test: 61 s transcription, $0.12.
- App: docs/APP-ARCHITECTURE.md; 28 Figma screens; 192+ tests; flow tests in test/flows/; goldens in test/goldens (Linux only).
- Independent review (Fable) found 0 critical, 2 high, 4 medium: all fixed and redeployed.
- Device tests for the owner: docs/DEVICE-TEST-V1.md.
- Open: real StoreKit billing; App Attest; privacy/terms URLs + App Store id (lib/features/common/links.dart); share-into-app needs Xcode setup; Hinglish returns Devanagari; merge v1-build to master after device test.
- Keys: .env.local (git-ignored). Server secrets in Supabase only.
