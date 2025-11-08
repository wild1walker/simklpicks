# ===== SimklPicks: hardened build (no SDK, direct /stremio/v1 routes) =====
FROM node:20-alpine
WORKDIR /app

RUN cat > package.json <<'EOF'
{
  "name": "simklpicks",
  "version": "1.5.1",
  "type": "module",
  "scripts": { "start": "node src/index.js" },
  "dependencies": { "node-fetch": "^3.3.2" }
}
EOF

RUN npm install --omit=dev
RUN mkdir -p src

# ---- Simkl client with safe error handling ----
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
      // Simkl user endpoints expect Bearer
      ...(this.accessToken ? { 'Authorization': `Bearer ${this.accessToken}` } : {})
    };
  }
  async _get(path) {
    try {
      const r = await fetch(this.base + path, { headers: this.headers() });
      const text = await r.text();
      const body = text ? (() => { try { return JSON.parse(text); } catch { return { raw: text }; } })() : null;
      if (!r.ok) {
        return { ok: false, status: r.status, statusText: r.statusText, body };
      }
      return { ok: true, body: Array.isArray(body) ? body : (body || []) };
    } catch (e) {
      return { ok: false, status: 0, statusText: String(e?.message || e), body: null };
    }
  }
  historyMovies()   { return this._get('/sync/history/movies'); }
  watchlistMovies() { return this._get('/sync/watchlist/movies'); }
  ratingsMovies()   { return this._get('/sync/ratings/movies'); }
  historyShows()    { return this._get('/sync/history/shows'); }
  watchlistShows()  { return this._get('/sync/watchlist/shows'); }
  ratingsShows()    { return this._get('/sync/ratings/shows'); }
  historyAnime()    { return this._get('/sync/history/anime'); }
  watchlistAnime()  { return this._get('/sync/watchlist/anime'); }
  ratingsAnime()    { return this._get('/sync/ratings/anime'); }
}
EOF

# ---- Minimal server with robust debug + catalogs ----
RUN cat > src/index.js <<'EOF'
import http from 'http';
import { SimklClient } from './simklClient.js';

const PORT = Number(process.env.PORT) || 7769;

const manifest = {
  id: 'org.simkl.picks',
  version: '1.5.1',
  name: 'SimklPicks',
  description: 'Recommendations based on your Simkl watchlists/history',
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

const pickId = (b={}) => {
  const ids = b.ids || {};
  if (ids.imdb) return String(ids.imdb).startsWith('tt') ? ids.imdb : `tt${ids.imdb}`;
  if (ids.tmdb) return `tmdb:${ids.tmdb}`;
  if (ids.tvdb) return `tvdb:${ids.tvdb}`;
  return b.slug || String(Math.random()).slice(2);
};
const toMeta = (x) => {
  const b = x.movie || x.show || x.anime || x || {};
  return {
    id: pickId(b),
    type: b.type === 'movie' ? 'movie' : 'series',
    name: b.title || b.name || 'Untitled',
    poster: b.poster || b.image || undefined,
    posterShape: 'poster',
    year: b.year
  };
};

function sendJson(res, obj, code=200) {
  const s = JSON.stringify(obj);
  res.writeHead(code, {
    'Content-Type': 'application/json; charset=utf-8',
    'Access-Control-Allow-Origin': '*',
    'Cache-Control': 'no-store'
  });
  res.end(s);
}

async function safeList(callPromise) {
  const r = await callPromise;
  if (!r.ok) return { metas: [], error: r };
  const list = Array.isArray(r.body) ? r.body : [];
  return { metas: list.map(toMeta).slice(0,50), error: null };
}

http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url, `http://${req.headers.host}`);
    const parts = url.pathname.split('/').filter(Boolean);

    if (url.pathname === '/' || url.pathname === '/health') {
      res.writeHead(200, {'Content-Type':'text/plain'}); return res.end('ok');
    }
    if (url.pathname === '/manifest.json') return sendJson(res, manifest);

    // Strong auth debug: NEVER throws; shows whether we're sending Bearer, and first failing endpoint
    if (url.pathname === '/debug-auth') {
      const authHasBearer = (process.env.SIMKL_ACCESS_TOKEN || '').startsWith('Bearer ');
      const test = await simkl.watchlistMovies();
      return sendJson(res, {
        ok: !!process.env.SIMKL_API_KEY && !!process.env.SIMKL_ACCESS_TOKEN && test.ok,
        hasApiKey: !!process.env.SIMKL_API_KEY,
        hasAccessToken: !!process.env.SIMKL_ACCESS_TOKEN,
        accessTokenLooksBearerPrefixed: authHasBearer,
        testCall: test.ok ? { ok:true, count:Array.isArray(test.body)?test.body.length:0 } :
                            { ok:false, status:test.status, statusText:test.statusText, body:test.body }
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
        out[fn] = r.ok ? (Array.isArray(r.body)?r.body.length:0) :
                         { status:r.status, statusText:r.statusText, body:r.body };
      }
      return sendJson(res, out);
    }

    // Serve Stremio paths directly: /stremio/v1/catalog/<type>/<id>.json
    if (parts[0] === 'stremio' && parts[1] === 'v1' && parts[2] === 'catalog') {
      const type = parts[3];
      const id = (parts[4] || '').replace(/\.json$/i, '');

      let result = { metas: [], error: null };
      if (id === 'simklpicks.recommended-movies' && type === 'movie') {
        result = await safeList(simkl.watchlistMovies());
        if (!result.metas.length && !result.error) result = await safeList(simkl.ratingsMovies());
        if (!result.metas.length && !result.error) result = await safeList(simkl.historyMovies());
      } else if (id === 'simklpicks.recommended-series' && type === 'series') {
        result = await safeList(simkl.watchlistShows());
        if (!result.metas.length && !result.error) result = await safeList(simkl.ratingsShows());
        if (!result.metas.length && !result.error) result = await safeList(simkl.historyShows());
      } else if (id === 'simklpicks.recommended-anime' && type === 'series') {
        result = await safeList(simkl.watchlistAnime());
        if (!result.metas.length && !result.error) result = await safeList(simkl.ratingsAnime());
        if (!result.metas.length && !result.error) result = await safeList(simkl.historyAnime());
      }

      if (result.error && result.error.status) {
        // Surface Simkl error to Stremio so you see status instead of generic 500
        return sendJson(res, { metas: [], error: { source:'simkl', ...result.error } }, 200);
      }
      return sendJson(res, { metas: result.metas }, 200);
    }

    res.writeHead(404, {'Content-Type':'text/plain'}); res.end('Not found');
  } catch (e) {
    sendJson(res, { error: { source:'server', message: String(e?.message || e) } }, 200);
  }
}).listen(PORT, () => {
  console.log(`[SimklPicks] listening on :${PORT}`);
  console.log(`[SimklPicks] manifest: http://localhost:${PORT}/manifest.json`);
});
EOF

ENV PORT=7769
EXPOSE 7769
CMD ["npm","start"]
