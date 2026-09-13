import type { VercelRequest, VercelResponse } from '@vercel/node'
import { createClient } from '@supabase/supabase-js'
import { hermesAuthOk, authClient } from './_auth.js'

// ── Hermes V0.6 — conversational body-state interpreter ─────────────────
// POST /api/hermes/chat
// Body: { message: string, history?: ChatTurn[] }
// Auth: Authorization: Bearer $HERMES_TRIGGER_SECRET (or CRON_SECRET)
//
// Gathers rich context from 6 tables (latest /now snapshot + matched
// patterns + last 7d tasks + last 3d brain_dumps + last 5 emotional
// snapshots + latest health_metrics) and asks Gemini 2.5 Flash to
// answer the user's question grounded on it.
//
// Conversation history is client-owned — iOS sends prior turns each call.
// No server persistence in V0.6.

const SUPABASE_URL = process.env.VITE_SUPABASE_URL || process.env.SUPABASE_URL || ''
const SUPABASE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY || process.env.VITE_SUPABASE_ANON_KEY || ''
const GEMINI_KEY = process.env.GOOGLE_AI_API_KEY || process.env.VITE_GOOGLE_AI_API_KEY || ''
const USER_ID = process.env.HERMES_USER_ID || ''

const supabase = createClient(SUPABASE_URL, SUPABASE_KEY, {
  auth: { persistSession: false },
})

const HERMES_CHAT_SYSTEM = `You are Hermes — Fabi's body-state-aware conversational companion inside the Health app.

Fabi just messaged you. You have rich context attached below: his body state RIGHT NOW (HRV percentiles, sleep, recovery), task activity (last 7 days, what he finished, how hard, when), brain dumps (last 3 days, what's on his mind), emotional snapshots, matched correlation patterns.

Use that context to answer like a smart friend who has access to all his data and isn't afraid to be direct.

Style:
- Direct and warm. Answer the question. Don't deflect to "what do YOU think?"
- Reference specific data when it explains the answer: "Your HRV is bottom 20% right now AND you slept 4.2h. That's why."
- Connect 2-3 signals into a story when it lands. Don't list 7 things.
- If data is weak, say so plainly: "I don't have great data for this — your last emotional snapshot was 6 days ago."
- No medical disclaimers. No "consult a doctor." No "I'm an AI." No "you might want to consider."
- Match his tone — typos are fine, casual is fine, short answers are fine.
- Typical answer: 2-5 sentences. Go longer only if he asks for deep analysis.
- One practical suggestion only if it's obviously needed. Not a checklist.

Avoid:
- Generic wellness platitudes ("listen to your body")
- Lecturing or moralizing
- Hedging when the data is clear
- Lists of >3 items (Fabi has ADHD; lists fragment attention)
- Saying "as an AI" or "I'm a language model"

Fabi: 30yo German entrepreneur, ADHD + mild dyslexia, sport-bike rider, runs his businesses from a Windows PC, tracks his HRV via a jailbroken Whoop. Knows his data well. Wants the truth, not pep talks.

If he asks "why am I feeling X" — answer based on his actual data, not generic causes.
If he asks "what's going on" — read the strongest signals in his current state.
If he asks for advice — give him ONE concrete thing tied to what the data shows.`

// Auth uses the shared hermesAuthOk helper, which accepts:
//   - HERMES_TRIGGER_SECRET (manual triggers)
//   - CRON_SECRET (Vercel cron)
//   - User session JWT (iOS app calls)
const authVerifier = authClient()

// ── Types ───────────────────────────────────────────────────────────────
interface ChatTurn { role: 'user' | 'assistant'; content: string }
interface ChatRequest { message?: string; history?: ChatTurn[] }

interface NowSnapshot {
  computed_at: string
  raw_signal: Record<string, unknown> | null
  percentiles: Record<string, number | null> | null
  context: Record<string, unknown> | null
  interpretation: string | null
}

interface PatternMatch {
  pattern_name: string
  correlation_r: number | null
  n_samples: number | null
  matched: boolean | null
  computed_at: string
}

interface TaskRow {
  id: string
  title: string
  priority: string | null
  status: string | null
  energy_level: string | null
  time_estimate_minutes: number | null
  actual_duration_minutes: number | null
  difficulty: number | null
  completed_at: string | null
  started_at: string | null
  project: string | null
}

interface BrainDumpRow {
  content: string | null
  tags: string[] | null
  created_at: string
}

interface EmotionalSnapshotRow {
  emotions: string[] | null
  intensity: number | null
  valence: string | null
  created_at: string
}

interface HealthMetricsRow {
  metric_date: string
  sleep_hours: number | null
  sleep_score: number | null
  recovery_score: number | null
  hrv_avg: number | null
  resting_hr: number | null
  strain_score: number | null
  readiness_level: string | null
}

// ── DB pulls ────────────────────────────────────────────────────────────
async function fetchLatestNow(): Promise<NowSnapshot | null> {
  const { data } = await supabase
    .from('hermes_now_snapshots')
    .select('computed_at, raw_signal, percentiles, context, interpretation')
    .eq('user_id', USER_ID)
    .order('computed_at', { ascending: false })
    .limit(1)
  return (data?.[0] as NowSnapshot) ?? null
}

async function fetchRecentMatches(): Promise<PatternMatch[]> {
  const { data } = await supabase
    .from('hermes_pattern_matches')
    .select('pattern_name, correlation_r, n_samples, matched, computed_at')
    .eq('matched', true)
    .order('computed_at', { ascending: false })
    .limit(5)
  return (data as PatternMatch[]) ?? []
}

async function fetchRecentTasks(): Promise<TaskRow[]> {
  const sevenDaysAgo = new Date(Date.now() - 7 * 86400e3).toISOString()
  const { data } = await supabase
    .from('tasks')
    .select('id, title, priority, status, energy_level, time_estimate_minutes, actual_duration_minutes, difficulty, completed_at, started_at, project')
    .eq('user_id', USER_ID)
    .or(`completed_at.gte.${sevenDaysAgo},created_at.gte.${sevenDaysAgo}`)
    .order('completed_at', { ascending: false, nullsFirst: false })
    .limit(60)
  return (data as TaskRow[]) ?? []
}

async function fetchRecentDumps(): Promise<BrainDumpRow[]> {
  const threeDaysAgo = new Date(Date.now() - 3 * 86400e3).toISOString()
  const { data } = await supabase
    .from('brain_dumps')
    .select('content, tags, created_at')
    .eq('user_id', USER_ID)
    .gte('created_at', threeDaysAgo)
    .order('created_at', { ascending: false })
    .limit(15)
  return (data as BrainDumpRow[]) ?? []
}

async function fetchRecentEmotions(): Promise<EmotionalSnapshotRow[]> {
  const { data } = await supabase
    .from('emotional_snapshots')
    .select('emotions, intensity, valence, created_at')
    .eq('user_id', USER_ID)
    .order('created_at', { ascending: false })
    .limit(5)
  return (data as EmotionalSnapshotRow[]) ?? []
}

async function fetchLatestHealth(): Promise<HealthMetricsRow | null> {
  const { data } = await supabase
    .from('health_metrics')
    .select('metric_date, sleep_hours, sleep_score, recovery_score, hrv_avg, resting_hr, strain_score, readiness_level')
    .eq('user_id', USER_ID)
    .order('metric_date', { ascending: false })
    .limit(1)
  return (data?.[0] as HealthMetricsRow) ?? null
}

// ── Context block builder ──────────────────────────────────────────────
function buildContextBlock(
  now: NowSnapshot | null,
  matches: PatternMatch[],
  tasks: TaskRow[],
  dumps: BrainDumpRow[],
  emotions: EmotionalSnapshotRow[],
  health: HealthMetricsRow | null
): string {
  const lines: string[] = []
  const nowDate = new Date()
  lines.push(`Current time: ${nowDate.toISOString()} (Berlin: ${nowDate.toLocaleString('en-US', { timeZone: 'Europe/Berlin' })})`)
  lines.push(`Day of week: ${nowDate.toLocaleDateString('en-US', { weekday: 'long', timeZone: 'Europe/Berlin' })}`)
  lines.push('')

  // Body state right now
  lines.push('=== BODY STATE (now) ===')
  if (now) {
    const ageMin = Math.round((Date.now() - new Date(now.computed_at).getTime()) / 60000)
    lines.push(`Last /now snapshot: ${ageMin}m ago`)
    if (now.raw_signal) {
      const sig = now.raw_signal as Record<string, number | null>
      lines.push(`HRV ${sig.hrv_avg ?? '?'} (min ${sig.hrv_min ?? '?'} / max ${sig.hrv_max ?? '?'}), SDNN ${sig.sdnn_avg ?? '?'}, pNN50 ${sig.pnn50_avg ?? '?'}, DFA-α1 ${sig.dfa_alpha1_avg ?? '?'}, cognitive ${sig.cognitive_capacity_avg ?? '?'}`)
    }
    if (now.percentiles) {
      const p = now.percentiles
      lines.push(`Percentiles (vs same hour over last 30d): HRV ${p.hrv ?? '?'}, SDNN ${p.sdnn ?? '?'}, pNN50 ${p.pnn50 ?? '?'}, RR ${p.rr ?? '?'}, cognitive ${p.cognitive_capacity ?? '?'}`)
    }
    if (now.interpretation) {
      lines.push(`Last interpretation: "${String(now.interpretation).slice(0, 200)}"`)
    }
  } else {
    lines.push('(no recent /now snapshot — body state not measured in last hour)')
  }
  lines.push('')

  // Health metrics (last finalized day)
  lines.push('=== HEALTH (last finalized day) ===')
  if (health) {
    lines.push(`${health.metric_date} — sleep ${health.sleep_hours ?? '?'}h, score ${health.sleep_score ?? '?'}, recovery ${health.recovery_score ?? '?'} (${health.readiness_level ?? '?'}), HRV ${health.hrv_avg ?? '?'}, RHR ${health.resting_hr ?? '?'}, strain ${health.strain_score ?? '?'}`)
  } else {
    lines.push('(no health_metrics row yet)')
  }
  lines.push('')

  // Tasks — last 7 days, broken down
  lines.push('=== TASKS (last 7 days) ===')
  if (tasks.length) {
    const completed = tasks.filter(t => t.completed_at)
    const open = tasks.filter(t => !t.completed_at)
    lines.push(`Completed: ${completed.length} · Open: ${open.length}`)
    const byEnergy: Record<string, number> = {}
    const byPriority: Record<string, number> = {}
    const byProject: Record<string, number> = {}
    let totalEst = 0
    let totalActual = 0
    let actualCount = 0
    let difficultySum = 0
    let difficultyCount = 0
    for (const t of completed) {
      byEnergy[t.energy_level ?? 'unknown'] = (byEnergy[t.energy_level ?? 'unknown'] ?? 0) + 1
      byPriority[t.priority ?? 'unknown'] = (byPriority[t.priority ?? 'unknown'] ?? 0) + 1
      byProject[t.project ?? 'unknown'] = (byProject[t.project ?? 'unknown'] ?? 0) + 1
      if (t.time_estimate_minutes) totalEst += t.time_estimate_minutes
      if (t.actual_duration_minutes != null) { totalActual += t.actual_duration_minutes; actualCount++ }
      if (t.difficulty != null) { difficultySum += t.difficulty; difficultyCount++ }
    }
    lines.push(`By energy: ${Object.entries(byEnergy).map(([k, v]) => `${k}=${v}`).join(', ')}`)
    lines.push(`By priority: ${Object.entries(byPriority).map(([k, v]) => `${k}=${v}`).join(', ')}`)
    lines.push(`Top projects: ${Object.entries(byProject).sort((a, b) => b[1] - a[1]).slice(0, 5).map(([k, v]) => `${k}=${v}`).join(', ')}`)
    lines.push(`Total time estimated: ${totalEst}m (${(totalEst / 60).toFixed(1)}h)`)
    if (actualCount > 0) {
      lines.push(`Actually tracked time: ${totalActual}m across ${actualCount} tasks (avg ${Math.round(totalActual / actualCount)}m)`)
    } else {
      lines.push(`Actually tracked time: 0 tasks have actual_duration logged (feature is new)`)
    }
    if (difficultyCount > 0) {
      lines.push(`Avg self-rated difficulty: ${(difficultySum / difficultyCount).toFixed(1)}/5 across ${difficultyCount} rated tasks`)
    }
    // Last 5 completed tasks with detail
    const recent = completed.slice(0, 5)
    if (recent.length) {
      lines.push('Most recent completions:')
      for (const t of recent) {
        const when = t.completed_at ? new Date(t.completed_at).toISOString().slice(0, 16).replace('T', ' ') : '?'
        const dur = t.actual_duration_minutes != null ? `${t.actual_duration_minutes}m actual` : (t.time_estimate_minutes ? `~${t.time_estimate_minutes}m est` : '')
        const diff = t.difficulty != null ? `d${t.difficulty}` : ''
        const meta = [t.energy_level, t.priority, dur, diff].filter(Boolean).join(' · ')
        lines.push(`  ${when} — "${t.title.slice(0, 70)}" (${meta})`)
      }
    }
  } else {
    lines.push('(no tasks in last 7 days)')
  }
  lines.push('')

  // Brain dumps — what's on his mind
  lines.push('=== BRAIN DUMPS (last 3 days) ===')
  if (dumps.length) {
    for (const d of dumps.slice(0, 8)) {
      const when = new Date(d.created_at).toISOString().slice(0, 16).replace('T', ' ')
      const tags = d.tags && d.tags.length ? ` [${d.tags.join(',')}]` : ''
      lines.push(`  ${when}${tags}: "${String(d.content ?? '').slice(0, 200)}"`)
    }
  } else {
    lines.push('(no brain dumps in last 3 days)')
  }
  lines.push('')

  // Emotional snapshots
  lines.push('=== EMOTIONAL SNAPSHOTS (last 5) ===')
  if (emotions.length) {
    for (const e of emotions) {
      const when = new Date(e.created_at).toISOString().slice(0, 16).replace('T', ' ')
      const ems = (e.emotions ?? []).slice(0, 4).join(', ')
      lines.push(`  ${when} — ${e.valence ?? '?'} intensity ${e.intensity ?? '?'} [${ems}]`)
    }
  } else {
    lines.push('(no emotional snapshots logged)')
  }
  lines.push('')

  // Matched patterns
  lines.push('=== HERMES MATCHED PATTERNS (correlation engine findings) ===')
  if (matches.length) {
    for (const m of matches) {
      lines.push(`  "${m.pattern_name}" — r=${m.correlation_r?.toFixed(3) ?? '?'} (n=${m.n_samples})`)
    }
  } else {
    lines.push('(no matched patterns yet — engine needs more days of data)')
  }

  return lines.join('\n')
}

// ── Gemini call ─────────────────────────────────────────────────────────
interface GeminiResponse {
  candidates?: Array<{ content?: { parts?: Array<{ text?: string }> } }>
  usageMetadata?: { promptTokenCount?: number; candidatesTokenCount?: number }
}

async function callGemini(systemInstruction: string, userContent: string): Promise<{ text: string; tokens_in: number; tokens_out: number; latency_ms: number }> {
  const t0 = Date.now()
  const url = `https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=${GEMINI_KEY}`
  const body = {
    contents: [{ role: 'user', parts: [{ text: userContent }] }],
    systemInstruction: { parts: [{ text: systemInstruction }] },
    generationConfig: {
      temperature: 0.6,
      maxOutputTokens: 700,
      thinkingConfig: { thinkingBudget: 0 },  // chat doesn't need extended thinking
    },
  }
  const r = await fetch(url, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  })
  if (!r.ok) {
    const errBody = await r.text()
    throw new Error(`Gemini HTTP ${r.status}: ${errBody.slice(0, 300)}`)
  }
  const j = (await r.json()) as GeminiResponse
  const text = j.candidates?.[0]?.content?.parts?.map(p => p.text ?? '').join('') ?? ''
  return {
    text,
    tokens_in: j.usageMetadata?.promptTokenCount ?? 0,
    tokens_out: j.usageMetadata?.candidatesTokenCount ?? 0,
    latency_ms: Date.now() - t0,
  }
}

// ── Handler ─────────────────────────────────────────────────────────────
export default async function handler(req: VercelRequest, res: VercelResponse) {
  if (!(await hermesAuthOk(req, authVerifier))) return res.status(401).json({ error: 'Unauthorized' })
  if (req.method !== 'POST') return res.status(405).json({ error: 'method_not_allowed', hint: 'POST { message, history? }' })

  const body = req.body as ChatRequest
  const message = (body?.message ?? '').trim()
  if (!message) return res.status(400).json({ error: 'missing_message' })
  if (message.length > 4000) return res.status(400).json({ error: 'message_too_long', limit: 4000 })

  const history = Array.isArray(body?.history) ? body.history.slice(-12) : []

  // Pull context (6 parallel queries)
  const [now, matches, tasks, dumps, emotions, health] = await Promise.all([
    fetchLatestNow(),
    fetchRecentMatches(),
    fetchRecentTasks(),
    fetchRecentDumps(),
    fetchRecentEmotions(),
    fetchLatestHealth(),
  ])
  const contextBlock = buildContextBlock(now, matches, tasks, dumps, emotions, health)

  // Build conversation
  const historyLines = history.map(t => `${t.role === 'user' ? 'Fabi' : 'Hermes'}: ${t.content}`).join('\n\n')
  const userContent = [
    '=== CONTEXT (current state) ===',
    contextBlock,
    '',
    historyLines ? '=== PRIOR CONVERSATION ===\n' + historyLines + '\n' : '',
    '=== FABI ASKS ===',
    message,
    '',
    'Hermes:',
  ].filter(Boolean).join('\n')

  try {
    const result = await callGemini(HERMES_CHAT_SYSTEM, userContent)
    return res.status(200).json({
      reply: result.text,
      model: 'gemini-2.5-flash',
      tokens_in: result.tokens_in,
      tokens_out: result.tokens_out,
      latency_ms: result.latency_ms,
      context_summary: {
        now_snapshot_age_min: now ? Math.round((Date.now() - new Date(now.computed_at).getTime()) / 60000) : null,
        matched_patterns: matches.length,
        tasks_in_window: tasks.length,
        completed_tasks_in_window: tasks.filter(t => t.completed_at).length,
        brain_dumps_in_window: dumps.length,
        emotional_snapshots: emotions.length,
        last_health_date: health?.metric_date ?? null,
      },
    })
  } catch (e: unknown) {
    return res.status(500).json({ error: 'gemini_failed', message: (e as Error).message })
  }
}
