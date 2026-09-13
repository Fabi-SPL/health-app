import type { VercelRequest, VercelResponse } from '@vercel/node'
import { createClient } from '@supabase/supabase-js'
import { hermesAuthOk, authClient } from './_auth.js'

// ── Hermes V0.5 — on-demand body-state interpreter ──────────────────────
// Pulls last 60min of realtime_health, computes percentile rankings vs.
// the last 30 days at the same hour-of-day, gathers recent context
// (brain_dumps, emotional_snapshots, latest sleep, latest workout),
// then asks Gemini 2.5 Flash for a plain-English interpretation.
//
// Trigger: GET /api/hermes/now
// Auth:    Authorization: Bearer $HERMES_TRIGGER_SECRET
//
// Persists to hermes_now_snapshots (one row per call).

const SUPABASE_URL = process.env.VITE_SUPABASE_URL || process.env.SUPABASE_URL || ''
const SUPABASE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY || process.env.VITE_SUPABASE_ANON_KEY || ''
const GEMINI_KEY = process.env.GOOGLE_AI_API_KEY || process.env.VITE_GOOGLE_AI_API_KEY || ''
const USER_ID = process.env.HERMES_USER_ID || ''

const supabase = createClient(SUPABASE_URL, SUPABASE_KEY, {
  auth: { persistSession: false },
})

// ── Hermes system prompt (>1K tokens — enables Gemini implicit caching) ─
const HERMES_SYSTEM_PROMPT = `You are Hermes, Fabi's body-state interpreter inside the Health app.

Your job: given current body signals (HRV, RR, cognitive_capacity, movement, sleep, etc.) plus percentile rankings (where each value sits in Fabi's typical distribution for this hour-of-day) plus recent context (brain dumps, emotional snapshots, last workout), write a 150-300 word plain-English interpretation of what Fabi's body is doing RIGHT NOW.

Style rules:
- Direct and warm. No medical hedging. No "you might want to consider."
- Lead with the dominant signal. Example: "HRV is in the bottom 20% for this hour — sympathetic load is up."
- Connect 2-3 signals into a story when it makes sense. Example: "Low HRV + elevated RR + skipped lunch in your brain dump = stress + low fuel."
- Reference recent context only if it explains the signal — don't list it just to list it.
- End with ONE practical suggestion (water, breathing, food, walk, brief rest). Not a checklist.
- Plain language. No jargon unless explained inline.
- 150-300 words. Less is fine. Wall-of-text is not.

Avoid:
- Medical disclaimers ("consult a doctor")
- Lists of >3 items (Fabi has ADHD; lists fragment attention)
- Vague "could be" / "might be" when data is clear
- Mentioning you're an AI or LLM
- Generic wellness platitudes ("listen to your body")

Fabi context: 30yo male, sport-bike rider, ADHD, runs his own business. Lives mostly indoors at his Windows PC. Tracks HRV via custom WHOOP setup (LucidBridge) at 1Hz. Strong relationship with his data — wants the truth, not pep talks.

If signals are mixed or weak, say so plainly: "Body signals are middle-of-range across the board. Nothing strong to flag."

If percentiles are extreme (>90 or <10), call it out — those are real outliers worth attention.`

// ── Stats helpers ───────────────────────────────────────────────────────
function avg(xs: number[]): number | null {
  const v = xs.filter(x => Number.isFinite(x))
  if (!v.length) return null
  return v.reduce((a, b) => a + b, 0) / v.length
}
function minOf(xs: number[]): number | null {
  const v = xs.filter(x => Number.isFinite(x))
  return v.length ? Math.min(...v) : null
}
function maxOf(xs: number[]): number | null {
  const v = xs.filter(x => Number.isFinite(x))
  return v.length ? Math.max(...v) : null
}
// Rank-based percentile: fraction of distribution values below `x` (0-100, rounded).
function percentileRank(distribution: number[], x: number | null): number | null {
  if (x == null || !Number.isFinite(x)) return null
  const v = distribution.filter(d => Number.isFinite(d))
  if (v.length < 5) return null // need a meaningful baseline
  let below = 0
  let equal = 0
  for (const d of v) {
    if (d < x) below++
    else if (d === x) equal++
  }
  return Math.round(((below + equal / 2) / v.length) * 100)
}

// Auth uses the shared hermesAuthOk helper (accepts HERMES_TRIGGER_SECRET,
// Vercel CRON_SECRET, or a valid user session JWT belonging to Fabi).
const authVerifier = authClient()

// ── Types ───────────────────────────────────────────────────────────────
interface RtRow {
  hrv_rmssd: number | null
  respiratory_rate: number | null
  cognitive_capacity: number | null
  sdnn: number | null
  pnn50: number | null
  dfa_alpha1: number | null
  movement_score: number | null
  hmm_state: string | null
  recorded_at: string
}

interface RawSignal {
  hrv_avg: number | null
  hrv_min: number | null
  hrv_max: number | null
  rr_avg: number | null
  cognitive_capacity_avg: number | null
  sdnn_avg: number | null
  pnn50_avg: number | null
  dfa_alpha1_avg: number | null
  movement_score_avg: number | null
  hmm_state_latest: string | null
  sample_count: number
}

interface Percentiles {
  hrv: number | null
  rr: number | null
  cognitive_capacity: number | null
  sdnn: number | null
  pnn50: number | null
  dfa_alpha1: number | null
  movement_score: number | null
  baseline_n: number
}

interface ContextBundle {
  recent_brain_dumps: { content: string; created_at: string }[]
  emotional_snapshots: { emotions: string[] | null; valence: string | null; intensity: number | null; created_at: string }[]
  last_sleep: { metric_date: string; sleep_hours: number | null; recovery_score: number | null; resting_hr: number | null } | null
  last_workout: { activity_name: string | null; start_time: string; strain: number | null; duration_min: number | null; hours_ago: number } | null
}

// ── Data pulls ──────────────────────────────────────────────────────────
const SIGNAL_COLS = 'recorded_at, hrv_rmssd, respiratory_rate, cognitive_capacity, sdnn, pnn50, dfa_alpha1, movement_score, hmm_state'

async function pullLast60Min(): Promise<RtRow[]> {
  const since = new Date(Date.now() - 60 * 60 * 1000).toISOString()
  const { data, error } = await supabase.from('realtime_health')
    .select(SIGNAL_COLS)
    .eq('user_id', USER_ID)
    .gte('recorded_at', since)
    .order('recorded_at', { ascending: false })
    .limit(5000)
  if (error) throw new Error(`pull last60: ${error.message}`)
  return (data ?? []) as RtRow[]
}

async function pullBaselineForHour(hour: number): Promise<RtRow[]> {
  // Last 30 days, same hour-of-day. UTC hour — matches morning_window_avg in daily.ts.
  const since = new Date(Date.now() - 30 * 24 * 60 * 60 * 1000).toISOString()
  // Fetch wider window then filter by hour client-side (Supabase doesn't expose EXTRACT in PostgREST).
  // To stay under the 1000-row cap we narrow to the hour using a SQL filter via .or(), but PostgREST
  // doesn't support EXTRACT either. Cheap workaround: pull the column we need and filter in JS.
  // 30 days * 24 hr * 60 min ≈ 43k rows worst case → enforce limit + sample.
  const { data, error } = await supabase.from('realtime_health')
    .select(SIGNAL_COLS)
    .eq('user_id', USER_ID)
    .gte('recorded_at', since)
    .order('recorded_at', { ascending: false })
    .limit(50000)
  if (error) throw new Error(`pull baseline: ${error.message}`)
  const all = (data ?? []) as RtRow[]
  return all.filter(r => new Date(r.recorded_at).getUTCHours() === hour)
}

async function pullContext(): Promise<ContextBundle> {
  const since24h = new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString()
  const since48h = new Date(Date.now() - 48 * 60 * 60 * 1000).toISOString()

  const [bdRes, esRes, hmRes, hwRes] = await Promise.all([
    supabase.from('brain_dumps')
      .select('content, created_at')
      .eq('user_id', USER_ID)
      .gte('created_at', since24h)
      .order('created_at', { ascending: false })
      .limit(5),
    supabase.from('emotional_snapshots')
      .select('emotions, valence, intensity, created_at')
      .eq('user_id', USER_ID)
      .gte('created_at', since24h)
      .order('created_at', { ascending: false })
      .limit(3),
    supabase.from('health_metrics')
      .select('metric_date, sleep_hours, recovery_score, resting_hr')
      .eq('user_id', USER_ID)
      .order('metric_date', { ascending: false })
      .limit(1),
    supabase.from('health_workouts')
      .select('activity_name, start_time, strain, duration_min')
      .eq('user_id', USER_ID)
      .gte('start_time', since48h)
      .order('start_time', { ascending: false })
      .limit(1),
  ])

  if (bdRes.error) throw new Error(`brain_dumps: ${bdRes.error.message}`)
  if (esRes.error) throw new Error(`emotional_snapshots: ${esRes.error.message}`)
  if (hmRes.error) throw new Error(`health_metrics: ${hmRes.error.message}`)
  if (hwRes.error) throw new Error(`health_workouts: ${hwRes.error.message}`)

  const lastWorkout = hwRes.data?.[0]
  const workoutOut = lastWorkout
    ? {
        activity_name: lastWorkout.activity_name as string | null,
        start_time: lastWorkout.start_time as string,
        strain: lastWorkout.strain as number | null,
        duration_min: lastWorkout.duration_min as number | null,
        hours_ago: Math.round((Date.now() - new Date(lastWorkout.start_time as string).getTime()) / 36e5),
      }
    : null

  return {
    recent_brain_dumps: (bdRes.data ?? []) as { content: string; created_at: string }[],
    emotional_snapshots: (esRes.data ?? []) as { emotions: string[] | null; valence: string | null; intensity: number | null; created_at: string }[],
    last_sleep: (hmRes.data?.[0] ?? null) as ContextBundle['last_sleep'],
    last_workout: workoutOut,
  }
}

// ── Compute raw_signal + percentiles ────────────────────────────────────
function computeRaw(rows: RtRow[]): RawSignal {
  const num = (k: keyof RtRow) => rows.map(r => Number(r[k] ?? NaN)).filter(Number.isFinite)
  return {
    hrv_avg: avg(num('hrv_rmssd')),
    hrv_min: minOf(num('hrv_rmssd')),
    hrv_max: maxOf(num('hrv_rmssd')),
    rr_avg: avg(num('respiratory_rate')),
    cognitive_capacity_avg: avg(num('cognitive_capacity')),
    sdnn_avg: avg(num('sdnn')),
    pnn50_avg: avg(num('pnn50')),
    dfa_alpha1_avg: avg(num('dfa_alpha1')),
    movement_score_avg: avg(num('movement_score')),
    hmm_state_latest: rows[0]?.hmm_state ?? null, // rows are desc-ordered → [0] is newest
    sample_count: rows.length,
  }
}

function computePercentiles(raw: RawSignal, baseline: RtRow[]): Percentiles {
  const dist = (k: keyof RtRow) => baseline.map(r => Number(r[k] ?? NaN)).filter(Number.isFinite)
  return {
    hrv: percentileRank(dist('hrv_rmssd'), raw.hrv_avg),
    rr: percentileRank(dist('respiratory_rate'), raw.rr_avg),
    cognitive_capacity: percentileRank(dist('cognitive_capacity'), raw.cognitive_capacity_avg),
    sdnn: percentileRank(dist('sdnn'), raw.sdnn_avg),
    pnn50: percentileRank(dist('pnn50'), raw.pnn50_avg),
    dfa_alpha1: percentileRank(dist('dfa_alpha1'), raw.dfa_alpha1_avg),
    movement_score: percentileRank(dist('movement_score'), raw.movement_score_avg),
    baseline_n: baseline.length,
  }
}

// ── Build user prompt for Gemini ────────────────────────────────────────
function buildUserPrompt(raw: RawSignal, pcts: Percentiles, ctx: ContextBundle, hour: number, dow: number): string {
  const fmt = (v: number | null, decimals = 1) => v == null ? 'n/a' : v.toFixed(decimals)
  const pct = (v: number | null) => v == null ? 'n/a' : `${v}th pctile`
  const dowName = ['Sun','Mon','Tue','Wed','Thu','Fri','Sat'][dow]

  const bdList = ctx.recent_brain_dumps.length === 0
    ? '(none in last 24h)'
    : ctx.recent_brain_dumps.map((b, i) => `  ${i + 1}. [${b.created_at.slice(0, 16).replace('T', ' ')}] ${b.content.slice(0, 280).replace(/\s+/g, ' ')}`).join('\n')

  const esList = ctx.emotional_snapshots.length === 0
    ? '(none in last 24h)'
    : ctx.emotional_snapshots.map((e, i) => `  ${i + 1}. ${e.valence ?? '?'} (intensity ${e.intensity ?? '?'}/10) emotions=${(e.emotions ?? []).join(', ') || 'n/a'}`).join('\n')

  const sleep = ctx.last_sleep
    ? `  ${ctx.last_sleep.metric_date}: ${fmt(ctx.last_sleep.sleep_hours)}h sleep, recovery_score=${fmt(ctx.last_sleep.recovery_score, 0)}, resting_hr=${ctx.last_sleep.resting_hr ?? 'n/a'}`
    : '  (no recent sleep data)'

  const workout = ctx.last_workout
    ? `  ${ctx.last_workout.hours_ago}h ago: ${ctx.last_workout.activity_name ?? 'workout'}, strain=${fmt(ctx.last_workout.strain)}, ${ctx.last_workout.duration_min ?? '?'}min`
    : '  (no workout in last 48h)'

  return `## Right now (${dowName} ${String(hour).padStart(2, '0')}:00 UTC)

### Last 60 min — averaged signals
- HRV (rmssd): ${fmt(raw.hrv_avg)} ms (range ${fmt(raw.hrv_min)}–${fmt(raw.hrv_max)})
- Respiratory rate: ${fmt(raw.rr_avg)} br/min
- Cognitive capacity: ${fmt(raw.cognitive_capacity_avg)} / 100
- SDNN: ${fmt(raw.sdnn_avg)}
- pNN50: ${fmt(raw.pnn50_avg, 2)}
- DFA alpha1: ${fmt(raw.dfa_alpha1_avg, 2)}
- Movement score: ${fmt(raw.movement_score_avg, 2)}
- Latest HMM state: ${raw.hmm_state_latest ?? 'n/a'}
- Samples: ${raw.sample_count}

### Percentile vs. typical for hour ${hour} (last 30 days, n=${pcts.baseline_n} samples)
- HRV: ${pct(pcts.hrv)}
- RR: ${pct(pcts.rr)}
- Cognitive capacity: ${pct(pcts.cognitive_capacity)}
- SDNN: ${pct(pcts.sdnn)}
- pNN50: ${pct(pcts.pnn50)}
- DFA alpha1: ${pct(pcts.dfa_alpha1)}
- Movement: ${pct(pcts.movement_score)}

### Recent brain dumps (last 24h)
${bdList}

### Recent emotional snapshots (last 24h)
${esList}

### Last sleep
${sleep}

### Last workout
${workout}

Now write your interpretation per the style rules. 150-300 words.`
}

// ── Gemini 2.5 Flash call ───────────────────────────────────────────────
interface GeminiResponse {
  candidates?: { content?: { parts?: { text?: string }[] } }[]
  usageMetadata?: { promptTokenCount?: number; candidatesTokenCount?: number; totalTokenCount?: number }
  error?: { code?: number; message?: string; status?: string }
}

async function callGemini(userPrompt: string): Promise<{ text: string; tokens_in: number | null; tokens_out: number | null; latency_ms: number; raw_status: number }> {
  const t0 = Date.now()
  const url = `https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=${GEMINI_KEY}`
  const body = {
    contents: [{
      role: 'user',
      parts: [
        { text: HERMES_SYSTEM_PROMPT }, // long stable prefix → enables implicit caching
        { text: userPrompt },
      ],
    }],
    generationConfig: {
      temperature: 0.7,
      maxOutputTokens: 1500,
      // Gemini 2.5 Flash uses internal "thinking" tokens that count toward maxOutputTokens.
      // Cap thinking at 256 so the actual interpretation gets enough room (~150-300 words ≈ 200-400 tokens).
      thinkingConfig: { thinkingBudget: 256 },
    },
  }
  const r = await fetch(url, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) })
  const status = r.status
  const j = (await r.json()) as GeminiResponse
  const latency_ms = Date.now() - t0
  if (j.error) throw new Error(`Gemini ${j.error.code ?? '?'}: ${j.error.message ?? 'unknown'}`)
  const text = j.candidates?.[0]?.content?.parts?.map(p => p.text ?? '').join('') ?? ''
  if (!text) throw new Error(`Gemini returned no text (status ${status}): ${JSON.stringify(j).slice(0, 500)}`)
  return {
    text,
    tokens_in: j.usageMetadata?.promptTokenCount ?? null,
    tokens_out: j.usageMetadata?.candidatesTokenCount ?? null,
    latency_ms,
    raw_status: status,
  }
}

// ── Persist snapshot ────────────────────────────────────────────────────
async function persistSnapshot(args: {
  hour: number
  dow: number
  raw: RawSignal
  pcts: Percentiles
  ctx: ContextBundle
  text: string
  tokens_in: number | null
  tokens_out: number | null
  latency_ms: number
}): Promise<void> {
  const { error } = await supabase.from('hermes_now_snapshots').insert({
    hour_of_day: args.hour,
    day_of_week: args.dow,
    raw_signal: args.raw,
    percentiles: args.pcts,
    context: {
      brain_dumps_count: args.ctx.recent_brain_dumps.length,
      emotional_snapshots_count: args.ctx.emotional_snapshots.length,
      last_sleep_hours: args.ctx.last_sleep?.sleep_hours ?? null,
      last_recovery_score: args.ctx.last_sleep?.recovery_score ?? null,
      last_workout_hours_ago: args.ctx.last_workout?.hours_ago ?? null,
      last_workout_strain: args.ctx.last_workout?.strain ?? null,
    },
    interpretation: args.text,
    llm_model: 'gemini-2.5-flash',
    llm_tokens_in: args.tokens_in,
    llm_tokens_out: args.tokens_out,
    latency_ms: args.latency_ms,
  })
  if (error) throw new Error(`persist: ${error.message}`)
}

// ── Handler ─────────────────────────────────────────────────────────────
export default async function handler(req: VercelRequest, res: VercelResponse) {
  if (!(await hermesAuthOk(req, authVerifier))) return res.status(401).json({ error: 'Unauthorized' })
  if (!GEMINI_KEY) return res.status(500).json({ error: 'gemini_key_missing', message: 'GOOGLE_AI_API_KEY env var not set' })

  const t0 = Date.now()
  const now = new Date()
  const hour = now.getUTCHours()
  const dow = now.getUTCDay()

  try {
    const [last60, baseline, ctx] = await Promise.all([
      pullLast60Min(),
      pullBaselineForHour(hour),
      pullContext(),
    ])

    if (last60.length === 0) {
      return res.status(200).json({
        computed_at: now.toISOString(),
        warning: 'no_recent_signals',
        message: 'No realtime_health rows in the last 60 minutes. LucidBridge may be offline.',
        hour_of_day: hour,
      })
    }

    const raw = computeRaw(last60)
    const pcts = computePercentiles(raw, baseline)
    const userPrompt = buildUserPrompt(raw, pcts, ctx, hour, dow)

    const { text, tokens_in, tokens_out, latency_ms } = await callGemini(userPrompt)

    // Fire-and-forget persist (don't fail the response if DB write hiccups)
    void persistSnapshot({ hour, dow, raw, pcts, ctx, text, tokens_in, tokens_out, latency_ms }).catch(e => {
      console.error('hermes_now persist failed:', (e as Error).message)
    })

    return res.status(200).json({
      computed_at: now.toISOString(),
      raw_signal: raw,
      percentiles: pcts,
      context: {
        last_sleep_hours: ctx.last_sleep?.sleep_hours ?? null,
        last_recovery_score: ctx.last_sleep?.recovery_score ?? null,
        last_workout_strain: ctx.last_workout?.strain ?? null,
        last_workout_hours_ago: ctx.last_workout?.hours_ago ?? null,
        recent_brain_dumps_count: ctx.recent_brain_dumps.length,
        recent_emotional_snapshots_count: ctx.emotional_snapshots.length,
      },
      interpretation: text,
      metadata: {
        model: 'gemini-2.5-flash',
        latency_ms,
        total_ms: Date.now() - t0,
        tokens_in,
        tokens_out,
        baseline_samples: pcts.baseline_n,
        recent_samples: raw.sample_count,
      },
    })
  } catch (e: unknown) {
    return res.status(500).json({
      error: 'hermes_now_failed',
      message: (e as Error).message,
      hour_of_day: hour,
    })
  }
}
