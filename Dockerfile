# --- Self-contained build; no zip needed ---
FROM node:20-alpine
WORKDIR /app

# package.json without stremio-addon-sdk
RUN cat > package.json <<'EOF'
{
  "name": "simklpicks",
  "version": "1.2.3",
  "description": "Stremio addon: Simkl-powered recommendations (series, movies, anime) — no SDK web layer",
  "type": "module",
  "main": "src/index.js",
  "scripts": {
    "start": "node src/index.js"
  },
  "dependencies": {
    "dotenv": "^16.4.5",
    "node-fetch": "^3.3.2"
  }
}
EOF

RUN npm install --omit=dev

# src files (no stremio-addon-sdk import)
RUN mkdir -p /app/src /app/src/tools

# index.js: minimal HTTP server that implements Stremio endpoints directly
RUN cat > /app/src/index.js <<'EOF'
import 'dotenv/config';
import http from 'http';
import { SimklClient } from './simklClient.js';
import { buildCatalog } from './buildCatalog.js';

const manifest = {
  id: 'org.abraham.simklpicks',
  version: '1.2.3',
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

const client = new SimklClient({
  apiKey: process.env.SIMKL_API_KEY,
  accessToken: process.env.SIMKL_ACCESS_TOKEN,
  cacheMinutes: parseInt(process.env.CACHE_MINUTES || '30', 10)
});

function sendJson(res, obj, code = 200) {
  const data = JSON.stringify(obj);
  res.writeHead(code, {
    'Content-Type': 'application/json; charset=utf-8',
    'Access-Control-Allow-Origin': '*',
    'Cache-Control': 'no-store'
  });
  res.end(data);
}

function notFound(res) {
  res.writeHead(404, { 'Content-Type': 'text/plain', 'Access-Control-Allow-Origin': '*' });
  res.end('Not found');
}

const port = Number(process.env.PORT) || 7769;

http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url, `http://${req.headers.host}`);
    const parts = url.pathname.split('/').filter(Boolean);

    // health/root
    if (url.pathname === '/' || url.pathname === '/health' || url.pathname === '/_health') {
      res.writeHead(200, { 'Content-Type': 'text/plain', 'Access-Control-Allow-Origin': '*' });
      res.end('ok');
      return;
    }

    // manifest
    if (url.pathname === '/manifest.json') {
      return sendJson(res, manifest);
    }

    // catalog: /catalog/{type}/{id}.json (ignore extras)
    if (parts[0] === 'catalog') {
      const type = parts[1];                    // movie | series
      const idWithExt = parts[2] || '';
      if (!type || !idWithExt) return notFound(res);
      const id = idWithExt.replace(/\.json$/i, '');

      try {
        const metas = await buildCatalog({ client, type, listId: id });
        return sendJson(res, { metas });
      } catch (e) {
        console.error('Catalog handler error:', e);
        return sendJson(res, { metas: [] });
      }
    }

    return notFound(res);
  } catch (err) {
    console.error('Server error:', err);
    sendJson(res, { error: 'internal' }, 500);
  }
}).listen(port, () => {
  console.log(`[SimklPicks] listening on :${port}`);
  console.log(`[SimklPicks] manifest: http://localhost:${port}/manifest.json`);
});
EOF

# simklClient.js
RUN cat > /app/src/simklClient.js <<'EOF'
import fetch from 'node-fetch';

export class SimklClient {
  constructor({ apiKey, accessToken, cacheMinutes = 30 }) {
    this.apiKey = apiKey;
    this.accessToken = accessToken;
    this.base = 'https://api.simkl.com';
    this.cacheMs = cacheMinutes * 60 * 1000;
    this.cache = new Map();
  }
  headers() {
    return {
      'Content-Type': 'application/json',
      'simkl-api-key': this.apiKey,
      ...(this.accessToken ? { 'Authorization': `Bearer ${this.accessToken}` } : {})
    };
  }
  async _get(path) {
    const url = `${this.base}${path}`;
    const cached = this.cache.get(url);
    const now = Date.now();
    if (cached && (now - cached.ts) < this.cacheMs) return cached.data;
    const res = await fetch(url, { headers: this.headers() });
    if (!res.ok) throw new Error(`SIMKL GET ${path} failed: ${res.status} ${await res.text()}`);
    const data = await res.json();
    this.cache.set(url, { ts: now, data });
    return data;
  }
  historyMovies()   { return this._get('/sync/history/movies'); }
  historyShows()    { return this._get('/sync/history/shows'); }
  watchlistMovies() { return this._get('/sync/watchlist/movies'); }
  watchlistShows()  { return this._get('/sync/watchlist/shows'); }
  ratingsMovies()   { return this._get('/sync/ratings/movies'); }
  ratingsShows()    { return this._get('/sync/ratings/shows'); }
  historyAnime()    { return this._get('/sync/history/anime'); }
  watchlistAnime()  { return this._get('/sync/watchlist/anime'); }
  ratingsAnime()    { return this._get('/sync/ratings/anime'); }
}
EOF

# scorer.js
RUN cat > /app/src/scorer.js <<'EOF'
export function buildUserProfile({ history }) {
  const genres = new Map();
  for (const item of history || []) {
    const base = item.show || item.movie || item.anime || item;
    const gs = base?.genres || [];
    for (const g of gs) genres.set(g, (genres.get(g) || 0) + 1);
  }
  const total = Array.from(genres.values()).reduce((a,b)=>a+b,0) || 1;
  const affinity = {};
  for (const [g, c] of genres.entries()) affinity[g] = c / total;
  return { affinity };
}
function genreAffinityScore(affinity, itemGenres) {
  if (!itemGenres || !itemGenres.length) return 0;
  let s = 0;
  for (const g of itemGenres) s += (affinity[g] || 0);
  return Math.min(1, s / itemGenres.length);
}
export function scoreItem({ item, inWatchlist, profile }) {
  const genres = item.genres || [];
  const rating = (item.ratings?.rating || 0) / 10;
  const genreScore = genreAffinityScore(profile.affinity || {}, genres);
  const watchlistBoost = inWatchlist ? 0.3 : 0;
  return rating * 0.6 + genreScore * 0.4 + watchlistBoost;
}
export function normalizeTopN(items, topN = 50) {
  return items.sort((a,b)=> b.score - a.score).slice(0, topN);
}
EOF

# buildCatalog.js
RUN cat > /app/src/buildCatalog.js <<'EOF'
import { buildUserProfile, scoreItem, normalizeTopN } from './scorer.js';

function toMetaPreview(simklItem, prefer) {
  const base = simklItem[prefer] || simklItem.show || simklItem.movie || simklItem.anime || simklItem;
  const ids = base?.ids || {};
  const id = ids.imdb || (ids.tmdb ? `tmdb:${ids.tmdb}` : (ids.tvdb ? `tvdb:${ids.tvdb}` : (base?.slug || base?.title)));
  return {
    id,
    name: base?.title || base?.name || base?.show_title || base?.movie_title || 'Unknown',
    poster: base?.poster || base?.image || undefined,
    posterShape: 'poster',
    year: base?.year,
    genres: base?.genres || [],
    ratings: base?.ratings || {}
  };
}
function uniqueById(arr) {
  const seen = new Set(); const out = [];
  for (const it of arr) { if (!it || !it.id) continue; if (seen.has(it.id)) continue; seen.add(it.id); out.push(it); }
  return out;
}
export async function buildCatalog({ client, type, listId }) {
  let historyRaw = [], watchlistRaw = [], ratingsRaw = [], preferKey = type;
  const isAnime = listId === 'simklpicks.recommended-anime';
  if (isAnime) {
    historyRaw = await client.historyAnime();
    watchlistRaw = await client.watchlistAnime();
    ratingsRaw = await client.ratingsAnime();
    preferKey = 'anime';
  } else if (type === 'movie') {
    historyRaw = await client.historyMovies();
    watchlistRaw = await client.watchlistMovies();
    ratingsRaw = await client.ratingsMovies();
    preferKey = 'movie';
  } else {
    historyRaw = await client.historyShows();
    watchlistRaw = await client.watchlistShows();
    ratingsRaw = await client.ratingsShows();
    preferKey = 'show';
  }
  const historyItems = (historyRaw || []).map(x => toMetaPreview(x, preferKey));
  const watchlistItems = (watchlistRaw || []).map(x => toMetaPreview(x, preferKey));
  const watchIds = new Set(watchlistItems.map(i => i.id));
  let pool = uniqueById([...watchlistItems, ...historyItems]);
  if (!isAnime && preferKey === 'movie') {
    const watched = new Set(historyItems.map(i => i.id));
    pool = pool.filter(i => !watched.has(i.id));
  }
  const profile = buildUserProfile({ history: historyRaw });
  const scored = pool.map(item => ({
    ...item,
    score: scoreItem({ item, inWatchlist: watchIds.has(item.id), profile })
  }));
  return normalizeTopN(scored, 50);
}
EOF

ENV PORT=7769
EXPOSE 7769
CMD ["node","src/index.js"]
