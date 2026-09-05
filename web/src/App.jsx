import React, { useEffect, useRef, useState } from 'react'

const C = { indigo: '#4f46e5', green: '#16a34a', red: '#dc2626', amber: '#b45309', line: '#e5e7eb', mute: '#666' }

const styles = {
  page: { fontFamily: 'system-ui, sans-serif', maxWidth: 860, margin: '32px auto', padding: '0 16px' },
  card: { border: '1px solid #ddd', borderRadius: 12, padding: 20, marginBottom: 20, boxShadow: '0 1px 4px rgba(0,0,0,.06)' },
  btn: { background: C.indigo, color: '#fff', border: 'none', borderRadius: 8, padding: '9px 16px', cursor: 'pointer', fontSize: 15 },
  btnGhost: { background: '#fff', color: C.indigo, border: `1px solid ${C.indigo}`, borderRadius: 8, padding: '8px 14px', cursor: 'pointer', fontSize: 14 },
  input: { padding: '9px 10px', borderRadius: 8, border: '1px solid #ccc', fontSize: 15, width: '100%', boxSizing: 'border-box' },
  table: { width: '100%', borderCollapse: 'collapse' },
  th: { textAlign: 'left', borderBottom: `2px solid ${C.line}`, padding: 8, fontSize: 13, color: C.mute },
  td: { borderBottom: '1px solid #f0f0f0', padding: 8, verticalAlign: 'top' },
  badge: (s) => ({
    padding: '2px 10px', borderRadius: 999, fontSize: 13, whiteSpace: 'nowrap',
    background: s === 'done' ? '#dcfce7' : s === 'failed' ? '#fee2e2' : '#fef9c3',
    color: s === 'done' ? '#166534' : s === 'failed' ? '#991b1b' : '#854d0e',
  }),
  barOuter: { height: 6, background: '#eee', borderRadius: 999, overflow: 'hidden', marginTop: 6 },
  barInner: (pct, s) => ({
    height: '100%', width: `${pct}%`,
    background: s === 'done' ? C.green : s === 'failed' ? C.red : C.indigo,
    transition: 'width .6s ease',
  }),
  steps: { display: 'flex', gap: 4, marginTop: 6 },
  step: (st) => ({ flex: 1, height: 4, borderRadius: 2, background: st === 'done' ? C.indigo : st === 'active' ? '#a5b4fc' : C.line }),
  detail: { fontSize: 12, color: C.mute, marginTop: 4 },
  testBanner: {
    background: '#fffbeb', border: '1px solid #fcd34d', color: C.amber,
    borderRadius: 8, padding: '8px 12px', fontSize: 13, marginBottom: 16,
  },
  planGrid: { display: 'grid', gridTemplateColumns: 'repeat(auto-fit,minmax(190px,1fr))', gap: 12 },
  plan: (cur) => ({
    border: `2px solid ${cur ? C.indigo : C.line}`, borderRadius: 10, padding: 14,
    background: cur ? '#eef2ff' : '#fff',
  }),
  row: { display: 'flex', gap: 10, alignItems: 'center', flexWrap: 'wrap' },
  err: { color: C.red, fontSize: 14 },
}

const STAGES = ['queued', 'downloading', 'separating', 'packaging', 'uploading', 'done']
const TOKEN_KEY = 'sonicloud.idToken'

function StageBar({ job }) {
  const pct = job.percent ?? (job.status === 'done' ? 100 : 5)
  const idx = STAGES.indexOf(job.stage || (job.status === 'done' ? 'done' : 'queued'))
  const failed = job.stage === 'failed'
  return (
    <div>
      <span style={styles.badge(failed ? 'failed' : job.status)}>{job.stage_label || job.status}</span>
      <div style={styles.barOuter}><div style={styles.barInner(failed ? 100 : pct, failed ? 'failed' : job.status)} /></div>
      {!failed && (
        <div style={styles.steps}>
          {STAGES.slice(1).map((s, i) => (
            <div key={s} title={s} style={styles.step(idx > i + 1 ? 'done' : idx === i + 1 ? 'active' : 'todo')} />
          ))}
        </div>
      )}
      {(job.stage_detail || job.elapsed_seconds != null) && (
        <div style={styles.detail}>
          {job.stage_detail}{job.elapsed_seconds != null && ` · ${Math.round(job.elapsed_seconds)}s`}
        </div>
      )}
    </div>
  )
}

function Auth({ onToken }) {
  const [mode, setMode] = useState('login')
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [err, setErr] = useState('')
  const [busy, setBusy] = useState(false)

  const submit = async () => {
    setBusy(true); setErr('')
    try {
      if (mode === 'signup') {
        const r = await fetch('/api/auth/signup', {
          method: 'POST', headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ email, password }),
        })
        if (!r.ok) throw new Error((await r.json()).error || 'signup failed')
      }
      const r = await fetch('/api/auth/login', {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ email, password }),
      })
      if (!r.ok) throw new Error((await r.json()).error || 'login failed')
      const { id_token } = await r.json()
      localStorage.setItem(TOKEN_KEY, id_token)
      onToken(id_token)
    } catch (e) { setErr(e.message) } finally { setBusy(false) }
  }

  return (
    <div style={styles.page}>
      <h1>🎵 SoniCloud</h1>
      <div style={styles.testBanner}>
        <b>Test environment.</b> Accounts and payments here are simulated. Do not use a real password.
      </div>
      <div style={styles.card}>
        <h3>{mode === 'login' ? 'Sign in' : 'Create an account'}</h3>
        <div style={{ display: 'grid', gap: 10, maxWidth: 360 }}>
          <input style={styles.input} placeholder="email" value={email} onChange={e => setEmail(e.target.value)} />
          <input style={styles.input} placeholder="password (min 8 chars, 1 number)" type="password"
                 value={password} onChange={e => setPassword(e.target.value)} />
          {err && <div style={styles.err}>{err}</div>}
          <div style={styles.row}>
            <button style={styles.btn} onClick={submit} disabled={busy}>
              {busy ? 'Working…' : mode === 'login' ? 'Sign in' : 'Sign up'}
            </button>
            <button style={styles.btnGhost} onClick={() => { setMode(mode === 'login' ? 'signup' : 'login'); setErr('') }}>
              {mode === 'login' ? 'Need an account?' : 'Have an account?'}
            </button>
          </div>
        </div>
      </div>
    </div>
  )
}

export default function App() {
  const [token, setToken] = useState(() => localStorage.getItem(TOKEN_KEY) || '')
  const [me, setMe] = useState(null)
  const [plans, setPlans] = useState({})
  const [jobs, setJobs] = useState([])
  const [stems, setStems] = useState(2)
  const [busy, setBusy] = useState(false)
  const [msg, setMsg] = useState('')
  const fileRef = useRef()

  const auth = { 'Authorization': `Bearer ${token}` }
  const signOut = () => { localStorage.removeItem(TOKEN_KEY); setToken(''); setMe(null); setJobs([]) }

  const loadMe = async () => {
    const r = await fetch('/api/me', { headers: auth })
    if (r.status === 401) return signOut()
    if (r.ok) setMe(await r.json())
  }
  const refresh = async () => {
    try {
      const r = await fetch('/api/jobs', { headers: auth })
      if (r.status === 401) return signOut()
      if (r.ok) setJobs(await r.json())
    } catch { /* transient */ }
  }

  useEffect(() => { fetch('/api/config').then(r => r.json()).then(c => setPlans(c.plans || {})) }, [])
  useEffect(() => { if (token) { loadMe(); refresh() } }, [token])

  const active = jobs.some(j => j.status !== 'done' && j.stage !== 'failed')
  useEffect(() => {
    if (!token) return
    const t = setInterval(() => { refresh(); loadMe() }, active ? 2000 : 10000)
    return () => clearInterval(t)
  }, [token, active])

  const upload = async () => {
    const file = fileRef.current.files[0]
    if (!file) return setMsg('Pick an .mp3 or .wav first')
    setBusy(true); setMsg('Requesting upload URL…')
    try {
      const r = await fetch('/api/jobs', {
        method: 'POST', headers: { ...auth, 'Content-Type': 'application/json' },
        body: JSON.stringify({ filename: file.name, stems }),
      })
      const body = await r.json()
      if (!r.ok) throw new Error(body.error || 'API error')
      setMsg('Uploading…')
      const put = await fetch(body.upload_url, {
        method: 'PUT', headers: { 'Content-Type': 'audio/mpeg' }, body: file,
      })
      if (!put.ok) throw new Error('upload failed')
      setMsg(`Uploaded. ${body.credits_left} credits left.`)
      fileRef.current.value = ''
      refresh(); loadMe()
    } catch (e) { setMsg(`Error: ${e.message}`) } finally { setBusy(false) }
  }

  const buy = async (plan) => {
    setBusy(true)
    try {
      const r = await fetch('/api/billing/checkout', {
        method: 'POST', headers: { ...auth, 'Content-Type': 'application/json' },
        body: JSON.stringify({ plan }),
      })
      const b = await r.json()
      setMsg(r.ok ? `Simulated purchase of ${plan}. You now have ${b.credits} credits.` : `Error: ${b.error}`)
      loadMe()
    } finally { setBusy(false) }
  }

  const download = async (id) => {
    const r = await fetch(`/api/jobs/${id}/download`, { headers: auth })
    if (r.ok) window.open((await r.json()).download_url, '_blank')
  }

  if (!token) return <Auth onToken={setToken} />

  const allowed = me?.plan_detail?.stems || [2]
  return (
    <div style={styles.page}>
      <div style={styles.row}>
        <h1 style={{ flex: 1 }}>🎵 SoniCloud</h1>
        {me && <span style={{ color: C.mute, fontSize: 14 }}>{me.email}</span>}
        <button style={styles.btnGhost} onClick={signOut}>Sign out</button>
      </div>

      <div style={styles.testBanner}>
        <b>TEST MODE.</b> Payments below are simulated — no card is collected and no money moves.
      </div>

      {me && (
        <div style={styles.card}>
          <div style={styles.row}>
            <div style={{ flex: 1 }}>
              <div style={{ fontSize: 13, color: C.mute }}>Plan</div>
              <div style={{ fontSize: 20 }}><b>{me.plan_detail?.name || me.plan}</b></div>
            </div>
            <div style={{ flex: 1 }}>
              <div style={{ fontSize: 13, color: C.mute }}>Credits</div>
              <div style={{ fontSize: 20, color: me.credits > 0 ? C.green : C.red }}><b>{me.credits}</b></div>
            </div>
            <div style={{ flex: 2, fontSize: 13, color: C.mute }}>
              Tenant #{me.tenant_id} · your songs are stored under <code>tenants/{me.tenant_id}/</code>
            </div>
          </div>
        </div>
      )}

      <div style={styles.card}>
        <h3>Upload a song</h3>
        <div style={{ display: 'grid', gap: 10 }}>
          <input ref={fileRef} type="file" accept=".mp3,.wav" disabled={busy} />
          <div style={styles.row}>
            <span style={{ fontSize: 14, color: C.mute }}>Separate into:</span>
            {[2, 4, 5].map(n => {
              const ok = allowed.includes(n)
              return (
                <label key={n} style={{ fontSize: 14, opacity: ok ? 1 : .45, cursor: ok ? 'pointer' : 'not-allowed' }}
                       title={ok ? '' : 'Upgrade to unlock'}>
                  <input type="radio" name="stems" disabled={!ok} checked={stems === n}
                         onChange={() => setStems(n)} /> {n} stems{ok ? '' : ' 🔒'}
                </label>
              )
            })}
          </div>
          <div><button style={styles.btn} onClick={upload} disabled={busy || (me && me.credits <= 0)}>
            {busy ? 'Working…' : 'Upload & Split'}
          </button></div>
          {me && me.credits <= 0 && <div style={styles.err}>No credits left — pick a plan below.</div>}
          {msg && <p style={{ fontSize: 14 }}>{msg}</p>}
        </div>
      </div>

      <div style={styles.card}>
        <h3>Plans <span style={{ fontSize: 13, color: C.amber }}>(simulated)</span></h3>
        <div style={styles.planGrid}>
          {Object.entries(plans).map(([key, p]) => (
            <div key={key} style={styles.plan(me?.plan === key)}>
              <div style={{ fontSize: 17 }}><b>{p.name}</b></div>
              <div style={{ fontSize: 22, margin: '4px 0' }}>${p.price_usd}</div>
              <div style={{ fontSize: 13, color: C.mute, minHeight: 40 }}>{p.blurb}</div>
              <button style={styles.btn} disabled={busy} onClick={() => buy(key)}>
                {me?.plan === key ? 'Add credits' : 'Choose'}
              </button>
            </div>
          ))}
        </div>
      </div>

      <div style={styles.card}>
        <h3>Your jobs</h3>
        <table style={styles.table}>
          <thead><tr>
            <th style={styles.th}>#</th><th style={styles.th}>Song</th>
            <th style={styles.th}>Stems</th><th style={styles.th}>Progress</th>
            <th style={styles.th}>Created</th><th style={styles.th}></th>
          </tr></thead>
          <tbody>
            {jobs.map(j => (
              <tr key={j.id}>
                <td style={styles.td}>{j.id}</td>
                <td style={styles.td}>{j.filename}</td>
                <td style={styles.td}>{j.stems}</td>
                <td style={{ ...styles.td, minWidth: 230 }}><StageBar job={j} /></td>
                <td style={styles.td}>{new Date(j.created_at).toLocaleString()}</td>
                <td style={styles.td}>
                  {j.status === 'done' && <button style={styles.btnGhost} onClick={() => download(j.id)}>Download</button>}
                </td>
              </tr>
            ))}
            {jobs.length === 0 && <tr><td style={styles.td} colSpan={6}>No jobs yet.</td></tr>}
          </tbody>
        </table>
      </div>
    </div>
  )
}
