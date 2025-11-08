FROM node:20-alpine
WORKDIR /app

RUN cat > package.json <<'EOF'
{
  "name": "simklpicks",
  "version": "2.0.4",
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
      const t = await r.text();
      const body = t ? (()=>{ try { return JSON.parse(t); } catch { return { raw: t }; } })() : null;
      if (!r.ok) return { ok:false, status:r.status, statusText:r.statusText, body, path };
      return { ok:true, body, path };
    } catch (e) {
      return { ok:false, status:0, statusText:String(e?.message||e), body:null, path };
    }
  }

  // seen sources
  historyMovies()   { return this._get('/sync/history/movies'); }
  ratingsMovies()   { return this._get('/sync/ratings/movies'); }
  watchlistMovies() { return this._get('/sync/watchlist/movies'); }

  historyShows()    { return this._get('/sync/history/shows'); }
  ratingsShows()    { return this._get('/sync/ratings/shows'); }
  watchlistShows()  { return this._get('/sync/watchlist/shows'); }

  historyAnime()    { return this._get('/sync/history/anime'); }
  ratingsAnime()    { return this._get('/sync/ratings/anime'); }
  watchlistAnime()  { return this._get('/sync/watchlist/anime'); }

  // candidates with fallbacks (+ optional force)
  async candidatesMovies() {
    const forced = process.env.FORCE_MOVIE_PATH;
    const paths = forced ? [forced] : [
      '/movies/recommendations','/recommendations/movies',
      '/movies/trending','/movies/trending/today',
      '/movies/popular','/movies/anticipated','/movies/top'
    ];
    return this._firstOk(paths);
  }
  async candidatesShows() {
    const forced = process.env.FORCE_SERIES_PATH;
    const paths = forced ? [forced] : [
      '/shows/recommendations','/recommendations/shows',
      '/shows/trending','/shows/trending/today',
      '/shows/popular','/shows/anticipated','/shows/airing','/shows/top',
      '/calendar/episodes/popular','/popular/shows'
    ];
    return this._firstOk(paths);
  }
  async candidatesAnime() {
    const forced = process.env.FORCE_ANIME_PATH;
    const paths = forced ? [forced] : [
      '/anime/recommendations','/recommendations/anime',
      '/anime/trending','/anime/trending/today',
      '/anime/popular','/anime/anticipated','/anime/top',
      // many anime appear in general shows lists
      '/shows/trending','/shows/popular','/shows/top'
    ];
    return this._firstOk(paths);
  }
  async _firstOk(paths) {
    const tried = [];
    for (const p of paths) {
      const r = await this._get(p);
      tried.push({ path:p, ok:r.ok, status:r.status||200 });
      if (r.ok && r.body) return { ...r, tried };
    }
    return { ok:false, status:404, statusText:'No candidate endpoint OK', body:null, tried };
  }
}
EOF

# --- Server ---
RUN cat > src/index.js <<'EOF'
import http from 'http';
import fetch from 'node-fetch';
import { SimklClient } from './simklClient.js';

const PORT = Number(process.env.PORT) || 7769;
const TTL_MIN = Number(process.env.CACHE_TTL_MINUTES || 360);
const EMIT_PLAIN = (process.env.EMIT_PLAIN_IDS ?? '1') === '1';

// aiometadata-friendly defaults: plain TMDB for all unless you override via env
const ORDER_GLOBAL = (process.env.PREFERRED_ID_ORDER || 'tmdb,tt,tvdb')
  .split(',').map(s=>s.trim().toLowerCase()).filter(Boolean);
const ORDER_MOV = (process.env.PREFERRED_ID_ORDER_MOVIE  || 'tmdb,tt,tvdb').split(',').map(s=>s.trim().toLowerCase()).filter(Boolean);
const ORDER_SER = (process.env.PREFERRED_ID_ORDER_SERIES || 'tmdb,tt,tvdb').split(',').map(s=>s.trim().toLowerCase()).filter(Boolean);
const ORDER_ANI = (process.env.PREFERRED_ID_ORDER_ANIME  || 'tmdb,tt,tvdb').split(',').map(s=>s.trim().toLowerCase()).filter(Boolean);
const ORDER = { movie: ORDER_MOV, series: ORDER_SER, anime: ORDER_ANI };

// choose which Simkl lists count as "seen"
const SEEN_SOURCES = (process.env.SEEN_SOURCES || 'history,ratings')
  .split(',').map(s=>s.trim().toLowerCase()).filter(Boolean);

const manifest = {
  id: 'org.simkl.picks',
  version: '2.0.4',
  name: 'SimklPicks (AI)',
  description: 'AI re-ranked unseen recs from your Simkl profile (IDs only; metadata via your other addon)',
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

const cache = new Map();
const k = (kind) => `cat:${kind}`;
const now = () => Date.now();
const expired = (t) => now() > t;

// ----- ID helpers -----
function chooseIdByOrder(idsObj = {}, order) {
  for (const key of order) {
    if ((key === 'tt' || key === 'imdb') && idsObj.imdb) {
      return String(idsObj.imdb).startsWith('tt') ? idsObj.imdb : `tt${idsObj.imdb}`;
    }
    if (key === 'tmdb' && idsObj.tmdb != null) return EMIT_PLAIN ? String(idsObj.tmdb) : `tmdb:${idsObj.tmdb}`;
    if (key === 'tvdb' && idsObj.tvdb != null) return EMIT_PLAIN ? String(idsObj.tvdb) : `tvdb:${idsObj.tvdb}`;
  }
  return null;
}
const pickId = (b = {}, kind) => {
  const ids = b.ids || {};
  const chosen = chooseIdByOrder(ids, ORDER[kind] || ORDER_GLOBAL);
  if (chosen) return chosen;
  if (ids.imdb) return String(ids.imdb).startsWith('tt') ? ids.imdb : `tt${ids.imdb}`;
  if (ids.tmdb != null) return EMIT_PLAIN ? String(ids.tmdb) : `tmdb:${ids.tmdb}`;
  if (ids.tvdb != null) return EMIT_PLAIN ? String(ids.tvdb) : `tvdb:${ids.tvdb}`;
  return b.slug || String(Math.random()).slice(2);
};

// normalize
function norm(b) {
  if (Array.isArray(b)) return b;
  if (b && Array.isArray(b.movies)) return b.movies;
  if (b && Array.isArray(b.shows))  return b.shows;
  if (b && Array.isArray(b.anime))  return b.anime;
  if (b && Array.isArray(b.items))  return b.items;
  if (b && Array.isArray(b.data))   return b.data;
  return [];
}

// seen set per SEEN_SOURCES
async function buildSeen(kind) {
  const wants = new Set(SEEN_SOURCES);
  const calls = [];
  if (kind === 'movie') {
    if (wants.has('history'))  calls.push(simkl.historyMovies());
    if (wants.has('ratings'))  calls.push(simkl.ratingsMovies());
    if (wants.has('watchlist'))calls.push(simkl.watchlistMovies());
  } else if (kind === 'series') {
    if (wants.has('history'))  calls.push(simkl.historyShows());
    if (wants.has('ratings'))  calls.push(simkl.ratingsShows());
    if (wants.has('watchlist'))calls.push(simkl.watchlistShows());
  } else {
    if (wants.has('history'))  calls.push(simkl.historyAnime());
    if (wants.has('ratings'))  calls.push(simkl.ratingsAnime());
    if (wants.has('watchlist'))calls.push(simkl.watchlistAnime());
  }

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

// candidates
async function candidates(kind) {
  return kind === 'movie' ? simkl.candidatesMovies()
       : kind === 'series' ? simkl.candidatesShows()
       : simkl.candidatesAnime();
}

// LLM rank (OpenRouter / OpenAI if configured)
async function llmRank(kind, profile, candList) {
  const want = Math.min(50, candList.length);
  const sys = `You are a movie/TV recommender. Return ONLY a JSON array of up to ${want} objects with keys {id}. No prose.`;
  const user = {
    kind,
    profile,
    candidates: candList.map(c => ({
      id: c.__id,
      title: c.title || c.name || '',
      year: c.year || c.first_aired || '',
      genres: c.genres || c.genre || [],
      rating: c.user_rating || c.rating || ''
    }))
  };
  const hasOR = !!process.env.OPENROUTER_API_KEY;
  const hasOA = !!process.env.OPENAI_API_KEY;

  try {
    if (hasOR) {
      const r = await fetch('https://openrouter.ai/api/v1/chat/completions', {
        method: 'POST',
        headers: { 'Authorization': `Bearer ${process.env.OPENROUTER_API_KEY}`, 'Content-Type': 'application/json' },
        body: JSON.stringify({ model: process.env.LLM_MODEL || 'openrouter/anthropic/claude-3.5-sonnet',
          messages: [{ role: 'system', content: sys }, { role: 'user', content: JSON.stringify(user) }],
          temperature: 0.2, response_format: { type: "json_object" } })
      });
      const j = await r.json().catch(()=>null);
      const content = j?.choices?.[0]?.message?.content || '[]';
      return safeParseIdList(content);
    }
    if (hasOA) {
      const r = await fetch('https://api.openai.com/v1/chat/completions', {
        method: 'POST',
        headers: { 'Authorization': `Bearer ${process.env.OPENAI_API_KEY}`, 'Content-Type': 'application/json' },
        body: JSON.stringify({ model: process.env.LLM_MODEL || 'gpt-4o-mini',
          messages: [{ role: 'system', content: sys }, { role: 'user', content: JSON.stringify(user) }],
          temperature: 0.2, response_format: { type: "json_object" } })
      });
      const j = await r.json().catch(()=>null);
      const content = j?.choices?.[0]?.message?.content || '[]';
      return safeParseIdList(content);
    }
  } catch (_) {}

  return candList.slice(0, want).map(c => c.__id);
}
function safeParseIdList(s) {
  try {
    const j = JSON.parse(s);
    const arr = Array.isArray(j) ? j : (Array.isArray(j.items) ? j.items : []);
    return arr.map(x => x.id).filter(Boolean);
  } catch { return []; }
}

// build catalog
async function buildCatalog(kind) {
  const seen = await buildSeen(kind);
  const candResp = await candidates(kind);
  if (!candResp.ok) return { metas: [], tried: candResp.tried || [], error: { status: candResp.status, statusText: candResp.statusText } };

  let pool = norm(candResp.body).map(x => x.movie || x.show || x.anime || x || {});
  pool = pool.map(b => ({ ...b, __id: pickId(b, kind) })).filter(b => b.__id);
  pool = pool.filter(b => !seen.has(b.__id)); // unseen

  // simple profile for LLM
  const genres = {};
  for (const b of pool.slice(0,80)) {
    for (const gg of Array.isArray(b.genres||b.genre)? (b.genres||b.genre) : String(b.genres||b.genre||'').split(',')) {
      const key = String(gg).trim().toLowerCase(); if (key) genres[key]=(genres[key]||0)+1;
    }
  }
  const profile = { top_genres: Object.entries(genres).sort((a,b)=>b[1]-a[1]).slice(0,8).map(([g,c])=>`${g}(${c})`) };

  const rankedIds = await llmRank(kind, profile, pool.slice(0,120));
  const rankedSet = new Set(rankedIds);
  const ordered = (rankedIds.length ? pool.filter(b => rankedSet.has(b.__id)) : pool).slice(0,50);

  const metas = ordered.map(b => ({ id:b.__id, type:kind, name:b.title||b.name||'Untitled', year:b.year||b.first_aired||undefined }));
  return { metas };
}

// HTTP
function sendJson(res, obj, code=200) {
  const s = JSON.stringify(obj);
  res.writeHead(code, { 'Content-Type': 'application/json; charset=utf-8', 'Access-Control-Allow-Origin': '*', 'Cache-Control': 'no-store' });
  res.end(s);
}

http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url, `http://${req.headers.host}`);
    const parts = url.pathname.split('/').filter(Boolean);

    if (url.pathname === '/' || url.pathname === '/health') { res.writeHead(200, { 'Content-Type': 'text/plain' }); return res.end('ok'); }
    if (url.pathname === '/manifest.json') return sendJson(res, {
      ...${JSON.stringify({})}, // no-op to keep heredoc simple
      ...${'{}'},
      ... ( ()=> ({ ...manifest }) )()
    });
    if (url.pathname === '/refresh') { cache.clear(); return sendJson(res, { ok:true, cleared:true }); }

    // ids preview
    if (url.pathname === '/ids-preview') {
      const kind = (url.searchParams.get('type') || 'movie').toLowerCase();
      const r = await candidates(kind);
      if (!r.ok) return sendJson(res, { error:{ status:r.status, statusText:r.statusText } }, 200);
      const list = norm(r.body).map(x => x.movie||x.show||x.anime||x||{}).slice(0,20);
      return sendJson(res, { type:kind, order:ORDER[kind], emitPlain:EMIT_PLAIN, items:list.map(b => ({ chosen: pickId(b, kind), ids:b.ids||{}, title:b.title||b.name })) });
    }

    // catalogs (new + legacy)
    const isNew = parts[0]==='stremio' && parts[1]==='v1' && parts[2]==='catalog';
    const isOld = parts[0]==='catalog';
    if (isNew || isOld) {
      const type = isNew ? parts[3] : parts[1];
      const id   = (isNew ? parts[4] : parts[2] || '').replace(/\.json$/i, '');
      let kind=null;
      if (id==='simklpicks.recommended-movies' && type==='movie')  kind='movie';
      if (id==='simklpicks.recommended-series' && type==='series') kind='series';
      if (id==='simklpicks.recommended-anime'  && type==='series') kind='anime';
      if (!kind) return sendJson(res, { metas:[] }, 200);

      const C = cache.get(kind);
      if (C && !expired(C.exp)) return sendJson(res, { metas:C.data }, 200);

      const { metas, error } = await buildCatalog(kind);
      if (error) return sendJson(res, { metas:[], error:{ source:'simkl', ...error } }, 200);

      cache.set(kind, { data: metas, exp: Date.now() + TTL_MIN*60*1000 });
      return sendJson(res, { metas }, 200);
    }

    res.writeHead(404, { 'Content-Type': 'text/plain' }); res.end('Not found');
  } catch (e) {
    sendJson(res, { error:{ source:'server', message:String(e?.message||e) } }, 200);
  }
}).listen(PORT, () => {
  console.log(`[SimklPicks] listening on :${PORT}`);
  console.log(`[SimklPicks] manifest: http://localhost:${PORT}/manifest.json`);
});
EOF

ENV PORT=7769
EXPOSE 7769
CMD ["npm","start"]
