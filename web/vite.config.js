import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

export default defineConfig({
  plugins: [react()],
  server: {
    // local dev only: proxy API calls to a locally running Flask
    proxy: { '/api': 'http://localhost:5000' }
  }
})
