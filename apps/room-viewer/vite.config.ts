import { resolve } from 'node:path';
import { defineConfig } from 'vite';

const app = import.meta.dirname;
const repository = resolve(app, '../..');

export default defineConfig({
  root: app,
  base: process.env.VIEWER_BASE || '/',
  optimizeDeps: { include: ['three/addons/objects/Reflector.js'] },
  publicDir: resolve(repository, 'data/web-assets'),
  server: {
    host: '127.0.0.1', port: 5188, strictPort: true, fs: { allow: [repository] },
    // Render evidence is output, not application source. Publishing a preview
    // image must not reload every viewer/capture in the middle of a build.
    watch: { ignored: ['**/data/captures/**', '**/data/recordings/**', '**/data/web-assets/office-v4/live/**'] },
  },
  build: {
    outDir: resolve(app, 'dist'),
    rolldownOptions: {
      input: {
        main: resolve(app, 'index.html'),
        play: resolve(app, 'play.html'),
        capture: resolve(app, 'tools/capture.html'),
        inspect: resolve(app, 'inspect.html'),
      },
    },
  },
});
