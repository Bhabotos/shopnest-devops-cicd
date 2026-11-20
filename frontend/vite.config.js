import react from '@vitejs/plugin-react';
import { defineConfig } from 'vite';

export default defineConfig({
  plugins: [react()],
  server: {
    // Local development: forward API calls to the backend on its loopback port.
    proxy: { '/api': 'http://127.0.0.1:3100' },
  },
  test: {
    environment: 'jsdom',
    setupFiles: ['./test/setup.js'],
  },
});
