import React, { useEffect, useRef, useState } from 'react'
import './styles.css'

const TOKEN_KEY = 'sonicloud.idToken'
const STAGES = ['queued', 'downloading', 'separating', 'packaging', 'uploading', 'done']

// Stem colours follow DAW convention, so a producer reads them without a legend.
const STEM_SETS = {
  2: [['Vocals', 'var(--vocals)'], ['Accompaniment', 'var(--other)']],
  4: [['Vocals', 'var(--vocals)'], ['Drums', 'var(--drums)'], ['Bass', 'var(--bass)'], ['Other', 'var(--other)']],
  5: [['Vocals', 'var(--vocals)'], ['Drums', 'var(--drums)'], ['Bass', 'var(--bass)'], ['Piano', '#7dd3fc'], ['Other', 'var(--other)']],
}

const row = (gap = 12) => ({ display: 'flex', alignItems: 'center', gap, flexWrap: 'wrap' })
const dim = { color: 'var(--text-dim)' }
const mute = { color: 'var(--text-mute)' }
const label = { fontSize: 11, letterSpacing: '.09em', textTransform: 'uppercase', color: 'var(--text-mute)' }

/* A waveform, not a spinner: this is an audio tool, and it animates only when
   something is actually running. */
function Wave({ live = false, bars = 34 }) {
  const heights = React.useMemo(
    () => Array.from({ length: bars }, (_, i) => 24 + Math.abs(Math.sin(i * 1.7)) * 22), [bars])
  return (
    <div className={`wave${live ? '' : ' idle'}`} aria-hidden="true">
      {heights.map((h, i) => (
        <i key={i} style={{ height: h, animationDelay: `${(i % 11) * 0.09}s` }} />
      ))}
    </div>
  )
}

/* Progress as a level meter — the visual language of the room this tool lives in. */
function Meter({ percent, state, segments = 22 }) {
  const lit = Math.round((percent / 100) * segments)
  return (
    <div className={`meter${state === 'run' ? ' live' : ''}`}>
      {Array.from({ length: segments }, (_, i) => {
        const on = i < lit
        const hot = on && i >= segments - 4 && state !== 'done'
        return (
          <b key={i}
             className={state === 'fail' ? '' : on ? (hot ? 'hot' : 'on') : ''}
             style={{
               height: `${38 + (i % 5) * 14}%`,
               background: state === 'fail' && on ? 'var(--danger)' : undefined,
             }} />
        )
      })}
    </div>
  )
}

function StageBar({ job }) {
  const failed = job.stage === 'failed'
  const finished = job.stage === 'done' || job.status === 'done'
  const pct = failed ? 100 : (job.percent ?? (finished ? 100 : 5))
  const state = failed ? 'fail' : finished ? 'done' : 'run'
  const idx = STAGES.indexOf(job.stage || (finished ? 'done' : 'queued'))
  return (
    <div style={{ minWidth: 250 }}>
      <div style={{ ...row(8), marginBottom: 7 }}>
        <span className={`pill ${failed ? 'fail' : finished ? 'done' : 'run'}`}>
          {job.stage_label || job.status}
        </span>
        {!finished && !failed && (
          <span className="mono" style={{ ...mute, fontSize: 12 }}>
            {idx < 0 ? 0 : Math.max(0, idx)}/{STAGES.length - 1}
          </span>
        )}
        {job.elapsed_seconds != null && (
          <span className="mono" style={{ ...mute, fontSize: 12 }}>
            {Math.round(job.elapsed_seconds)}s
          </span>
        )}
      </div>
      <Meter percent={pct} state={state} />
      {job.stage_detail && (
        <div style={{ ...mute, fontSize: 12, marginTop: 7 }}>{job.stage_detail}</div>
      )}
    </div>
  )
}

function StemChips({ n }) {
  return (
    <div style={row(6)}>
      {(STEM_SETS[n] || []).map(([name, colour]) => (
        <span className="stemchip" key={name}><s style={{ background: colour }} />{name}</span>
      ))}
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
    <div style={{ maxWidth: 460, margin: '0 auto', padding: '72px 20px' }}>
      <div style={{ textAlign: 'center', marginBottom: 26 }}>
        <div style={{ display: 'flex', justifyContent: 'center', marginBottom: 18 }}><Wave live bars={40} /></div>
        <h1 style={{ fontSize: 36, margin: '0 0 8px', letterSpacing: '-.02em' }}>SoniCloud</h1>
        <p style={{ ...dim, margin: 0, fontSize: 15 }}>
          Split any track into its stems. Vocals, drums, bass — isolated in about a minute.
        </p>
      </div>

      <div className="panel">
        <div style={{ ...row(), marginBottom: 16 }}>
          <h2 style={{ fontSize: 19, margin: 0, flex: 1 }}>
            {mode === 'login' ? 'Sign in' : 'Create an account'}
          </h2>
          <button className="btn-ghost" onClick={() => { setMode(mode === 'login' ? 'signup' : 'login'); setErr('') }}>
            {mode === 'login' ? 'Sign up' : 'Sign in'}
          </button>
        </div>
        <div style={{ display: 'grid', gap: 11 }}>
          <input className="field" placeholder="you@studio.com" value={email}
                 onChange={e => setEmail(e.target.value)} onKeyDown={e => e.key === 'Enter' && submit()} />
          <input className="field" placeholder="password — 8+ characters, one number" type="password"
                 value={password} onChange={e => setPassword(e.target.value)}
                 onKeyDown={e => e.key === 'Enter' && submit()} />
          {err && <div style={{ color: 'var(--danger)', fontSize: 14 }}>{err}</div>}
          <button className="btn" onClick={submit} disabled={busy}>
            {busy ? 'Working…' : mode === 'login' ? 'Sign in' : 'Create account'}
          </button>
        </div>
      </div>

      <div className="banner">
        <b>Test environment.</b> Accounts here are for testing. Don't reuse a real password.
      </div>
    </div>
  )
}

export default function App() {
  const [token, setToken] = useState(() => localStorage.getItem(TOKEN_KEY) || '')
  const [me, setMe] = useState(null)
  const [jobs, setJobs] = useState([])
  const [stems, setStems] = useState(2)
  const [file, setFile] = useState(null)
  const [busy, setBusy] = useState(false)
  const [msg, setMsg] = useState('')
  const [over, setOver] = useState(false)
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

  useEffect(() => { if (token) { loadMe(); refresh() } }, [token])

  const active = jobs.some(j => j.status !== 'done' && j.stage !== 'failed')
  useEffect(() => {
    if (!token) return
    const t = setInterval(() => { refresh(); loadMe() }, active ? 2000 : 10000)
    return () => clearInterval(t)
  }, [token, active])

  const pick = (f) => {
    if (!f) return
    if (!/\.(mp3|wav)$/i.test(f.name)) return setMsg('Only .mp3 and .wav files')
    setFile(f); setMsg('')
  }

  const upload = async () => {
    if (!file) return setMsg('Choose a track first')
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
      setMsg(`Queued — separating into ${body.stems} stems.`)
      setFile(null); if (fileRef.current) fileRef.current.value = ''
      refresh(); loadMe()
    } catch (e) { setMsg(e.message) } finally { setBusy(false) }
  }

  const download = async (id) => {
    const r = await fetch(`/api/jobs/${id}/download`, { headers: auth })
    if (r.ok) window.open((await r.json()).download_url, '_blank')
  }

  if (!token) return <Auth onToken={setToken} />

  const allowed = [2, 4, 5]

  return (
    <div style={{ maxWidth: 980, margin: '0 auto', padding: '28px 20px 64px' }}>
      <header style={{ ...row(14), marginBottom: 22 }}>
        <Wave live={active} bars={18} />
        <div style={{ flex: 1 }}>
          <h1 style={{ fontSize: 24, margin: 0, letterSpacing: '-.02em' }}>SoniCloud</h1>
          <div style={{ ...mute, fontSize: 12 }}>
            {me?.email} · tenant <span className="mono">#{me?.tenant_id}</span>
          </div>
        </div>
        <button className="btn-ghost" onClick={signOut}>Sign out</button>
      </header>

      <div className="panel">
        <h2 style={{ fontSize: 17, margin: '0 0 14px' }}>New separation</h2>

        <div className={`drop${over ? ' over' : ''}`}
             onClick={() => fileRef.current?.click()}
             onDragOver={e => { e.preventDefault(); setOver(true) }}
             onDragLeave={() => setOver(false)}
             onDrop={e => { e.preventDefault(); setOver(false); pick(e.dataTransfer.files[0]) }}>
          {file ? (
            <>
              <div style={{ fontSize: 16, color: 'var(--text)' }}>{file.name}</div>
              <div className="mono" style={{ ...mute, fontSize: 12, marginTop: 4 }}>
                {(file.size / 1048576).toFixed(1)} MB · click to change
              </div>
            </>
          ) : (
            <>
              <div style={{ fontSize: 15 }}>Drop a track here, or click to browse</div>
              <div style={{ ...mute, fontSize: 12, marginTop: 4 }}>MP3 or WAV</div>
            </>
          )}
        </div>
        <input ref={fileRef} type="file" accept=".mp3,.wav" style={{ display: 'none' }}
               onChange={e => pick(e.target.files[0])} />

        <div style={{ ...label, margin: '20px 0 9px' }}>Separate into</div>
        <div className="stems">
          {[2, 4, 5].map(n => {
            const ok = allowed.includes(n)
            return (
              <div key={n}
                   className={`stem-opt${stems === n ? ' sel' : ''}${ok ? '' : ' locked'}`}
                   onClick={() => ok && setStems(n)}
>
                <div style={{ ...row(8), marginBottom: 8 }}>
                  <span style={{ fontSize: 16, fontWeight: 650 }}>{n} stems</span>
                </div>
                <StemChips n={n} />
              </div>
            )
          })}
        </div>

        <div style={{ ...row(), marginTop: 20 }}>
          <button className="btn" onClick={upload} disabled={busy || !file}>
            {busy ? 'Working…' : 'Split track'}
          </button>
          {msg && <span style={{ ...dim, fontSize: 14 }}>{msg}</span>}
        </div>
      </div>

      <div className="panel">
        <div style={{ ...row(), marginBottom: 6 }}>
          <h2 style={{ fontSize: 17, margin: 0, flex: 1 }}>Your tracks</h2>
          {active && <span style={{ ...mute, fontSize: 12 }}>live · refreshing every 2s</span>}
        </div>
        {jobs.length === 0 ? (
          <div style={{ ...mute, padding: '26px 0', textAlign: 'center' }}>
            Nothing here yet. Your separations will appear as they run.
          </div>
        ) : (
          <table>
            <thead><tr>
              <th style={{ width: 42 }}>#</th><th>Track</th><th style={{ width: 78 }}>Stems</th>
              <th style={{ width: 270 }}>Progress</th><th style={{ width: 110 }}></th>
            </tr></thead>
            <tbody>
              {jobs.map(j => (
                <tr key={j.id}>
                  <td className="mono" style={mute}>{j.id}</td>
                  <td>
                    <div style={{ fontSize: 15 }}>{j.filename}</div>
                    <div className="mono" style={{ ...mute, fontSize: 11, marginTop: 3 }}>
                      {new Date(j.created_at).toLocaleString()}
                    </div>
                  </td>
                  <td className="mono">{j.stems}</td>
                  <td><StageBar job={j} /></td>
                  <td>{j.status === 'done' &&
                    <button className="btn-ghost" onClick={() => download(j.id)}>Download</button>}</td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>

    </div>
  )
}
