import React, { useEffect, useRef, useState } from 'react'

const styles = {
  page: { fontFamily: 'system-ui, sans-serif', maxWidth: 760, margin: '40px auto', padding: '0 16px' },
  card: { border: '1px solid #ddd', borderRadius: 12, padding: 24, marginBottom: 24, boxShadow: '0 1px 4px rgba(0,0,0,.06)' },
  btn: { background: '#4f46e5', color: '#fff', border: 'none', borderRadius: 8, padding: '10px 18px', cursor: 'pointer', fontSize: 15 },
  table: { width: '100%', borderCollapse: 'collapse' },
  th: { textAlign: 'left', borderBottom: '2px solid #eee', padding: 8 },
  td: { borderBottom: '1px solid #f0f0f0', padding: 8 },
  badge: (s) => ({
    padding: '2px 10px', borderRadius: 999, fontSize: 13,
    background: s === 'done' ? '#dcfce7' : '#fef9c3',
    color: s === 'done' ? '#166534' : '#854d0e',
  }),
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

  useEffect(() => {
    refresh()
    const t = setInterval(refresh, 10000)
    return () => clearInterval(t)
  }, [])

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
      setMsg('Uploaded! The AI worker is splitting your song - status updates below.')
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
                <td style={styles.td}><span style={styles.badge(j.status)}>{j.status}</span></td>
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
