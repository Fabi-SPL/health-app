# Health

**One person's body-state engine.** iOS app + server-side correlation engine + DIY Whoop BLE bridge. Streams heart rate, HRV, recovery, and sleep data from a jailbroken Whoop 4.0 strap (no subscription) into Supabase, then runs pattern detection (t-tests, ANOVA, effect-size correlation) to surface real signal in noisy daily data.

> This is **a personal engine**, not a polished product. Pattern thresholds, the system prompt's voice, the recovery formula — all tuned to one body over months. Fork it to learn, gut it to adapt, run it on your own Supabase + Apple ID. No support, no roadmap, no DM me.

---

## What's inside

```
ios/                         SwiftUI iOS 26+ app — thin client
api/hermes/                  Vercel serverless TS endpoints
  ├── daily.ts               Nightly correlation engine (pg_cron triggered)
  ├── now.ts                 On-demand "what's my body doing right now"
  ├── chat.ts                Conversational interpreter (Gemini 2.5 Flash)
  ├── patterns.ts            Pattern CRUD
  └── _auth.ts               Shared auth (secret / cron / user JWT)
supabase/migrations/         Schema + server-side health algorithms (Postgres)
scripts/                     Python Whoop BLE bridge (bleak)
.github/workflows/build.yml  iOS build + AltStore source update + IPA upload
public/altstore-source.json  AltStore subscription source (template)
```

## How it actually works

```
┌─────────────────────────────────────────────────────────────┐
│  Whoop 4.0 (jailbroken, BLE peripheral)                     │
└──────────────────────┬──────────────────────────────────────┘
                       │ BLE GATT notifications (HR, RR, type47 packets)
                       ▼
┌─────────────────────────────────────────────────────────────┐
│  iOS app — BLEManager.swift                                 │
│  Listens for HR/RR notifications, computes HRV (RMSSD,      │
│  SDNN, pNN50, Poincaré), upserts to realtime_health table   │
│  every 10s. NO algorithm code on device.                    │
└──────────────────────┬──────────────────────────────────────┘
                       │ Supabase REST (anon key, JWT auth)
                       ▼
┌─────────────────────────────────────────────────────────────┐
│  Supabase (Postgres + pg_cron + Vercel edge functions)      │
│  ┌──────────────────────────────────────────────────────┐   │
│  │ pg_recompute(uuid, date)  — server-side scoring      │   │
│  │   recovery_score, strain_score, sleep_score,         │   │
│  │   readiness_score, cognitive_capacity, illness_risk  │   │
│  └──────────────────────────────────────────────────────┘   │
│  ┌──────────────────────────────────────────────────────┐   │
│  │ Hermes correlation engine (api/hermes/daily.ts)      │   │
│  │   Runs nightly. Pearson r, t-test (Welch's d),       │   │
│  │   ANOVA (η²), seasonal stratification.               │   │
│  │   Writes to hermes_pattern_matches.                  │   │
│  └──────────────────────────────────────────────────────┘   │
└──────────────────────┬──────────────────────────────────────┘
                       │ iOS reads computed values + pattern matches
                       ▼
┌─────────────────────────────────────────────────────────────┐
│  HermesCard on TodayView — what your body's doing right now │
└─────────────────────────────────────────────────────────────┘
```

## Setup (if you actually want to run this)

### 1. Your own Supabase

Self-host (Coolify/Hetzner) or Supabase Cloud — either works.

```bash
# 1. Run migrations in order (find/replace YOUR_USER_ID_HERE and YOUR_SUPABASE_URL_HERE first)
psql $DATABASE_URL -f supabase/migrations/supabase-migration-v29.sql
psql $DATABASE_URL -f supabase/migrations/supabase-migration-v37.sql
# ... etc up to v101

# 2. Create your user via Supabase Auth (email + password)
# 3. Note your auth.users.id — that's HERMES_USER_ID below
```

### 2. Deploy Hermes API to Vercel

```bash
vercel deploy api/hermes/
```

Vercel env vars required:
- `HERMES_USER_ID` — your auth.users.id
- `HERMES_TRIGGER_SECRET` — random string, used for manual /now and /daily triggers
- `VITE_SUPABASE_URL` — `https://your-project.supabase.co`
- `VITE_SUPABASE_ANON_KEY` — Supabase anon key
- `SUPABASE_SERVICE_ROLE_KEY` — Supabase service role key (server-only)
- `GOOGLE_AI_API_KEY` — Gemini API key (free tier at https://aistudio.google.com)

Vercel cron auto-runs `/api/hermes/daily` once per day at 06:00 UTC.

### 3. Build iOS app via GitHub Actions

Fork this repo, then set:

**Repo secrets** (Settings → Secrets → Actions):
- `EE_TASKS_EMAIL` — Supabase auth email
- `EE_TASKS_PASSWORD` — Supabase auth password
- `SUPABASE_ANON_KEY` — anon key (gets baked into the iOS binary)
- `SUPABASE_SERVICE_KEY` — service key (used by workflow to upload IPA to your storage)
- `HERMES_USER_ID` — your auth.users.id
- `GOOGLE_AI_API_KEY` — for on-device Gemini calls

**Repo variables** (Settings → Variables → Actions):
- `SUPABASE_URL` — `https://your-project.supabase.co`
- `SUPABASE_STORAGE_PUBLIC_BASE` — `https://your-project.supabase.co/storage/v1/object/public/ipa-builds`
- `SUPABASE_STORAGE_WRITE_BASE` — `https://your-project.supabase.co/storage/v1/object/ipa-builds`

Push to `main` → GHA builds an unsigned IPA on `macos-15` runner (FREE for public repos) → uploads to your Supabase storage bucket → updates `altstore-source.json`.

### 4. Sideload via AltStore PAL

Add `https://your-project.supabase.co/storage/v1/object/public/ipa-builds/altstore-source.json` as a source in AltStore PAL. Install Health. Done.

### 5. (Optional) The DIY Whoop bridge

The Python scripts in `scripts/` are diagnostic — they were used to reverse-engineer the Whoop BLE protocol. The real bridge runs *inside the iOS app* now (see `BLEManager.swift`). Useful if you want to scan/connect from a Linux/macOS box for testing:

```bash
pip install bleak
python scripts/whoop-scan-test.py    # find your strap
python scripts/whoop-connect-test.py # subscribe to HR notifications
```

## The voice

Hermes (the body-state interpreter) is intentionally **not a wellness app**. The system prompt and UI copy are tuned away from generic positivity ("you're crushing it!") toward observation-first, hypothesis-driven language. If you fork it, you'll want to rewrite the prompt for your own voice — search `HERMES_SYSTEM_PROMPT` in `api/hermes/now.ts` and `api/hermes/chat.ts`.

## What's intentionally missing

- **No commercial features** — no auth flows for multiple users, no Stripe, no marketplace, no onboarding
- **No App Store distribution** — sideload only (AltStore PAL on EU iOS, or AltStore Classic globally)
- **No support, no roadmap** — fork it, own it
- **No tests** — the test harness is "my body, every day"
- **Personal thresholds baked in** — recovery formula, pattern thresholds, voice samples reflect one person's data. Fork = expect to retune

## Stack

- **iOS:** Swift 6 / SwiftUI / iOS 26+ minimum (Live Activities, frequent updates, WidgetKit)
- **Server:** Vercel serverless TypeScript + Supabase Postgres + pgvector + pg_cron + Gemini 2.5 Flash
- **BLE:** CoreBluetooth (iOS) + bleak (Python, for diagnostics)
- **Sideload:** AltStore PAL / AltStore Classic (no Apple Developer Program enrollment required)

## License

MIT — see [LICENSE](./LICENSE). No warranty, no medical advice, not a medical device. If your body is doing something weird, see a doctor.
