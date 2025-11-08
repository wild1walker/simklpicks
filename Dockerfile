FROM node:20-alpine
WORKDIR /app

# --- Minimal package.json ---
RUN cat > package.json <<'EOF'
{
  "name": "simklpicks",
  "version": "2.1.0",
  "type": "module",
  "scripts": { "start": "node src/index.js" },
  "dependencies": {
    "node-fetch": "^3.3.2"
  }
}
EOF

RUN npm install --omit=dev
RUN mkdir -p src

# =========================
#  Simkl Client + Helpers
# =========================
RUN cat > src/simklClient.js <<'EOF'
import fetch from 'node-fetch';

const API = 'https://api.simkl.com';

function headers() {
  const h = {
    'Accept': 'application/json',
    'Content-Type': 'application/json',
    'simkl-api-key': process.env.SIMKL_API_KEY || ''
  };
  // SIMKL expects NO "Bearer " prefix here (your past 401 proved this)
  if (process.env.SIMKL_ACCESS_TOKEN) h['Authorization'] = process.env.SIMKL_ACCESS_TOKEN;
  return h;
}

async function get(path, query = {}) {
  const sp = new URLSearchParams(query);
  const url = API + path + (sp.toString() ? `?${sp}` : '');
  const r = await fetch(url, { headers: headers() });
  const text = await r.text();
  let body = null;
  if (text) { try { body = JSON.parse(text); } catch { body = { raw: text }; } }
  if (!r.ok) throw new Error(`${r.status} ${r.statusText} GET ${path}`);
  return body;
}

// Always ask for extended=full so Simkl returns external ids
const ext = { extended: 'full' };

// Robust external-ID resolver:
// 1) Try Simkl /search/id with simkl ID if present
// 2) Try Simkl /search/movies or /search/shows by title/year
export async function resolveIds(item, kind) {
  if (!item) return item;

  const hasExt =
    (item?.ids?.tmdb != null) ||
    (item?.ids?.tvdb != null) ||
    (item?.ids?.imdb != null);
  if (hasExt) return item;

  const simklId = item?.ids?.simkl ?? item?.simkl_id ?? item?.id;
  const title = item?.title ?? item?.name;
  const year  = item?.year ?? item?.first_aired;

  // 1) lookup by simkl id
  try {
    if (simklId != null) {
      const looked = await get('/search/id', { simkl: simklId });
      if (looked && looked.ids) {
        item.ids = { ...(item.ids||{}), ...looked.ids };
        const ok = item.ids.tmdb != null || item.ids.tvdb != null || item.ids.imdb != null;
        if (ok) return item;
      }
    }
  } catch (_) {}

  // 2) fallback: title/year search
  try {
    if (title) {
      if (kind === 'movie') {
        const res = await get('/search/movies', { q: title, year });
        const hit = Array.isArray(res) ? res[0] : null;
        if (hit?.ids) { item.ids = { ...(item.ids||{}), ...hit.ids }; return item; }
      } else {
        // series and anime live under /search/shows
        const res = await get('/search/shows', { q: title, year });
        const hit = Array.isArray(res) ? res[0] : null;
        if (hit?.ids) { item.ids = { ...(item.ids||{}), ...hit.ids }; return item; }
      }
    }
  } catch (_) {}

  return item;
}

export async function userMovies() {
  const [history, ratings, watchlist] = await Promise.all([
    get('/sync/history/movies', ext).catch(() => []),
    get('/sync/ratings/movies', ext).catch(() => []),
    get('/sync/watchlist/movies', ext).catch(() => [])
  ]);
  return { history, ratings, watchlist };
}

export async function userShows() {
  const [history, ratings, watchlist] = await Promise.all([
    get('/sync/history/shows', ext).catch(() => []),
    get('/sync/ratings/shows', ext).catch(() => []),
    get('/sync/watchlist/shows', ext).catch(() => [])
  ]);
  return { history, ratings, watchlist };
}

// Anime is usually just a flagged subset of shows on Simkl
export async function userAnime() {
  const [history, ratings, watchlist] = await Promise.all([
    get('/sync/history/shows', ext).catch(() => []),
    get('/sync/ratings/shows', ext).catch(() => []),
    get('/sync/watchlist/shows', ext).catch(() => [])
  ]);
  return { history, ratings, watchlist };
}

export async function candidatesMovies() {
  // Try recommendations first, then stable fallbacks
  const paths = [
    ['/movies/recommendations', { limit: 200, extended: 'full' }],
    ['/recommendations/movies', { limit: 200, extended: 'full' }],
    ['/movies/trending',        { extended: 'full' }],
    ['/movies/popular',         { extended: 'full' }],
    ['/movies/top',             { extended: 'full' }]
  ];
  for (const [p,q] of paths) {
    try {
      const res = await get(p, q);
      if (Array.isArray(res) && res.length) return res;
    } catch (_) {}
  }
  return [];
}

export async function candidatesShows() {
  const paths = [
    ['/shows/recommendations', { limit: 200, extended: 'full' }],
    ['/recommendations/shows', { limit: 200, extended: 'full' }],
    ['/shows/trending',        { extended: 'full' }],
    ['/shows/popular',         { extended: 'full' }],
    ['/shows/top',             { extended: 'full' }]
  ];
  for (const [p,q] of paths) {
    try {
      const res = await get(p, q);
      if (Array.isArray(res) && res.length) return res;
    } catch (_) {}
  }
  return [];
}

export async function filterAnimeFromShows(shows) {
  // Accept common anime signals
  return (shows || []).filter(s => {
    const b = s?.show || s || {};
    if (b?.anime === true) return true;
    if (Array.isArray(b?.genres) && b.genres.some(g => String(g).toLowerCase()==='anime')) return true;
    return false;
  });
}
EOF

# =========================
#  Catalog Builder
# =========================
RUN cat > src/buildCatalog.js <<'EOF'
import { resolveIds } from './simklClient.js';

// aiometadata wants:
//   - MOVIES: plain TMDB numeric ID
//   - SERIES/ANIME: plain TVDB numeric ID
function chooseIdForAioMeta(ids, kind) {
  if (!ids) return null;
  if (kind === 'movie') {
    // strict tmdb first; fallbacks only if absolutely necessary
    return (ids.tmdb != null) ? String(ids.tmdb)
         : (ids.imdb != null) ? (String(ids.imdb).startsWith('tt') ? String(ids.imdb) : `tt${ids.imdb}`)
         : (ids.tvdb != null) ? String(ids.tvdb)
         : null;
  }
  // series/anime -> tvdb first
  return (ids.tvdb != null) ? String(ids.tvdb)
       : (ids.tmdb != null) ? String(ids.tmdb)
       : (ids.imdb != null) ? (String(ids.imdb).startsWith('tt') ? String(ids.imdb) : `tt${ids.imdb}`)
       : null;
}

export async function buildMetas(list, kind, { limit = 50 } = {}) {
  const metas = [];
  for (const raw of list) {
    const base = raw?.movie || raw?.show || raw || {};
    const enriched = await resolveIds(base, kind);
    const id = chooseIdForAioMeta(enriched?.ids, kind);
    if (!id) continue;

    metas.push({
      id,
      type: kind === 'anime' ? 'series' : kind,
      name: enriched.title || enriched.name || 'Untitled',
      year: enriched.year || enriched.first_aired || undefined
      // no poster: you delegate posters to aiometadata
    });
    if (metas.length >= limit) break;
  }
  return metas;
}
EOF

# =========================
#  Main Server
# =========================
RUN cat > src/index.js <<'EOF'
import http from 'http';
import fetch from 'node-fetch';
import {
  userMovies, userShows, userAnime,
  candidatesMovies, candidatesShows, filterAnimeFromShows
} from './simklClient.js';
import { buildMetas } from './buildCatalog.js';

const PORT = Number(process.env.PORT) || 7769;
const TTL_MIN = Number(process.env.CACHE_TTL_MINUTES || 360);

// Strict unseen policy (like you asked):
// exclude items found in ANY of: history, ratings, watchlist
const EXCLUDE_SOURCES = new Set((process.env.EXCLUDE_SOURCES || 'history,ratings,watchlist')
  .split(',').map(s=>s.trim().toLowerCase()).filter(Boolean));

// Simple cache
const cache = new Map();
const key = (k)=>`cat:${k}`;
const now = ()=>Date.now();
const expired = (t)=> now() > t;

const manifest = {
  id: 'org.simkl.picks',
  version: '2.1.0',
  name: 'SimklPicks (AI)',
  description: 'AI re-ranked unseen recs from your Simkl profile; emits TMDB ids for movies and TVDB ids for series/anime for aiometadata.',
  resources: ['catalog'],
  types: ['movie','series'],
  idPrefixes: ['tmdb','tvdb','tt'],
  catalogs: [
    { type: 'series', id: 'simklpicks.recommended-series', name: 'Simkl Picks • Series (AI, unseen)' },
    { type: 'movie',  id: 'simklpicks.recommended-movies', name: 'Simkl Picks • Movies (AI, unseen)' },
    { type: 'series', id: 'simklpicks.recommended-anime',  name: 'Simkl Picks • Anime (AI, unseen)' }
  ]
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

function norm(list) {
  if (Array.isArray(list)) return list;
  if (list?.movies) return list.movies;
  if (list?.shows)  return list.shows;
  if (list?.items)  return list.items;
  if (list?.data)   return list.data;
  return [];
}

// Build a simkl id set from a bucket
function toSimklIds(arr) {
  const S = new Set();
  for (const x of arr || []) {
    const b = x?.movie || x?.show || x || {};
    const id = b?.ids?.simkl ?? b?.simkl_id ?? b?.id;
    if (id != null) S.add(String(id));
  }
  return S;
}

async function buildSeen(kind) {
  // Pull your three user buckets for the content type
  const { history, ratings, watchlist } =
    kind === 'movie' ? await userMovies() :
    kind === 'series' ? await userShows() :
                        await userAnime();

  const union = new Set();
  if (EXCLUDE_SOURCES.has('history'))   for (const id of toSimklIds(norm(history)))   union.add(id);
  if (EXCLUDE_SOURCES.has('ratings'))   for (const id of toSimklIds(norm(ratings)))   union.add(id);
  if (EXCLUDE_SOURCES.has('watchlist')) for (const id of toSimklIds(norm(watchlist))) union.add(id);
  return union;
}

async function makeCatalog(kind) {
  // Get raw candidates
  let candidates =
    kind === 'movie'  ? await candidatesMovies() :
    kind === 'series' ? await candidatesShows() :
    await candidatesShows(); // anime from shows

  if (kind === 'anime') candidates = await filterAnimeFromShows(candidates);

  // Build unseen filter by simkl id
  const seen = await buildSeen(kind);
  const unseen = norm(candidates).filter(x => {
    const b = x?.movie || x?.show || x || {};
    const simklId = b?.ids?.simkl ?? b?.simkl_id ?? b?.id;
    return simklId == null ? true : !seen.has(String(simklId));
  });

  // Optional LLM re-rank (kept simple; IDs must stay the same)
  const ranked = await maybeRank(kind, unseen);

  // Convert to Stremio metas with correct external id format
  const metas = await buildMetas(ranked, kind, { limit: 50 });
  return metas;
}

async function maybeRank(kind, arr) {
  const hasOR = !!process.env.OPENROUTER_API_KEY;
  const hasOA = !!process.env.OPENAI_API_KEY;
  if (!hasOR && !hasOA) return arr; // no-op if you didn't configure a model

  const want = Math.min(60, arr.length);
  const sys = `You are a recommender. Return JSON array of up to ${want} objects with key {simkl_id}, no prose.`;
  const user = {
    kind,
    candidates: arr.slice(0, 180).map(x => {
      const b = x?.movie || x?.show || x || {};
      const simklId = b?.ids?.simkl ?? b?.simkl_id ?? b?.id ?? '';
      return {
        simkl_id: String(simklId),
        title: b.title || b.name || '',
        year: b.year || b.first_aired || '',
        genres: b.genres || b.genre || []
      };
    })
  };

  try {
    if (hasOR) {
      const r = await fetch('https://openrouter.ai/api/v1/chat/completions', {
        method: 'POST',
        headers: {
          'Authorization': `Bearer ${process.env.OPENROUTER_API_KEY}`,
          'Content-Type': 'application/json'
        },
        body: JSON.stringify({
          model: process.env.LLM_MODEL || 'openrouter/anthropic/claude-3.5-sonnet',
          messages: [{ role: 'system', content: sys }, { role: 'user', content: JSON.stringify(user) }],
          temperature: 0.2,
          response_format: { type: 'json_object' }
        })
      });
      const j = await r.json().catch(()=>null);
      const content = j?.choices?.[0]?.message?.content || '[]';
      const ids = safeParseSimklIdList(content);
      if (ids.length) {
        const set = new Set(ids.map(String));
        return arr.filter(x => {
          const b = x?.movie || x?.show || x || {};
          const simklId = b?.ids?.simkl ?? b?.simkl_id ?? b?.id;
          return simklId != null && set.has(String(simklId));
        });
      }
    } else if (hasOA) {
      const r = await fetch('https://api.openai.com/v1/chat/completions', {
        method: 'POST',
        headers: {
          'Authorization': `Bearer ${process.env.OPENAI_API_KEY}`,
          'Content-Type': 'application/json'
        },
        body: JSON.stringify({
          model: process.env.LLM_MODEL || 'gpt-4o-mini',
          messages: [{ role: 'system', content: sys }, { role: 'user', content: JSON.stringify(user) }],
          temperature: 0.2,
          response_format: { type: 'json_object' }
        })
      });
      const j = await r.json().catch(()=>null);
      const content = j?.choices?.[0]?.message?.content || '[]';
      const ids = safeParseSimklIdList(content);
      if (ids.length) {
        const set = new Set(ids.map(String));
        return arr.filter(x => {
          const b = x?.movie || x?.show || x || {};
          const simklId = b?.ids?.simkl ?? b?.simkl_id ?? b?.id;
          return simklId != null && set.has(String(simklId));
        });
      }
    }
  } catch (_) {}
  return arr;
}

function safeParseSimklIdList(s) {
  try {
    const j = JSON.parse(s);
    const arr = Array.isArray(j) ? j : (Array.isArray(j.items) ? j.items : []);
    return arr.map(x => x.simkl_id).filter(Boolean);
  } catch { return []; }
}

// ------------- HTTP server & routes -------------
http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url, `http://${req.headers.host}`);
    const parts = url.pathname.split('/').filter(Boolean);

    if (url.pathname === '/' || url.pathname === '/health') {
      res.writeHead(200, { 'Content-Type': 'text/plain' });
      return res.end('ok');
    }

    if (url.pathname === '/manifest.json') return sendJson(res, manifest);

    if (url.pathname === '/env-check') {
      return sendJson(res, {
        ok: true,
        hasApiKey: !!process.env.SIMKL_API_KEY,
        hasAccessToken: !!process.env.SIMKL_ACCESS_TOKEN,
        excludeSources: Array.from(EXCLUDE_SOURCES)
      });
    }

    if (url.pathname === '/refresh') { cache.clear(); return sendJson(res, { ok:true, cleared:true }); }

    if (url.pathname === '/ids-preview') {
      const kind = (url.searchParams.get('type') || 'movie').toLowerCase();
      // Use candidate layer; do not filter or resolve here, just show simkl ids for sanity
      let cands = kind === 'movie' ? await candidatesMovies() : await candidatesShows();
      if (kind === 'anime') cands = await filterAnimeFromShows(cands);
      const items = (cands || []).slice(0, 25).map(x => {
        const b = x?.movie || x?.show || x || {};
        return {
          title: b.title || b.name,
          year: b.year || b.first_aired,
          ids: b.ids || {}
        };
      });
      return sendJson(res, { type: kind, items });
    }

    // Stremio catalog endpoints (new & legacy)
    const isNew = parts[0]==='stremio' && parts[1]==='v1' && parts[2]==='catalog';
    const isOld = parts[0]==='catalog';
    if (isNew || isOld) {
      const type = isNew ? parts[3] : parts[1];
      const id   = (isNew ? parts[4] : parts[2] || '').replace(/\.json$/i, '');
      let kind = null;
      if (id==='simklpicks.recommended-movies'  && type==='movie')  kind='movie';
      if (id==='simklpicks.recommended-series'  && type==='series') kind='series';
      if (id==='simklpicks.recommended-anime'   && type==='series') kind='anime';
      if (!kind) return sendJson(res, { metas: [] }, 200);

      const C = cache.get(kind);
      if (C && !expired(C.exp)) return sendJson(res, { metas: C.data }, 200);

      const metas = await makeCatalog(kind);
      cache.set(kind, { data: metas, exp: Date.now() + TTL_MIN*60*1000 });
      return sendJson(res, { metas }, 200);
    }

    res.writeHead(404, { 'Content-Type': 'text/plain' });
    res.end('Not found');
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
