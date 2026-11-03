import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import { fileURLToPath, URL } from 'node:url';

export default defineConfig({
  plugins: [react()],
  base: './',
  build: {
    // A frontend-only build must never update the installed native bundle.
    outDir: fileURLToPath(new URL('../obj/ui', import.meta.url)),
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
