import react from '@vitejs/plugin-react'
import { defineConfig } from 'vite'

// 产物由 Fastify @fastify/static 托管——单域,免 CORS(p0 §0 / 07 §4)
export default defineConfig({
  plugins: [react()],
})
