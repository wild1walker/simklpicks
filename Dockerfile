# ---- Self-contained SimklPicks build (no zip, no SDK) ----
FROM node:20-alpine
WORKDIR /app

# Create package.json with minimal deps
RUN cat > package.json <<'EOF'
{
  "name": "simklpicks",
  "version": "1.3.0",
  "description": "Personalized Stremio recommendations based on Simkl history and watchlists",
  "type": "module",
  "main": "src/index.js",
  "scripts": { "start": "node src/index.js" },
  "dependencies": {
    "dotenv": "^16.4.5",
    "node-fetch": "^3.3.2"
  }
}
EOF

RUN npm install --omit=dev
RUN mkdir -p /app/src

# ---- src/index.js ----
RUN cat > /app/src/index.js <<'EOF'
import 'dotenv/config';
import http from 'http';
import { SimklClient } from './simklClient.js';
import { buildCatalog } from './buildCatalog.js';

const manifest = {
  id: 'org.abraham.simklpicks',
  version: '1.3.0',
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
console.log(`[SimklPicks] EXCLUDE_HISTORY=${process.env.EXCLUDE_HISTORY ?? 'true'} EXCLUDE_RATED=${process.env.EXCLUDE_RATED ?? 'true'}`);

http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url, `http://${req.headers.host}`);
    const parts = url.pathname.split('/').filter(Boolean);

    if (['/', '/health', '/_health'].includes(url.pathname)) {
      res.writeHead(200, { 'Content-Type': 'text/plain', 'Access-Control-Allow-Origin': '*' });
      return res.end('ok');
    }
    if (url.pathname === '/manifest.json') return sendJson(res, manifest);

    // Debug endpoint
    if (url.pathname === '/debug') {
      const out = {};
      for (const fn of ['historyMovies','watchlistMovies','ratingsMovies','historyShows','watchlistShows','ratingsShows','historyAnime','watchlistAnime','ratingsAnime']) {
        try { const data = await client[fn](); out[fn] = data.length; } 
        catch (e) { out[fn] = 'ERR ' + e.message; }
      }
      return sendJson(res, out);
    }

    // Catalogs
    if (parts[0] === 'catalog') {
      const type = parts[1];
      const id = (parts[2] || '').replace(/\.json$/i, '');
      if (!type || !id) return notFound(res);
      const metas = await buildCatalog({ client, type, listId: id });
      return sendJson(res, { metas });
    }

    notFound(res);
  } catch (err) {
    console.error('Server error:', err);
    sendJson(res, { error: 'internal' }, 500);
  }
}).listen(port, () => {
  console.log(`[SimklPicks] listening on :${port}`);
  console.log(`[SimklPicks] manifest: http://localhost:${port}/manifest.json`);
});
EOF

# ---- src/simklClient.js ----
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
    if (!res.ok) throw new Error(`${res.status} ${res.statusText}`);
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

# ---- src/scorer.js ----
RUN cat > /app/src/scorer.js <<'EOF'
export function buildUserProfile({ history }) {
  const genres = new Map();
  for (const item of history || []) {
    const base = item.show || item.movie || item.anime || item;
    for (const g of base?.genres || []) genres.set(g, (genres.get(g) || 0) + 1);
  }
  const total = [...genres.values()].reduce((a,b)=>a+b,0) || 1;
  const affinity = {};
  for (const [g,c] of genres.entries()) affinity[g] = c / total;
  return { affinity };
}
function genreAffinityScore(affinity, itemGenres) {
  if (!itemGenres?.length) return 0;
  let s = 0; for (const g of itemGenres) s += (affinity[g] || 0);
  return Math.min(1, s / itemGenres.length);
}
export function scoreItem({ item, inWatchlist, profile }) {
  const rating = (item.ratings?.rating || 0) / 10;
  const genreScore = genreAffinityScore(profile.affinity || {}, item.genres);
  const boost = inWatchlist ? 0.3 : 0;
  return rating * 0.6 + genreScore * 0.4 + boost;
}
export function normalizeTopN(items, n=50) {
  return items.sort((a,b)=>b.score-a.score).slice(0,n);
}
EOF

# ---- src/buildCatalog.js ----
RUN cat > /app/src/buildCatalog.js <<'EOF'
import { buildUserProfile, scoreItem, normalizeTopN } from './scorer.js';
const EXCLUDE_HISTORY = String(process.env.EXCLUDE_HISTORY ?? 'true') === 'true';
const EXCLUDE_RATED   = String(process.env.EXCLUDE_RATED   ?? 'true') === 'true';

function toMetaPreview(simklItem, prefer) {
  const base = simklItem?.[prefer] || simklItem?.show || simklItem?.movie || simklItem?.anime || simklItem || {};
  const ids = base.ids || {};
  const imdb = ids.imdb && ids.imdb.startsWith('tt') ? ids.imdb : (ids.imdb ? `tt${ids.imdb}` : null);
  const id = imdb || (ids.tmdb ? `tmdb:${ids.tmdb}` : (ids.tvdb ? `tvdb:${ids.tvdb}` : (base.slug || base.title)));
  return { id, name: base.title || base.name || 'Unknown', poster: base.poster || base.image, posterShape:'poster', year: base.year, genres: base.genres || [], ratings: base.ratings || {} };
}
function uniqueById(arr){const s=new Set();const o=[];for(const i of arr){if(i?.id&&!s.has(i.id)){s.add(i.id);o.push(i);}}return o;}
function idSet(list){const s=new Set();for(const x of list)if(x?.id)s.add(x.id);return s;}

export async function buildCatalog({ client, type, listId }) {
  const isAnime = listId === 'simklpicks.recommended-anime';
  const preferKey = isAnime ? 'anime' : (type === 'movie' ? 'movie' : 'show');

  let historyRaw=[], watchlistRaw=[], ratingsRaw=[];
  try { historyRaw   = isAnime ? await client.historyAnime()   : type==='movie'?await client.historyMovies()   : await client.historyShows(); } catch {}
  try { watchlistRaw = isAnime ? await client.watchlistAnime() : type==='movie'?await client.watchlistMovies() : await client.watchlistShows(); } catch {}
  try { ratingsRaw   = isAnime ? await client.ratingsAnime()   : type==='movie'?await client.ratingsMovies()   : await client.ratingsShows(); } catch {}

  const historyItems   = (historyRaw||[]).map(x=>toMetaPreview(x,preferKey));
  const watchlistItems = (watchlistRaw||[]).map(x=>toMetaPreview(x,preferKey));
  const ratingsItems   = (ratingsRaw||[]).map(x=>toMetaPreview(x,preferKey));

  const seen = EXCLUDE_HISTORY ? idSet(historyItems) : new Set();
  const rated= EXCLUDE_RATED   ? idSet(ratingsItems) : new Set();

  let pool = uniqueById([...watchlistItems,...ratingsItems]).filter(i=>!seen.has(i.id)&&!rated.has(i.id));
  if(pool.length<25){const lenient=uniqueById([...watchlistItems,...ratingsItems,...historyItems]).filter(i=>!seen.has(i.id)&&!rated.has(i.id));if(lenient.length>pool.length)pool=lenient;}
  if(!pool.length)return [];

  const profile=buildUserProfile({history:historyRaw});
  const scored=pool.map(i=>({...i,score:scoreItem({item:i,inWatchlist:watchlistItems.find(w=>w.id===i.id),profile})}));
  return normalizeTopN(scored,50);
}
EOF

# Runtime env
ENV PORT=7769
EXPOSE 7769
CMD ["npm","start"]
