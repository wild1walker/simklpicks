# ===== SimklPicks + LLM re-ranker (aiopicks-style) =====
FROM node:20-alpine
WORKDIR /app

# Minimal package.json
RUN cat > package.json <<'EOF'
{
  "name": "simklpicks",
  "version": "2.0.0",
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

  // Seen sources
  historyMovies()   { return this._get('/sync/history/movies'); }
  watchlistMovies() { return this._get('/sync/watchlist/movies'); }
  ratingsMovies()   { return this._get('/sync/ratings/movies'); }

  historyShows()    { return this._get('/sync/history/shows'); }
  watchlistShows()  { return this._get('/sync/watchlist/shows'); }
  ratingsShows()    { return this._get('/sync/ratings/shows'); }

  historyAnime()    { return this._get('/sync/history/anime'); }
  watchlistAnime()  { return this._get('/sync/watchlist/anime'); }
  ratingsAnime()    { return this._get('/sync/ratings/anime'); }

  // Candidate pools (best-effort)
  async candidatesMovies() { return this._firstOk(['/movies/recommendations','/recommendations/movies','/movies/trending','/movies/popular','/movies/anticipated']); }
  async candidatesShows()  { return this._firstOk(['/shows/recommendations','/recommendations/shows','/shows/trending','/shows/popular','/shows/anticipated']); }
  async candidatesAnime()  { return this._firstOk(['/anime/recommendations','/recommendations/anime','/anime/trending','/anime/popular','/shows/trending']); }

  async _firstOk(paths) {
    for (const p of paths) {
      const r = await this._get(p);
      if (r.ok && r.body) return r;
    }
    return { ok: false, status: 404, statusText: 'No candidate endpoint OK', body: null };
  }
}
EOF

# --- Server with LLM ranking & caching ---
RUN cat > src/index.js <<'EOF'
import http from 'http';
import fetch from 'node-fetch';
import { SimklClient } from './simklClient.js';

const PORT = Number(process.env.PORT) || 7769;
const ORDER_GLOBAL = (process.env.PREFERRED_ID_ORDER || 'tmdb,tt,tvdb')
  .split(',').map(s => s.trim().toLowerCase()).filter(Boolean);
const TTL_MIN = Number(process.env.CACHE_TTL_MINUTES || 360);

// Optional per-type order
const ORDER_MOV = (process.env.PREFERRED_ID_ORDER_MOVIE  || '').split(',').map(s=>s.trim().toLowerCase()).filter(Boolean);
const ORDER_SER = (process.env.PREFERRED_ID_ORDER_SERIES || '').split(',').map(s=>s.trim().toLowerCase()).filter(Boolean);
const ORDER_ANI = (process.env.PREFERRED_ID_ORDER_ANIME  || '').split(',').map(s=>s.trim().toLowerCase()).filter(Boolean);
const ORDER = {
  movie:  ORDER_MOV.length ? ORDER_MOV : ORDER_GLOBAL,
  series: ORDER_SER.length ? ORDER_SER : ORDER_GLOBAL,
  anime:  ORDER_ANI.length ? ORDER_ANI : ORDER_GLOBAL
};

const manifest = {
  id: 'org.simkl.picks',
  version: '2.0.0',
  name: 'SimklPicks (AI)',
  description: 'AI re-ranked unseen recommendations from your Simkl profile (IDs only; metadata via your other addon)',
  resources: ['catalog'],
  types: ['movie','series'],
  idPrefixes: ['tt','tmdb','tvdb'],
  catalogs: [
    { type: 'series', id: 'simklpicks.recommended-series', name: 'Simkl Picks • Series (AI, unseen)' },
    { type: 'movie',  id: 'simklpicks.recommended-movies', name: 'Simkl Picks • Movies (AI, unseen)' },
    { type: 'series', id: 'simklpicks.recommended-anime',  name: 'Simkl Picks • Anime (AI, unseen)' }
  ]
};

const simkl = new SimklClient({
  apiKey: process.env.SIMKL_API_KEY,
  accessToken: process.env.SIMKL_ACCESS_TOKEN
});

// --- tiny in-memory cache ---
const cache = new Map();
const k = (kind) => `cat:${kind}`;
const now = () => Date.now();
const expired = (t) => now() > t;

// ---- ID helpers ----
function chooseIdByOrder(idsObj = {}, order) {
  for (const key of order) {
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
const pickId = (b = {}, kind) => {
  const ids = b.ids || {};
  const chosen = chooseIdByOrder(ids, ORDER[kind] || ORDER_GLOBAL);
  if (chosen) return chosen;
  if (ids.imdb) return String(ids.imdb).startsWith('tt') ? ids.imdb : `tt${ids.imdb}`;
  if (ids.tmdb) return `tmdb:${ids.tmdb}`;
  if (ids.tvdb) return `tvdb:${ids.tvdb}`;
  return b.slug || String(Math.random()).slice(2);
};

// Normalize Simkl list shapes
function norm(b) {
  if (Array.isArray(b)) return b;
  if (b && Array.isArray(b.movies)) return b.movies;
  if (b && Array.isArray(b.shows))  return b.shows;
  if (b && Array.isArray(b.anime))  return b.anime;
  if (b && Array.isArray(b.items))  return b.items;
  if (b && Array.isArray(b.data))   return b.data;
  return [];
}

// Build seen set (watched/rated/on any list)
async function buildSeen(kind) {
  const calls =
    kind === 'movie'  ? [simkl.historyMovies(), simkl.ratingsMovies(), simkl.watchlistMovies()] :
    kind === 'series' ? [simkl.historyShows(),  simkl.ratingsShows(),  simkl.watchlistShows()]  :
                        [simkl.historyAnime(),  simkl.ratingsAnime(),  simkl.watchlistAnime()];
  const res = await Promise.all(calls);
  const S = new Set();
  for (const r of res) if (r.ok) {
    for (const x of norm(r.body)) {
      const b = x.movie || x.show || x.anime || x || {};
      const id = pickId(b, kind);
      if (id) S.add(id);
    }
  }
  return S;
}

// Get candidates by kind
async function candidates(kind) {
  const r = kind === 'movie' ? await simkl.candidatesMovies()
          : kind === 'series' ? await simkl.candidatesShows()
          : await simkl.candidatesAnime();
  if (!r.ok) return [];
  return norm(r.body).map(x => x.movie || x.show || x.anime || x || {});
}

// Make a compact profile summary from seen (genres/titles)
function compactProfile(sample) {
  const titles = [];
  const genres = {};
  for (const b of sample) {
    if (b.title || b.name) titles.push((b.title || b.name).slice(0,60));
    const g = b.genres || b.genre || [];
    for (const gg of Array.isArray(g) ? g : String(g).split(',')) {
      const key = String(gg).trim().toLowerCase();
      if (!key) continue;
      genres[key] = (genres[key] || 0) + 1;
    }
  }
  const topGenres = Object.entries(genres).sort((a,b)=>b[1]-a[1]).slice(0,8).map(([g,c])=>`${g}(${c})`);
  return {
    liked_titles_sample: titles.slice(0, 40),
    top_genres: topGenres
  };
}

// Call LLM via OpenRouter or OpenAI
async function llmRank(kind, profile, candList) {
  const model = process.env.LLM_MODEL || 'openrouter/anthropic/claude-3.5-sonnet';
  const want = Math.min(50, candList.length);
  const sys = `You are a movie/TV recommender. Return ONLY a JSON array of up to ${want} objects with keys {id} based on "fit for user". No prose. Do not include duplicates. IDs are provided.`;
  const user = {
    kind,
    profile,
    candidates: candList.map(c => ({
      id: c.__id,
      title: c.title || c.name || '',
      year: c.year || c.first_aired || '',
      genres: c.genres || c.genre || [],
      rating: c.user_rating || c.rating || '',
    }))
  };

  // Try OpenRouter first
  if (process.env.OPENROUTER_API_KEY) {
    const r = await fetch('https://openrouter.ai/api/v1/chat/completions', {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${process.env.OPENROUTER_API_KEY}`,
        'Content-Type': 'application/json'
      },
      body: JSON.stringify({
        model,
        messages: [
          { role: 'system', content: sys },
          { role: 'user', content: JSON.stringify(user) }
        ],
        temperature: 0.2,
        response_format: { type: "json_object" }
      })
    });
    const j = await r.json().catch(()=>null);
    const content = j?.choices?.[0]?.message?.content || '[]';
    return safeParseIdList(content);
  }

  // Fallback: OpenAI
  if (process.env.OPENAI_API_KEY) {
    const mdl = process.env.LLM_MODEL || 'gpt-4o-mini';
    const r = await fetch('https://api.openai.com/v1/chat/completions', {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${process.env.OPENAI_API_KEY}`,
        'Content-Type': 'application/json'
      },
      body: JSON.stringify({
        model: mdl,
        messages: [
          { role: 'system', content: sys },
          { role: 'user', content: JSON.stringify(user) }
        ],
        temperature: 0.2,
        response_format: { type: "json_object" }
      })
    });
    const j = await r.json().catch(()=>null);
    const content = j?.choices?.[0]?.message?.content || '[]';
    return safeParseIdList(content);
  }

  // If no key set, fall back to simple heuristic: return first N
  return candList.slice(0, want).map(c => c.__id);
}

function safeParseIdList(s) {
  try {
    const j = JSON.parse(s);
    const arr = Array.isArray(j) ? j : (Array.isArray(j.items) ? j.items : []);
    return arr.map(x => x.id).filter(Boolean);
  } catch { return []; }
}

// Build one catalog (kind: movie|series|anime)
async function buildCatalog(kind) {
  const seen = await buildSeen(kind);
  // candidates
  let pool = await candidates(kind);
  // tag each with emitted ID and drop ones without an ID
  pool = pool.map(b => ({ ...b, __id: pickId(b, kind) })).filter(b => b.__id);
  // unseen filter
  pool = pool.filter(b => !seen.has(b.__id));
  // Thin payload to send to LLM
  const sampleForProfile = pool.slice(0, 80);
  const profile = compactProfile(sampleForProfile);
  const rankedIds = await llmRank(kind, profile, pool.slice(0, 120));
  const rankedSet = new Set(rankedIds);
  const ordered = (rankedIds.length ? pool.filter(b => rankedSet.has(b.__id))
                                    : pool).slice(0, 50);

  // Emit IDs-only metas
  return ordered.map(b => ({ id: b.__id, type: kind, name: b.title || b.name || 'Untitled' }));
}

// HTTP helpers
function sendJson(res, obj, code = 200) {
  const s = JSON.stringify(obj);
  res.writeHead(code, {
    'Content-Type': 'application/json; charset=utf-8',
    'Access-Control-Allow-Origin': '*',
    'Cache-Control': 'no-store'
  });
  res.end(s);
}

http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url, `http://${req.headers.host}`);
    const parts = url.pathname.split('/').filter(Boolean);

    if (url.pathname === '/' || url.pathname === '/health') {
      res.writeHead(200, { 'Content-Type': 'text/plain' }); return res.end('ok');
    }
    if (url.pathname === '/manifest.json') return sendJson(res, manifest);

    // Manual refresh (rebuild caches now)
    if (url.pathname === '/refresh') {
      cache.delete(k('movie')); cache.delete(k('series')); cache.delete(k('anime'));
      return sendJson(res, { ok: true, cleared: true });
    }

    // IDs preview for troubleshooting
    if (url.pathname === '/ids-preview') {
      const kind = (url.searchParams.get('type') || 'movie').toLowerCase();
      const pool = await candidates(kind);
      const sample = pool.slice(0, 20).map(b => ({ chosen: pickId(b, kind), ids: b.ids || {}, title: b.title || b.name }));
      return sendJson(res, { order: ORDER[kind] || ORDER_GLOBAL, type: kind, items: sample });
    }

    // debug counts (seen sizes)
    if (url.pathname === '/debug') {
      const [m,s,a] = await Promise.all([buildSeen('movie'), buildSeen('series'), buildSeen('anime')]);
      return sendJson(res, { seen: { movies: m.size, series: s.size, anime: a.size } });
    }

    // Catalog routes (new + legacy)
    const isNew = parts[0] === 'stremio' && parts[1] === 'v1' && parts[2] === 'catalog';
    const isOld = parts[0] === 'catalog';
    if (isNew || isOld) {
      const type = isNew ? parts[3] : parts[1];
      const id   = (isNew ? parts[4] : parts[2] || '').replace(/\.json$/i, '');

      let kind = null;
      if (id === 'simklpicks.recommended-movies'  && type === 'movie')  kind = 'movie';
      if (id === 'simklpicks.recommended-series'  && type === 'series') kind = 'series';
      if (id === 'simklpicks.recommended-anime'   && type === 'series') kind = 'anime';

      if (!kind) return sendJson(res, { metas: [] }, 200);

      // Cache
      const C = cache.get(k(kind));
      if (C && !expired(C.exp)) return sendJson(res, { metas: C.data }, 200);

      const metas = await buildCatalog(kind);
      cache.set(k(kind), { data: metas, exp: now() + TTL_MIN*60*1000 });
      return sendJson(res, { metas }, 200);
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
