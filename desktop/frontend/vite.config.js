import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import { fileURLToPath, URL } from 'node:url';

export default defineConfig({
  plugins: [react()],
  base: './',
  build: {
    outDir: fileURLToPath(new URL('../bin/ui', import.meta.url)),
    emptyOutDir: true,
    sourcemap: false,
  },
  test: {
    include: ['src/**/*.{test,spec}.{js,jsx,ts,tsx}'],
    environment: 'jsdom',
    setupFiles: './src/test-setup.js',
    globals: true,
  },
});
