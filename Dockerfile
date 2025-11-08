FROM node:20-alpine

WORKDIR /app

# use the single, deterministic archive
COPY app.zip /tmp/app.zip

# unzip and copy the actual project to /app
RUN apk add --no-cache unzip \
 && mkdir -p /app/_unzip \
 && unzip -q /tmp/app.zip -d /app/_unzip \
 && PKG_JSON="$(find /app/_unzip -type f -name package.json | head -n1)" \
 && if [ -z "$PKG_JSON" ]; then echo "package.json not found in zip" && exit 1; fi \
 && PKG_DIR="$(dirname "$PKG_JSON")" \
 && cp -a "$PKG_DIR"/. /app/ \
 && rm -rf /app/_unzip /tmp/app.zip

# HARD PATCH: overwrite src/index.js with a robust server (works across SDK versions)
RUN mkdir -p /app/src \
 && cat > /app/src/index.js <<'EOF'
import 'dotenv/config';
import { addonBuilder } from 'stremio-addon-sdk';
import { SimklClient } from './simklClient.js';
import { buildCatalog } from './buildCatalog.js';
import http from 'http';

const manifest = {
  id: 'org.abraham.simklpicks',
  version: '1.2.1',
  name: 'SimklPicks',
  description: 'Recommendations from your Simkl watchlists & history',
  resources: ['catalog'],
  types: (process.env.TYPES || 'movie,series').split(',').map(s => s.trim()),
  idPrefixes: ['tt', 'tmdb', 'tvdb'],
  catalogs: [
    { type: 'series', id: 'simklpicks.recommended-series', name: 'SimklPicks • Recommended Series' },
    { type: 'movie',  id: 'simklpicks.recommended-movies', name: 'SimklPicks • Recommended Movies' },
    { type: 'series', id: 'simklpicks.recommended-anime',  name: 'SimklPicks • Recommended Anime' }
  ]
};

const builder = addonBuilder(manifest);

const client = new SimklClient({
  apiKey: process.env.SIMKL_API_KEY,
  accessToken: process.env.SIMKL_ACCESS_TOKEN,
  cacheMinutes: parseInt(process.env.CACHE_MINUTES || '30', 10)
});

builder.defineCatalogHandler(async ({ type, id }) => {
  try {
    const metas = await buildCatalog({ client, type, listId: id });
    return { metas };
  } catch (e) {
    console.error('Catalog error', e);
    return { metas: [] };
  }
});

// normalize SDK interface → request handler
const iface = builder.getInterface();
const handler =
  typeof iface === 'function'                 ? iface :
  typeof iface?.middleware === 'function'     ? iface.middleware() :
  typeof iface?.requestHandler === 'function' ? iface.requestHandler :
  null;

if (!handler) {
  throw new Error('Unsupported stremio-addon-sdk interface; no callable handler found.');
}

const port = Number(process.env.PORT) || 7769;

http.createServer((req, res) => {
  const { pathname } = new URL(req.url, `http://${req.headers.host}`);
  if (pathname === '/' || pathname === '/health' || pathname === '/_health') {
    res.writeHead(200, { 'Content-Type': 'text/plain' });
    res.end('ok');
    return;
  }
  res.setHeader('Access-Control-Allow-Origin', '*');
  handler(req, res);
}).listen(port, () => {
  console.log(`[SimklPicks] listening on :${port}`);
  console.log(`[SimklPicks] manifest: http://localhost:${port}/manifest.json`);
});
EOF

# install deps; if SDK version fails, pin latest and retry
RUN set -eux; \
    if ! npm install --omit=dev; then \
      LATEST="$(npm view stremio-addon-sdk version)"; \
      npm pkg set dependencies.stremio-addon-sdk="$LATEST"; \
      npm install --omit=dev; \
    fi

ENV PORT=7769
EXPOSE 7769
CMD ["npm","start"]
