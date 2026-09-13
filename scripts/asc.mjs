#!/usr/bin/env node
// App Store Connect API client. One .p8 key, permanent control over every app
// on the team: bundle IDs, capabilities, app records, TestFlight, builds, testers.
//
// Credentials live OUTSIDE this repo (it is public) at
// C:/Programs/Claude/.secrets/asc.json -> { keyId, issuerId, p8Path }
//
//   node scripts/asc.mjs whoami
//   node scripts/asc.mjs apps
//   node scripts/asc.mjs bundles
//   node scripts/asc.mjs bundle-create com.fabi.lucidride "Ride"
//   node scripts/asc.mjs caps com.fabi.lucidhealth
//   node scripts/asc.mjs cap-enable com.fabi.lucidhealth APP_GROUPS
//   node scripts/asc.mjs app-create com.fabi.lucidride "Ride" lucidride
//   node scripts/asc.mjs builds com.fabi.lucidhealth
//   node scripts/asc.mjs beta-groups <appId>
//   node scripts/asc.mjs raw GET /v1/apps?limit=5
//   node scripts/asc.mjs raw POST /v1/bundleIds '{"data":{...}}'

import { createSign } from 'node:crypto'
import { readFileSync, existsSync } from 'node:fs'

const CFG = process.env.ASC_CONFIG || 'C:/Programs/Claude/.secrets/asc.json'

function creds() {
  if (process.env.ASC_KEY_ID && process.env.ASC_ISSUER_ID && process.env.ASC_KEY_PATH) {
    return { keyId: process.env.ASC_KEY_ID, issuerId: process.env.ASC_ISSUER_ID, p8Path: process.env.ASC_KEY_PATH }
  }
  if (!existsSync(CFG)) {
    console.error(`No credentials. Write ${CFG}:\n  { "keyId": "ABC123", "issuerId": "uuid", "p8Path": "C:/Programs/Claude/.secrets/AuthKey_ABC123.p8" }`)
    process.exit(2)
  }
  return JSON.parse(readFileSync(CFG, 'utf8'))
}

function token() {
  const { keyId, issuerId, p8Path } = creds()
  const key = readFileSync(p8Path, 'utf8')
  const b64 = (o) => Buffer.from(JSON.stringify(o)).toString('base64url')
  const iat = Math.floor(Date.now() / 1000)
  const head = b64({ alg: 'ES256', kid: keyId, typ: 'JWT' })
  const body = b64({ iss: issuerId, iat, exp: iat + 1140, aud: 'appstoreconnect-v1' })
  const s = createSign('SHA256')
  s.update(`${head}.${body}`)
  // JWS wants raw r|s, not the DER sequence OpenSSL emits by default.
  const sig = s.sign({ key, dsaEncoding: 'ieee-p1363' }).toString('base64url')
  return `${head}.${body}.${sig}`
}

const BASE = 'https://api.appstoreconnect.apple.com'
let JWT = null

// Git Bash (MSYS) rewrites a bare argument like /v1/betaGroups into
// C:/Program Files/Git/v1/betaGroups before node ever sees it — measured
// 2026-09-13, and it surfaces as an unhelpful "fetch failed / ENOTFOUND"
// against a host that is perfectly reachable. Args carrying a query string
// escape the rewrite, which is why GET calls looked fine and POSTs did not.
const unmangle = (p) => (p.startsWith('/') ? p : p.replace(/^.*?(?=\/v\d+\/)/, ''))

async function api(method, path, body) {
  JWT ||= token()
  const res = await fetch(path.startsWith('http') ? path : BASE + unmangle(path), {
    method,
    headers: { Authorization: `Bearer ${JWT}`, 'Content-Type': 'application/json' },
    body: body ? JSON.stringify(body) : undefined,
  })
  const text = await res.text()
  let json = null
  try { json = text ? JSON.parse(text) : null } catch { /* keep text */ }
  if (!res.ok) {
    const errs = json?.errors?.map(e => `${e.status} ${e.code}: ${e.title} — ${e.detail || ''}`).join('\n  ') || text.slice(0, 500)
    throw new Error(`${method} ${path} failed\n  ${errs}`)
  }
  return json
}

// Paginates. The API caps limit at 200 and hands back a next link.
async function all(path) {
  const out = []
  let next = path
  while (next) {
    const page = await api('GET', next)
    out.push(...(page.data || []))
    next = page.links?.next || null
  }
  return out
}

const bundleIdOf = async (identifier) => {
  const hits = await all(`/v1/bundleIds?filter[identifier]=${encodeURIComponent(identifier)}&limit=200`)
  const exact = hits.find(b => b.attributes.identifier === identifier)
  if (!exact) throw new Error(`bundle id not registered: ${identifier}`)
  return exact
}

const appOf = async (identifier) => {
  const hits = await all(`/v1/apps?filter[bundleId]=${encodeURIComponent(identifier)}&limit=200`)
  if (!hits.length) throw new Error(`no App Store Connect app record for ${identifier}`)
  return hits[0]
}

const row = (...c) => console.log(c.join('  '))

const CMDS = {
  async whoami() {
    const apps = await all('/v1/apps?limit=200')
    row('apps on team:', String(apps.length))
    for (const a of apps) row(' ', a.id, a.attributes.bundleId, '|', a.attributes.name)
    const b = await all('/v1/bundleIds?limit=200')
    row('\nbundle ids:', String(b.length))
    for (const x of b) row(' ', x.attributes.identifier, '|', x.attributes.platform, '|', x.attributes.name)
  },

  async apps() {
    for (const a of await all('/v1/apps?limit=200')) {
      row(a.id, a.attributes.bundleId, '|', a.attributes.name, '|', a.attributes.sku)
    }
  },

  async bundles() {
    for (const b of await all('/v1/bundleIds?limit=200')) {
      row(b.id, b.attributes.identifier, '|', b.attributes.platform, '|', b.attributes.name)
    }
  },

  // Xcode's -allowProvisioningUpdates registers bundle IDs itself, so this is
  // for the cases where it does not: widgets, extensions, a new app scaffolded
  // before its first build.
  async 'bundle-create'(identifier, name, platform = 'IOS') {
    const r = await api('POST', '/v1/bundleIds', {
      data: { type: 'bundleIds', attributes: { identifier, name: name || identifier, platform, seedId: undefined } },
    })
    row('created', r.data.id, r.data.attributes.identifier)
  },

  async caps(identifier) {
    const b = await bundleIdOf(identifier)
    // Relationship endpoints reject ?limit — 400 PARAMETER_ERROR.ILLEGAL.
    const caps = await all(`/v1/bundleIds/${b.id}/bundleIdCapabilities`)
    row(identifier, '->', b.id)
    for (const c of caps) row(' ', c.attributes.capabilityType, JSON.stringify(c.attributes.settings || []))
  },

  async 'cap-enable'(identifier, capabilityType) {
    const b = await bundleIdOf(identifier)
    const r = await api('POST', '/v1/bundleIdCapabilities', {
      data: {
        type: 'bundleIdCapabilities',
        attributes: { capabilityType },
        relationships: { bundleId: { data: { type: 'bundleIds', id: b.id } } },
      },
    })
    row('enabled', capabilityType, 'on', identifier, '->', r.data.id)
  },

  // Measured 2026-09-13, not guessed: POST /v1/apps returns
  //   403 FORBIDDEN_ERROR - The resource 'apps' does not allow 'CREATE'.
  //   Allowed operations are: GET_COLLECTION, GET_INSTANCE, UPDATE
  // So the first app record for a bundle ID is a browser job, once per app.
  // Everything after it (builds, TestFlight, metadata UPDATE) is scriptable.
  async 'app-create'(bundleId) {
    console.error([
      `Apple does not allow app-record creation over the API (403, CREATE not permitted).`,
      `Create it once at https://appstoreconnect.apple.com/apps -> + -> New App`,
      `  Platform iOS | Bundle ID ${bundleId || '<bundle>'} | SKU = the bundle's last component`,
      `Then everything else here works against it.`,
    ].join(String.fromCharCode(10)))
    process.exit(3)
  },

  async builds(identifier) {
    const app = await appOf(identifier)
    const builds = await all(`/v1/builds?filter[app]=${app.id}&limit=20&sort=-version`)
    row(identifier, '->', app.id, `(${builds.length} builds)`)
    for (const b of builds.slice(0, 15)) {
      row(' build', b.attributes.version, '|', b.attributes.processingState, '|', b.attributes.uploadedDate,
        '| expired:', String(b.attributes.expired))
    }
  },

  async 'beta-groups'(identifier) {
    const app = await appOf(identifier)
    for (const g of await all(`/v1/betaGroups?filter[app]=${app.id}&limit=200`)) {
      row(g.id, g.attributes.name, '| internal:', String(g.attributes.isInternalGroup))
    }
  },

  async testers() {
    for (const t of await all('/v1/betaTesters?limit=200')) {
      row(t.id, t.attributes.email, '|', t.attributes.state)
    }
  },

  async raw(method, path, body) {
    console.log(JSON.stringify(await api(method.toUpperCase(), path, body ? JSON.parse(body) : undefined), null, 2))
  },
}

const [cmd, ...args] = process.argv.slice(2)
if (!cmd || !CMDS[cmd]) {
  console.error('commands: ' + Object.keys(CMDS).join(', '))
  process.exit(1)
}
try {
  await CMDS[cmd](...args)
} catch (e) {
  console.error(String(e.message || e))
  // undici's "fetch failed" hides the real reason in .cause — print it.
  if (e.cause) console.error('  cause: ' + (e.cause.code || e.cause.message || String(e.cause)))
  process.exit(1)
}
