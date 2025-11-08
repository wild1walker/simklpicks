# ===== SimklPicks (IDs-only) unseen recommendations =====
FROM node:20-alpine
WORKDIR /app

# Minimal package.json
RUN cat > package.json <<'EOF'
{
  "name": "simklpicks",
  "version": "1.7.0",
  "type": "module",
  "scripts": { "start": "node src/index.js" },
  "dependencies": { "node-fetch": "^3.3.2" }
}
EOF

RUN npm install --omit=dev
RUN mkdir -p src

# --- Simkl client ---
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

  // --- user data (for seen set) ---
  historyMovies()   { return this._get('/sync/history/movies'); }
  watchlistMovies() { return this._get('/sync/watchlist/movies'); }
  ratingsMovies()   { return this._get('/sync/ratings/movies'); }

  historyShows()    { return this._get('/sync/history/shows'); }
  watchlistShows()  { return this._get('/sync/watchlist/shows'); }
  ratingsShows()    { return this._get('/sync/ratings/shows'); }

  historyAnime()    { return this._get('/sync/history/anime'); }
  watchlistAnime()  { return this._get('/sync/watchlist/anime'); }
  ratingsAnime()    { return this._get('/sync/ratings/anime'); }

  // --- candidate pools (best-effort; tries several endpoints) ---
  // Movies
  async candidatesMovies() {
    const paths = [
      // user-tailored (if available on your account; will return 200/401/404 depending on perms)
      '/movies/recommendations', '/recommendations/movies',
      // fallbacks
      '/movies/trending', '/movies/popular', '/movies/anticipated'
    ];
    return this._firstOk(paths);
  }
  // Series
  async candidatesShows() {
    const paths = [
      '/shows/recommendations', '/recommendations/shows',
      '/shows/trending', '/shows/popular', '/shows/anticipated'
    ];
    return this._firstOk(paths);
  }
  // Anime (Simkl treats anime as shows; include anime-specific fallbacks if present)
  async candidatesAnime() {
    const paths = [
      '/anime/recommendations', '/recommendations/anime',
      '/anime/trending', '/anime/popular',
      // Some APIs return anime mixed with shows:
      '/shows/trending', '/shows/popular'
    ];
    return this._firstOk(paths);
  }

  async _firstOk(paths) {
    for (const p of paths) {
      const r = await this._get(p);
      if (r.ok && r.body) return r;
    }
    return { ok: false, status: 404, statusText: 'No candidate endpoint OK', body: null };
  }
}
EOF

# --- Server (IDs-only metas; unseen filter; dual routes; debug) ---
RUN cat > src/index.js <<'EOF'
import http from 'http';
import { SimklClient } from './simklClient.js';

const PORT = Number(process.env.PORT) || 7769;
const ORDER = (process.env.PREFERRED_ID_ORDER || 'tmdb,tt,tvdb')
  .split(',').map(s => s.trim().toLowerCase()).filter(Boolean);

const manifest = {
  id: 'org.simkl.picks',
  version: '1.7.0',
  name: 'SimklPicks',
  description: 'Unseen recommendations based on your Simkl profile (IDs only; metadata resolved by your other addon)',
  resources: ['catalog'],
  types: ['movie','series'],
  idPrefixes: ['tt','tmdb','tvdb'],
  catalogs: [
    { type: 'series', id: 'simklpicks.recommended-series', name: 'Simkl Picks • Recommended Series (Unseen)' },
    { type: 'movie',  id: 'simklpicks.recommended-movies', name: 'Simkl Picks • Recommended Movies (Unseen)' },
    { type: 'series', id: 'simklpicks.recommended-anime',  name: 'Simkl Picks • Recommended Anime (Unseen)' }
  ]
};

const simkl = new SimklClient({
  apiKey: process.env.SIMKL_API_KEY,
  accessToken: process.env.SIMKL_ACCESS_TOKEN
});

// ---- id helpers ----
function chooseIdByOrder(idsObj = {}) {
  for (const key of ORDER) {
    if (key === 'tt' || key === 'imdb') {
      if (idsObj.imdb) return String(idsObj.imdb).startsWith('tt') ? idsObj.imdb : `tt${idsObj.imdb}`;
    } else if (key === 'tmdb' && idsObj.tmdb) {
      return `tmdb:${idsObj.tmdb}`;
    } else if (key === 'tvdb' && idsObj.tvdb) {
      return `tvdb:${idsObj.tvdb}`;
    }
  }
  return null;
}

const pickId = (b = {}) => {
  const ids = b.ids || {};
  const chosen = chooseIdByOrder(ids);
  if (chosen) return chosen;
  if (ids.imdb) return String(ids.imdb).startsWith('tt') ? ids.imdb : `tt${ids.imdb}`;
  if (ids.tmdb) return `tmdb:${ids.tmdb}`;
  if (ids.tvdb) return `tvdb:${ids.tvdb}`;
  return b.slug || String(Math.random()).slice(2);
};

// Normalize list bodies from various endpoints
function normalizeListBody(b) {
  if (Array.isArray(b)) return b;
  if (b && Array.isArray(b.movies)) return b.movies;
  if (b && Array.isArray(b.shows))  return b.shows;
  if (b && Array.isArray(b.anime))  return b.anime;
  if (b && Array.isArray(b.items))  return b.items;
  if (b && Array.isArray(b.data))   return b.data;
  return [];
}

// Convert raw item -> meta (IDs-only + type)
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

// Build a set of IDs considered "seen or listed" so we can exclude them
async function buildSeenSet(kind) {
  // kind: 'movie' | 'series' | 'anime'
  const calls =
    kind === 'movie' ? [simkl.historyMovies(), simkl.ratingsMovies(), simkl.watchlistMovies()] :
    kind === 'series' ? [simkl.historyShows(),  simkl.ratingsShows(),  simkl.watchlistShows()]  :
                        [simkl.historyAnime(),  simkl.ratingsAnime(),  simkl.watchlistAnime()];

  const results = await Promise.all(calls);
  const seen = new Set();
  for (const r of results) {
    if (!r.ok) continue;
    const list = normalizeListBody(r.body);
    for (const x of list) {
      const b = x.movie || x.show || x.anime || x || {};
      seen.add(pickId(b));
    }
  }
  return seen;
}

// Get a candidate pool and filter out "seen"
async function getUnseenMetas(kind, limit = 50) {
  const seen = await buildSeenSet(kind);

  // fetch candidates from Simkl (best-effort multi-endpoint)
  const candResp =
    kind === 'movie'  ? await simkl.candidatesMovies() :
    kind === 'series' ? await simkl.candidatesShows()  :
                        await simkl.candidatesAnime();

  if (!candResp.ok) return { metas: [], error: { status: candResp.status, statusText: candResp.statusText } };

  const pool = normalizeListBody(candResp.body);
  const metas = [];
  for (const x of pool) {
    const b = x.movie || x.show || x.anime || x || {};
    const id = pickId(b);
    if (!id || seen.has(id)) continue;  // exclude watched/rated/on any list
    metas.push({ id, type: kind, name: b.title || b.name || 'Untitled' });
    if (metas.length >= limit) break;
  }
  return { metas, error: null };
}

http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url, `http://${req.headers.host}`);
    const parts = url.pathname.split('/').filter(Boolean);

    if (url.pathname === '/' || url.pathname === '/health') {
      res.writeHead(200, { 'Content-Type': 'text/plain' }); return res.end('ok');
    }
    if (url.pathname === '/manifest.json') return sendJson(res, manifest);

    // Debug: auth
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

    // Debug: ids preview
    if (url.pathname === '/ids-preview') {
      const type = (url.searchParams.get('type') || 'movie').toLowerCase();
      const set = await buildSeenSet(type);
      return sendJson(res, { order: ORDER, type, seenCount: set.size, sample: Array.from(set).slice(0, 20) });
    }

    // Catalogs (support /stremio/v1/catalog/... and /catalog/...)
    const isNew = parts[0] === 'stremio' && parts[1] === 'v1' && parts[2] === 'catalog';
    const isOld = parts[0] === 'catalog';
    if (isNew || isOld) {
      const type = isNew ? parts[3] : parts[1];
      const id   = (isNew ? parts[4] : parts[2] || '').replace(/\.json$/i, '');

      let out = { metas: [], error: null };
      if (id === 'simklpicks.recommended-movies' && type === 'movie') {
        out = await getUnseenMetas('movie');
      } else if (id === 'simklpicks.recommended-series' && type === 'series') {
        out = await getUnseenMetas('series');
      } else if (id === 'simklpicks.recommended-anime' && type === 'series') {
        out = await getUnseenMetas('anime');
      }

      if (out.error) return sendJson(res, { metas: [], error: { source: 'simkl', ...out.error } }, 200);
      return sendJson(res, { metas: out.metas }, 200);
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
