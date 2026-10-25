#!/usr/bin/env node
// Replays the server sleep stager over past nights inside one rolled-back transaction and reports
// which nights a candidate change moves, plus the invariants every night must hold.
//
//   node scripts/replay-nights.mjs                        current live stager, invariants only
//   node scripts/replay-nights.mjs candidate.sql          diff live vs candidate (candidate never commits)
//   node scripts/replay-nights.mjs candidate.sql --expect 2026-10-25,2026-10-11
//
// Env: SUPABASE_URL (default https://db.speed-running-life.com), SUPABASE_SERVICE_KEY or LUCID_MCP_JSON
// (path to an .mcp.json holding --service-key), LUCID_USER_ID, REPLAY_FROM / REPLAY_TO (dates).
// Output is aggregate per night only. Nothing personal lives in this file; never commit its output.
import fs from 'fs';

const args = process.argv.slice(2);
const candidate = args[0] && !args[0].startsWith('--') ? fs.readFileSync(args[0], 'utf8') : null;
const expectIdx = args.indexOf('--expect');
const expected = new Set(expectIdx >= 0 ? args[expectIdx + 1].split(',') : []);

const url = (process.env.SUPABASE_URL || 'https://db.speed-running-life.com') + '/pg/query';
let key = process.env.SUPABASE_SERVICE_KEY;
if (!key) {
  const j = JSON.parse(fs.readFileSync(process.env.LUCID_MCP_JSON || 'C:/Programs/Claude/ee-personal-app/.mcp.json', 'utf8'));
  const a = j.mcpServers['supabase-hetzner'].args;
  key = a[a.indexOf('--service-key') + 1];
}
const user = process.env.LUCID_USER_ID;
if (!user || !/^[0-9a-f-]{36}$/.test(user)) { console.error('set LUCID_USER_ID'); process.exit(2); }
const from = process.env.REPLAY_FROM || new Date(Date.now() - 62 * 864e5).toISOString().slice(0, 10);
const to = process.env.REPLAY_TO || new Date().toISOString().slice(0, 10);
for (const d of [from, to]) if (!/^\d{4}-\d{2}-\d{2}$/.test(d)) { console.error('bad date ' + d); process.exit(2); }

const summary = (fn) => `
  select d.d::date::text night, x.*
    from generate_series(date '${from}', date '${to}', interval '1 day') d(d),
    lateral (
      with m as (select * from ${fn}('${user}'::uuid, d.d::date)),
      b as (select n_stage, count(*) len from (
              select n_stage, row_number() over (order by n_m_ts) - row_number() over (partition by n_stage order by n_m_ts) g
                from m where not n_pre_onset) r group by n_stage, g)
      select count(*) mins,
             count(*) filter (where n_stage <> 'awake' and not n_pre_onset) asleep,
             count(*) filter (where n_stage = 'deep') deep,
             count(*) filter (where n_stage = 'rem') rem,
             count(distinct n_m_ts) uniq,
             to_char(min(n_m_ts) filter (where not n_pre_onset) at time zone 'Europe/Berlin', 'MM-DD HH24:MI') onset,
             to_char(max(n_m_ts) at time zone 'Europe/Berlin', 'MM-DD HH24:MI') last,
             (select min(len) from b where n_stage = 'deep') min_deep_bout
        from m) x
   order by 1`;

let q = 'begin;\ncreate temp table r_live as ' + summary('sleep_night_minutes') + ';\n';
if (candidate) q += candidate.trim().replace(/;\s*$/, '') + ';\ncreate temp table r_cand as ' + summary('sleep_night_minutes') + ';\n';
else q += 'create temp table r_cand as select * from r_live;\n';
q += `select l.*, row_to_json(c) cand from r_live l join r_cand c using (night) order by night;\nrollback;\n`;

const r = await fetch(url, { method: 'POST', headers: { apikey: key, Authorization: 'Bearer ' + key, 'content-type': 'application/json' }, body: JSON.stringify({ query: q }) });
const t = await r.text();
if (!/^\s*[[{]/.test(t)) { console.error('HTTP ' + r.status + ' not JSON: ' + JSON.stringify(t.slice(0, 300))); process.exit(1); }
const rows = JSON.parse(t);
if (!r.ok || !Array.isArray(rows)) { console.error('HTTP ' + r.status + ' ' + t.slice(0, 500)); process.exit(1); }

const fields = ['mins', 'asleep', 'deep', 'rem', 'onset', 'last'];
let changed = 0, unexpected = 0, broken = 0;
for (const l of rows) {
  const c = l.cand;
  const diff = fields.filter((f) => String(l[f]) !== String(c[f]));
  const bad = [];
  if (+c.uniq !== +c.mins) bad.push('duplicate minutes');
  if (+c.asleep > 0 && +c.deep / +c.asleep > 0.30) bad.push('deep > 30 %');
  if (+c.asleep > 0 && +c.rem / +c.asleep > 0.35) bad.push('rem > 35 %');
  if (c.min_deep_bout != null && +c.min_deep_bout < 8) bad.push('deep bout ' + c.min_deep_bout + ' min');
  if (+c.mins > 17 * 60) bad.push('more minutes than the window');
  if (diff.length) {
    changed++;
    if (candidate && !expected.has(l.night)) unexpected++;
    console.log(`${l.night} CHANGED ${diff.map((f) => `${f} ${l[f]} -> ${c[f]}`).join(', ')}${expected.has(l.night) ? ' (expected)' : ''}`);
  }
  if (bad.length) { broken++; console.log(`${l.night} INVARIANT ${bad.join(', ')}`); }
}
console.log(`${rows.length} nights ${from}..${to}: ${changed} changed, ${unexpected} unexpected, ${broken} invariant failures`);
process.exit(unexpected || broken ? 1 : 0);
