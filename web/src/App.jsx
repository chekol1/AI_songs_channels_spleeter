import React, { useEffect, useRef, useState } from 'react'

const styles = {
  page: { fontFamily: 'system-ui, sans-serif', maxWidth: 760, margin: '40px auto', padding: '0 16px' },
  card: { border: '1px solid #ddd', borderRadius: 12, padding: 24, marginBottom: 24, boxShadow: '0 1px 4px rgba(0,0,0,.06)' },
  btn: { background: '#4f46e5', color: '#fff', border: 'none', borderRadius: 8, padding: '10px 18px', cursor: 'pointer', fontSize: 15 },
  table: { width: '100%', borderCollapse: 'collapse' },
  th: { textAlign: 'left', borderBottom: '2px solid #eee', padding: 8 },
  td: { borderBottom: '1px solid #f0f0f0', padding: 8 },
  badge: (s) => ({
    padding: '2px 10px', borderRadius: 999, fontSize: 13, whiteSpace: 'nowrap',
    background: s === 'done' ? '#dcfce7' : s === 'failed' ? '#fee2e2' : '#fef9c3',
    color: s === 'done' ? '#166534' : s === 'failed' ? '#991b1b' : '#854d0e',
  }),
  barOuter: { height: 6, background: '#eee', borderRadius: 999, overflow: 'hidden', marginTop: 6 },
  barInner: (pct, s) => ({
    height: '100%', width: `${pct}%`,
    background: s === 'done' ? '#16a34a' : s === 'failed' ? '#dc2626' : '#4f46e5',
    transition: 'width .6s ease',
  }),
  steps: { display: 'flex', gap: 4, marginTop: 6 },
  step: (state) => ({
    flex: 1, height: 4, borderRadius: 2,
    background: state === 'done' ? '#4f46e5' : state === 'active' ? '#a5b4fc' : '#e5e7eb',
  }),
  detail: { fontSize: 12, color: '#666', marginTop: 4 },
}

// The pipeline the worker walks through, in order.
const STAGES = ['queued', 'downloading', 'separating', 'packaging', 'uploading', 'done']

function StageBar({ job }) {
  const pct = job.percent ?? (job.status === 'done' ? 100 : 5)
  const idx = STAGES.indexOf(job.stage || (job.status === 'done' ? 'done' : 'queued'))
  const failed = job.stage === 'failed'
  return (
    <div>
      <span style={styles.badge(failed ? 'failed' : job.status)}>
        {job.stage_label || job.status}
      </span>
      <div style={styles.barOuter}>
        <div style={styles.barInner(failed ? 100 : pct, failed ? 'failed' : job.status)} />
      </div>
      {!failed && (
        <div style={styles.steps}>
          {STAGES.slice(1).map((s, i) => (
            <div key={s} title={s}
                 style={styles.step(idx > i + 1 ? 'done' : idx === i + 1 ? 'active' : 'todo')} />
          ))}
        </div>
      )}
      {(job.stage_detail || job.elapsed_seconds != null) && (
        <div style={styles.detail}>
          {job.stage_detail}
          {job.elapsed_seconds != null && ` · ${Math.round(job.elapsed_seconds)}s elapsed`}
        </div>
      )}
    </div>
  )
}

export default function App() {
  const [jobs, setJobs] = useState([])
  const [busy, setBusy] = useState(false)
  const [msg, setMsg] = useState('')
  const fileRef = useRef()

  const refresh = async () => {
    try {
      const r = await fetch('/api/jobs')
      if (r.ok) setJobs(await r.json())
    } catch { /* ignore transient errors */ }
  }

  // 10s is far too slow to watch a job move through stages, but polling that
  // fast forever is wasteful -- so speed up only while something is running.
  const active = jobs.some(j => j.status !== 'done' && j.stage !== 'failed')
  useEffect(() => {
    refresh()
    const t = setInterval(refresh, active ? 2000 : 10000)
    return () => clearInterval(t)
  }, [active])

  const upload = async () => {
    const file = fileRef.current.files[0]
    if (!file) return setMsg('Pick an .mp3 or .wav file first')
    setBusy(true)
    setMsg('Requesting upload URL...')
    try {
      const r = await fetch('/api/jobs', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ filename: file.name }),
      })
      if (!r.ok) throw new Error((await r.json()).error || 'API error')
      const { upload_url } = await r.json()
      setMsg('Uploading to S3...')
      const put = await fetch(upload_url, {
        method: 'PUT',
        headers: { 'Content-Type': 'audio/mpeg' },
        body: file,
      })
      if (!put.ok) throw new Error('S3 upload failed')
      setMsg('Uploaded. Progress for each stage is shown below.')
      fileRef.current.value = ''
      refresh()
    } catch (e) {
      setMsg(`Error: ${e.message}`)
    } finally {
      setBusy(false)
    }
  }

  const download = async (id) => {
    const r = await fetch(`/api/jobs/${id}/download`)
    if (r.ok) {
      const { download_url } = await r.json()
      window.open(download_url, '_blank')
    }
  }

  return (
    <div style={styles.page}>
      <h1>🎵 SoniCloud - AI Song Splitter</h1>
      <p>Upload a song, the AI (Spleeter) splits it into vocals + accompaniment stems.</p>

      <div style={styles.card}>
        <h3>Upload a song</h3>
        <input ref={fileRef} type="file" accept=".mp3,.wav" disabled={busy} />
        <button style={styles.btn} onClick={upload} disabled={busy}>
          {busy ? 'Working...' : 'Upload & Split'}
        </button>
        {msg && <p>{msg}</p>}
      </div>

      <div style={styles.card}>
        <h3>Jobs</h3>
        <table style={styles.table}>
          <thead>
            <tr>
              <th style={styles.th}>#</th>
              <th style={styles.th}>Song</th>
              <th style={styles.th}>Status</th>
              <th style={styles.th}>Created</th>
              <th style={styles.th}></th>
            </tr>
          </thead>
          <tbody>
            {jobs.map(j => (
              <tr key={j.id}>
                <td style={styles.td}>{j.id}</td>
                <td style={styles.td}>{j.filename}</td>
                <td style={{ ...styles.td, minWidth: 230 }}><StageBar job={j} /></td>
                <td style={styles.td}>{new Date(j.created_at).toLocaleString()}</td>
                <td style={styles.td}>
                  {j.status === 'done' && (
                    <button style={styles.btn} onClick={() => download(j.id)}>Download stems</button>
                  )}
                </td>
              </tr>
            ))}
            {jobs.length === 0 && (
              <tr><td style={styles.td} colSpan={5}>No jobs yet - upload a song above.</td></tr>
            )}
          </tbody>
        </table>
      </div>
    </div>
  )
}
