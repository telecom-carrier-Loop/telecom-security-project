import react from '@vitejs/plugin-react'
import { defineConfig } from 'vite'

// 개인 개발: /api 요청을 Flask(5000)로 넘긴다. 브라우저는 항상 상대 경로 /api 만 사용한다.
// (로컬 Compose·공용 PC에서는 Nginx가 같은 역할을 한다)
export default defineConfig({
  plugins: [react()],
  server: {
    port: 5173,
    // changeOrigin: false → 브라우저 주소(Host)를 그대로 넘긴다. Flask의 로그인 Origin 검사가 같은 출처로 판단하도록.
    proxy: { '/api': { target: 'http://127.0.0.1:5000', changeOrigin: false } },
  },
})
