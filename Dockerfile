# ===== SimklPicks (IDs-only) : dual routes + normalizer + debug =====
FROM node:20-alpine
WORKDIR /app

# --- Minimal package.json (ESM + node-fetch) ---
RUN cat > package.json <<'EOF'
{
  "name": "simklpicks",
  "version": "1.5.5",
  "type": "module",
  "scripts": { "start": "node src/index.js" },
  "dependencies": { "node-fetch": "^3.3.2" }
}
EOF

RUN npm install --omit=dev
RUN mkdir -p src

# --- Simkl client (safe errors, Bearer auth header built from SIMKL_ACCESS_TOKEN) ---
RUN cat > src/simklClient.js <<'EOF'
import fetch from 'node-fetch';

export class SimklClient {
  constructor({ apiKey, accessToken }) {
    this.apiKey = apiKey || '';
    this.accessToken = accessToken || '';
    this.base = 'https://api.simkl.com';
  }
  headers() {
    return {
      'Accept': 'application/json',
      'Content-Type': 'application/json',
      'simkl-api-key': this.apiKey,
      ...(this.accessToken ? { 'Authorization': `Bearer ${this.accessToken}` } : {})
    };
  }
  async _get(path) {
    try {
      const r = await fetch(this.base + path, { headers: this.headers() });
      const text = await r.text();
      const body = text ? (() => { try { return JSON.parse(text); } catch { return { raw: text }; } })() : null;
      if (!r.ok) return { ok: false, status: r.status, statusText: r.statusText, body };
      return { ok: true, body };
    } catch (e) {
      return { ok: false, status: 0, statusText: String(e?.message || e), body: null };
    }
  }
  // Movies
  historyMovies()   { return this._get('/sync/history/movies'); }
  watchlistMovies() { return this._get('/sync/watchlist/movies'); }
  ratingsMovies()   { return this._get('/sync/ratings/movies'); }
  // Series
  historyShows()    { return this._get('/sync/history/shows'); }
  watchlistShows()  { return this._get('/sync/watchlist/shows'); }
  ratingsShows()    { return this._get('/sync/ratings/shows'); }
  // Anime (series)
  historyAnime()    { return this._get('/sync/history/anime'); }
  watchlistAnime()  { return this._get('/sync/watchlist/anime'); }
  ratingsAnime()    { return this._get('/sync/ratings/anime'); }
}
EOF

# --- Server (IDs-only metas; lets your metadata addon resolve posters/titles) ---
RUN cat > src/index.js <<'EOF'
import http from 'http';
import { SimklClient } from './simklClient.js';

const PORT = Number(process.env.PORT) || 7769;

const manifest = {
  id: 'org.simkl.picks',
  version: '1.5.5',
  name: 'SimklPicks',
  description: 'Recommendations based on your Simkl watchlists/history (IDs only; metadata resolved by your other addon)',
  resources: ['catalog'],
  types: ['movie','series'],
  idPrefixes: ['tt','tmdb','tvdb'],
  catalogs: [
    { type: 'series', id: 'simklpicks.recommended-series', name: 'Simkl Picks • Recommended Series' },
    { type: 'movie',  id: 'simklpicks.recommended-movies', name: 'Simkl Picks • Recommended Movies' },
    { type: 'series', id: 'simklpicks.recommended-anime',  name: 'Simkl Picks • Recommended Anime' }
  ]
};

const simkl = new SimklClient({
  apiKey: process.env.SIMKL_API_KEY,
  accessToken: process.env.SIMKL_ACCESS_TOKEN
});

// ---- helpers ----
// Prefer IMDb (tt…), else TMDB/TVDB, else slug
const pickId = (b = {}) => {
  const ids = b.ids || {};
  if (ids.imdb) return String(ids.imdb).startsWith('tt') ? ids.imdb : `tt${ids.imdb}`;
  if (ids.tmdb) return `tmdb:${ids.tmdb}`;
  if (ids.tvdb) return `tvdb:${ids.tvdb}`;
  return b.slug || String(Math.random()).slice(2);
};

// Minimal metas (id + type; optional name kept for UX but your metadata addon will override)
const toMeta = (x, forcedType) => {
  const b = x.movie || x.show || x.anime || x || {};
  return {
    id: pickId(b),
    type: forcedType,
    name: b.title || b.name || 'Untitled'
  };
};

function sendJson(res, obj, code = 200) {
  const s = JSON.stringify(obj);
  res.writeHead(code, {
    'Content-Type': 'application/json; charset=utf-8',
    'Access-Control-Allow-Origin': '*',
    'Cache-Control': 'no-store'
  });
  res.end(s);
}

// Normalize Simkl response shapes (some endpoints return {movies:[...]}, etc.)
function normalizeListBody(b) {
  if (Array.isArray(b)) return b;
  if (b && Array.isArray(b.movies)) return b.movies;
  if (b && Array.isArray(b.shows))  return b.shows;
  if (b && Array.isArray(b.anime))  return b.anime;
  if (b && Array.isArray(b.items))  return b.items;
  if (b && Array.isArray(b.data))   return b.data;
  return [];
}

async function safeList(callPromise, forcedType) {
  const r = await callPromise;
  if (!r.ok) return { metas: [], error: r };
  const list = normalizeListBody(r.body);
  return { metas: list.map(x => toMeta(x, forcedType)).slice(0, 50), error: null };
}

http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url, `http://${req.headers.host}`);
    const parts = url.pathname.split('/').filter(Boolean);

    if (url.pathname === '/' || url.pathname === '/health') {
      res.writeHead(200, { 'Content-Type': 'text/plain' }); return res.end('ok');
    }
    if (url.pathname === '/manifest.json') return sendJson(res, manifest);

    // Debug endpoints
    if (url.pathname === '/debug-auth') {
      const test = await simkl.watchlistMovies();
      return sendJson(res, {
        ok: !!process.env.SIMKL_API_KEY && !!process.env.SIMKL_ACCESS_TOKEN && test.ok,
        hasApiKey: !!process.env.SIMKL_API_KEY,
        hasAccessToken: !!process.env.SIMKL_ACCESS_TOKEN,
        testCall: test.ok
          ? { ok: true, count: normalizeListBody(test.body).length }
          : { ok: false, status: test.status, statusText: test.statusText, body: test.body }
      });
    }

    if (url.pathname === '/debug') {
      const fns = [
        'historyMovies','watchlistMovies','ratingsMovies',
        'historyShows','watchlistShows','ratingsShows',
        'historyAnime','watchlistAnime','ratingsAnime'
      ];
      const out = {};
      for (const fn of fns) {
        const r = await simkl[fn]();
        out[fn] = r.ok ? normalizeListBody(r.body).length
                       : { status: r.status, statusText: r.statusText, body: r.body };
      }
      return sendJson(res, out);
    }

    // ---- Catalog routes (support both new and legacy paths) ----
    // /stremio/v1/catalog/<type>/<id>.json  OR  /catalog/<type>/<id>.json
    const isNew = parts[0] === 'stremio' && parts[1] === 'v1' && parts[2] === 'catalog';
    const isOld = parts[0] === 'catalog';
    if (isNew || isOld) {
      const type = isNew ? parts[3] : parts[1];
      const id   = (isNew ? parts[4] : parts[2] || '').replace(/\.json$/i, '');

      let result = { metas: [], error: null };

      if (id === 'simklpicks.recommended-movies' && type === 'movie') {
        result = await safeList(simkl.watchlistMovies(), 'movie');
        if (!result.metas.length && !result.error) result = await safeList(simkl.ratingsMovies(), 'movie');
        if (!result.metas.length && !result.error) result = await safeList(simkl.historyMovies(), 'movie');
      } else if (id === 'simklpicks.recommended-series' && type === 'series') {
        result = await safeList(simkl.watchlistShows(), 'series');
        if (!result.metas.length && !result.error) result = await safeList(simkl.ratingsShows(), 'series');
        if (!result.metas.length && !result.error) result = await safeList(simkl.historyShows(), 'series');
      } else if (id === 'simklpicks.recommended-anime' && type === 'series') {
        result = await safeList(simkl.watchlistAnime(), 'series');
        if (!result.metas.length && !result.error) result = await safeList(simkl.ratingsAnime(), 'series');
        if (!result.metas.length && !result.error) result = await safeList(simkl.historyAnime(), 'series');
      }

      if (result.error && result.error.status) {
        return sendJson(res, { metas: [], error: { source: 'simkl', ...result.error } }, 200);
      }
      return sendJson(res, { metas: result.metas }, 200);
    }

    res.writeHead(404, { 'Content-Type': 'text/plain' }); res.end('Not found');
  } catch (e) {
    sendJson(res, { error: { source: 'server', message: String(e?.message || e) } }, 200);
  }
}).listen(PORT, () => {
  console.log(`[SimklPicks] listening on :${PORT}`);
  console.log(`[SimklPicks] manifest: http://localhost:${PORT}/manifest.json`);
});
EOF

ENV PORT=7769
EXPOSE 7769
CMD ["npm","start"]
