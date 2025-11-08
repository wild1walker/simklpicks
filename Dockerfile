# ===== SimklPicks: no-SDK, direct /stremio/v1 routes =====
FROM node:20-alpine
WORKDIR /app

RUN cat > package.json <<'EOF'
{
  "name": "simklpicks",
  "version": "1.5.0",
  "type": "module",
  "scripts": { "start": "node src/index.js" },
  "dependencies": {
    "node-fetch": "^3.3.2"
  }
}
EOF

RUN npm install --omit=dev
RUN mkdir -p src

# ---- Simkl client (Bearer auth) ----
RUN cat > src/simklClient.js <<'EOF'
import fetch from 'node-fetch';

export class SimklClient {
  constructor({ apiKey, accessToken }) {
    this.apiKey = apiKey;
    this.accessToken = accessToken;
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
  async get(path) {
    const r = await fetch(this.base + path, { headers: this.headers() });
    const text = await r.text();
    if (!r.ok) throw new Error(`SIMKL ${r.status} ${r.statusText}: ${text.slice(0,200)}`);
    return text ? JSON.parse(text) : [];
  }
  historyMovies()   { return this.get('/sync/history/movies'); }
  watchlistMovies() { return this.get('/sync/watchlist/movies'); }
  ratingsMovies()   { return this.get('/sync/ratings/movies'); }
  historyShows()    { return this.get('/sync/history/shows'); }
  watchlistShows()  { return this.get('/sync/watchlist/shows'); }
  ratingsShows()    { return this.get('/sync/ratings/shows'); }
  historyAnime()    { return this.get('/sync/history/anime'); }
  watchlistAnime()  { return this.get('/sync/watchlist/anime'); }
  ratingsAnime()    { return this.get('/sync/ratings/anime'); }
}
EOF

# ---- Minimal server serving Stremio paths ----
RUN cat > src/index.js <<'EOF'
import http from 'http';
import { SimklClient } from './simklClient.js';

const PORT = Number(process.env.PORT) || 7769;

const manifest = {
  id: 'org.simkl.picks',
  version: '1.5.0',
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

async function handleCatalog(type, id) {
  if (id === 'simklpicks.recommended-movies' && type === 'movie') {
    const wl = await simkl.watchlistMovies(); if (wl?.length) return wl.map(toMeta).slice(0,50);
    const rt = await simkl.ratingsMovies();  if (rt?.length) return rt.map(toMeta).slice(0,50);
    const hi = await simkl.historyMovies();  return (hi||[]).map(toMeta).slice(0,50);
  }
  if (id === 'simklpicks.recommended-series' && type === 'series') {
    const wl = await simkl.watchlistShows(); if (wl?.length) return wl.map(toMeta).slice(0,50);
    const rt = await simkl.ratingsShows();  if (rt?.length) return rt.map(toMeta).slice(0,50);
    const hi = await simkl.historyShows();  return (hi||[]).map(toMeta).slice(0,50);
  }
  if (id === 'simklpicks.recommended-anime' && type === 'series') {
    const wl = await simkl.watchlistAnime(); if (wl?.length) return wl.map(toMeta).slice(0,50);
    const rt = await simkl.ratingsAnime();  if (rt?.length) return rt.map(toMeta).slice(0,50);
    const hi = await simkl.historyAnime();  return (hi||[]).map(toMeta).slice(0,50);
  }
  return [];
}

http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url, `http://${req.headers.host}`);
    const parts = url.pathname.split('/').filter(Boolean);

    if (url.pathname === '/' || url.pathname === '/health') {
      res.writeHead(200, { 'Content-Type': 'text/plain' });
      return res.end('ok');
    }

    if (url.pathname === '/manifest.json') return sendJson(res, manifest);

    // serve the exact Stremio SDK paths, but manually
    // /stremio/v1/catalog/<type>/<id>.json
    if (parts[0] === 'stremio' && parts[1] === 'v1' && parts[2] === 'catalog') {
      const type = parts[3];
      const id = (parts[4] || '').replace(/\.json$/i, '');
      const metas = await handleCatalog(type, id);
      return sendJson(res, { metas });
    }

    // quick auth+count checks
    if (url.pathname === '/debug-auth') {
      const hasApiKey = !!process.env.SIMKL_API_KEY;
      const hasAccess = !!process.env.SIMKL_ACCESS_TOKEN;
      return sendJson(res, { ok: hasApiKey && hasAccess, hasApiKey, hasAccessToken: hasAccess });
    }
    if (url.pathname === '/debug') {
      const out = {};
      const calls = [
        'historyMovies','watchlistMovies','ratingsMovies',
        'historyShows','watchlistShows','ratingsShows',
        'historyAnime','watchlistAnime','ratingsAnime'
      ];
      for (const fn of calls) {
        try { const d = await simkl[fn](); out[fn] = Array.isArray(d) ? d.length : 0; }
        catch (e) { out[fn] = 'ERR ' + (e.message||String(e)); }
      }
      return sendJson(res, out);
    }

    res.writeHead(404, { 'Content-Type': 'text/plain' });
    res.end('Not found');
  } catch (e) {
    console.error(e);
    sendJson(res, { error: 'internal' }, 500);
  }
}).listen(PORT, () => {
  console.log(`[SimklPicks] listening on :${PORT}`);
  console.log(`[SimklPicks] manifest: http://localhost:${PORT}/manifest.json`);
});
EOF

ENV PORT=7769
EXPOSE 7769
CMD ["npm","start"]
