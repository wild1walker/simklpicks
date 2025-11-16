FROM node:20-alpine

WORKDIR /app

# --- Write package.json ---
RUN cat <<'EOF' > package.json
{
  "name": "simkl-openrouter-stremio-addon",
  "version": "1.0.0",
  "description": "Stremio addon using Simkl watch history + OpenRouter AI for movie/TV/anime recommendations",
  "main": "server.js",
  "scripts": {
    "start": "node server.js"
  },
  "dependencies": {
    "axios": "^1.7.0",
    "body-parser": "^1.20.0",
    "express": "^4.18.0",
    "stremio-addon-sdk": "^1.6.5",
    "uuid": "^9.0.0"
  }
}
EOF

# --- Write server.js (entire app) ---
RUN cat <<'EOF' > server.js
const express = require("express");
const bodyParser = require("body-parser");
const fs = require("fs");
const path = require("path");
const axios = require("axios");
const { addonBuilder, getInterface } = require("stremio-addon-sdk");
const { v4: uuidv4 } = require("uuid");

const PORT = process.env.PORT || 7000;
const CONFIG_PATH = path.join(__dirname, "config.json");

// -------- CONFIG HELPERS --------

function defaultConfig() {
  return {
    simkl: {
      clientId: "",
      clientSecret: "",
      accessToken: "",
      userId: ""
    },
    openrouter: {
      apiKey: "",
      model: "openrouter/auto",
      systemPrompt: ""
    }
  };
}

function loadConfig() {
  if (!fs.existsSync(CONFIG_PATH)) {
    return defaultConfig();
  }
  try {
    return JSON.parse(fs.readFileSync(CONFIG_PATH, "utf8"));
  } catch (e) {
    console.error("Error reading config.json", e);
    return defaultConfig();
  }
}

function saveConfig(conf) {
  fs.writeFileSync(CONFIG_PATH, JSON.stringify(conf, null, 2), "utf8");
}

let config = loadConfig();

const app = express();
app.use(bodyParser.json());
app.use(express.urlencoded({ extended: true }));

function getBaseUrl(req) {
  const proto = req.headers["x-forwarded-proto"] || req.protocol || "http";
  const host = req.headers.host || `localhost:${PORT}`;
  return `${proto}://${host}`;
}

// -------- INLINE HTML UI --------

const HTML_PAGE = `<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8" />
  <title>Simkl → OpenRouter → Stremio Config</title>
  <style>
    body {
      font-family: system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      max-width: 800px;
      margin: 2rem auto;
      padding: 0 1rem;
    }
    h1, h2 { margin-bottom: 0.5rem; }
    p { margin: 0.25rem 0 0.75rem; }
    label {
      display: block;
      margin-top: 0.75rem;
      font-weight: 600;
    }
    input, textarea, button {
      padding: 0.5rem;
      font-size: 1rem;
      width: 100%;
      box-sizing: border-box;
      margin-top: 0.25rem;
    }
    textarea { min-height: 100px; }
    button { cursor: pointer; }
    .status { margin-top: 0.5rem; font-size: 0.9rem; }
    .ok { color: green; }
    .error { color: red; }
    .inline-help {
      font-size: 0.85rem;
      color: #666;
    }
    code {
      background: #f4f4f4;
      padding: 0.2rem 0.4rem;
      border-radius: 3px;
      display: inline-block;
      word-break: break-all;
    }
    hr { margin: 2rem 0; }
  </style>
</head>
<body>
  <h1>Simkl → OpenRouter → Stremio</h1>
  <p>Configure everything here, then paste the manifest URL into Stremio.</p>

  <!-- MANIFEST URL -->
  <h2>1. Stremio Addon URL</h2>
  <p>Use this in Stremio:</p>
  <p><code id="manifestUrl"></code></p>
  <hr />

  <!-- SIMKL SETTINGS -->
  <h2>2. Simkl App Settings</h2>
  <p class="inline-help">
    Create an app in your Simkl <em>Developer</em> settings, then paste its Client ID and Client Secret here.
  </p>

  <label>Simkl Client ID</label>
  <input type="text" id="simklClientId" placeholder="Your Simkl client_id" />

  <label>Simkl Client Secret</label>
  <input type="password" id="simklClientSecret" placeholder="Your Simkl client_secret" />

  <button id="saveSimkl">Save Simkl Settings</button>
  <div class="status" id="simklSettingsStatus"></div>

  <div style="margin-top: 1rem;">
    <button id="btnSimkl">Connect Simkl (OAuth)</button>
    <div class="status" id="simklStatus"></div>
  </div>

  <hr />

  <!-- OPENROUTER SETTINGS -->
  <h2>3. OpenRouter Settings</h2>

  <label>OpenRouter API Key</label>
  <input type="password" id="orApiKey" placeholder="sk-or-..." />
  <p class="inline-help">
    Saved on the server and hidden on reload. You’ll just see “key is set”.
  </p>

  <label>OpenRouter Model</label>
  <input type="text" id="orModel" placeholder="openrouter/auto" />

  <label>System Prompt (optional)</label>
  <textarea id="orSystemPrompt"
    placeholder="Custom instructions to the AI (leave empty to use the built-in movie/series/anime recommender prompt)"></textarea>

  <button id="saveOr">Save OpenRouter Settings</button>
  <div class="status" id="orStatus"></div>

  <script>
    const base = window.location.origin;
    document.getElementById("manifestUrl").innerText = base + "/manifest.json";

    async function loadConfig() {
      try {
        const res = await fetch("/api/config");
        if (!res.ok) return;
        const data = await res.json();

        if (data.simkl) {
          if (data.simkl.clientId) {
            document.getElementById("simklClientId").value = data.simkl.clientId;
          }
          if (data.simkl.hasToken) {
            document.getElementById("simklStatus").innerHTML =
              '<span class="ok">Simkl connected as ' + (data.simkl.userId || 'your account') + '</span>';
          } else {
            document.getElementById("simklStatus").innerHTML =
              '<span class="inline-help">Simkl not connected yet.</span>';
          }
        }

        if (data.openrouter) {
          if (data.openrouter.model) {
            document.getElementById("orModel").value = data.openrouter.model;
          }
          if (data.openrouter.systemPrompt) {
            document.getElementById("orSystemPrompt").value = data.openrouter.systemPrompt;
          }
          if (data.openrouter.hasKey) {
            document.getElementById("orStatus").innerHTML =
              '<span class="ok">OpenRouter key is set (hidden).</span>';
          }
        }
      } catch (err) {
        console.error(err);
      }
    }

    document.getElementById("saveSimkl").addEventListener("click", async () => {
      const clientId = document.getElementById("simklClientId").value.trim();
      const clientSecret = document.getElementById("simklClientSecret").value.trim();
      const res = await fetch("/api/simkl/settings", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ clientId, clientSecret })
      });
      const data = await res.json();
      if (data.success) {
        document.getElementById("simklSettingsStatus").innerHTML =
          '<span class="ok">Simkl settings saved.</span>';
      } else {
        document.getElementById("simklSettingsStatus").innerHTML =
          '<span class="error">' + (data.error || 'Error saving Simkl settings') + '</span>';
      }
    });

    document.getElementById("btnSimkl").addEventListener("click", async () => {
      const res = await fetch("/api/simkl/connect", { method: "POST" });
      const data = await res.json();
      if (data.authUrl) {
        window.location.href = data.authUrl;
      } else {
        document.getElementById("simklStatus").innerHTML =
          '<span class="error">' + (data.error || 'Error starting Simkl OAuth') + '</span>';
      }
    });

    document.getElementById("saveOr").addEventListener("click", async () => {
      const apiKey = document.getElementById("orApiKey").value.trim();
      const model = document.getElementById("orModel").value.trim();
      const systemPrompt = document.getElementById("orSystemPrompt").value.trim();
      const res = await fetch("/api/openrouter/settings", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ apiKey, model, systemPrompt })
      });
      const data = await res.json();
      if (data.success) {
        document.getElementById("orStatus").innerHTML =
          '<span class="ok">OpenRouter settings saved.</span>';
        document.getElementById("orApiKey").value = "";
      } else {
        document.getElementById("orStatus").innerHTML =
          '<span class="error">' + (data.error || 'Error saving OpenRouter settings') + '</span>';
      }
    });

    loadConfig();
  </script>
</body>
</html>`;

// -------- ROUTES FOR UI --------

app.get("/", (req, res) => {
  res.send(HTML_PAGE);
});

// -------- CONFIG API --------

app.get("/api/config", (req, res) => {
  res.json({
    simkl: {
      clientId: config.simkl.clientId || "",
      hasToken: !!config.simkl.accessToken,
      userId: config.simkl.userId || null
    },
    openrouter: {
      model: config.openrouter.model || "openrouter/auto",
      hasKey: !!config.openrouter.apiKey,
      systemPrompt: config.openrouter.systemPrompt || ""
    }
  });
});

app.post("/api/simkl/settings", (req, res) => {
  const { clientId, clientSecret } = req.body;
  if (!clientId || !clientSecret) {
    return res.status(400).json({ error: "Both clientId and clientSecret are required" });
  }
  config.simkl.clientId = clientId;
  config.simkl.clientSecret = clientSecret;
  saveConfig(config);
  res.json({ success: true });
});

app.post("/api/openrouter/settings", (req, res) => {
  const { apiKey, model, systemPrompt } = req.body;
  if (!config.openrouter) config.openrouter = {};

  if (apiKey) {
    config.openrouter.apiKey = apiKey;
  }
  config.openrouter.model = model || "openrouter/auto";
  config.openrouter.systemPrompt = systemPrompt || "";

  saveConfig(config);
  res.json({ success: true });
});

// -------- SIMKL OAUTH --------

app.post("/api/simkl/connect", (req, res) => {
  if (!config.simkl.clientId || !config.simkl.clientSecret) {
    return res.status(400).json({
      error: "Set Simkl Client ID and Secret in the UI first."
    });
  }

  const state = uuidv4();
  const baseUrl = getBaseUrl(req);
  const redirectUri = `${baseUrl}/api/simkl/callback`;

  const authUrl =
    `https://simkl.com/oauth/authorize` +
    `?response_type=code` +
    `&client_id=${encodeURIComponent(config.simkl.clientId)}` +
    `&redirect_uri=${encodeURIComponent(redirectUri)}` +
    `&state=${encodeURIComponent(state)}`;

  res.json({ authUrl });
});

app.get("/api/simkl/callback", async (req, res) => {
  const code = req.query.code;
  if (!code) {
    return res.status(400).send("Missing code from Simkl.");
  }

  try {
    const baseUrl = getBaseUrl(req);
    const redirectUri = `${baseUrl}/api/simkl/callback`;

    const tokenRes = await axios.post(
      "https://api.simkl.com/oauth/token",
      {
        grant_type: "authorization_code",
        client_id: config.simkl.clientId,
        client_secret: config.simkl.clientSecret,
        redirect_uri: redirectUri,
        code
      },
      { headers: { "Content-Type": "application/json" } }
    );

    const accessToken = tokenRes.data.access_token;
    config.simkl.accessToken = accessToken;

    const profileRes = await axios.get("https://api.simkl.com/users/settings", {
      headers: {
        "Content-Type": "application/json",
        "Authorization": `Bearer ${accessToken}`,
        "simkl-api-key": config.simkl.clientId
      }
    });

    if (profileRes.data?.user?.username) {
      config.simkl.userId = profileRes.data.user.username;
    }

    saveConfig(config);

    // FIXED: no stray backslash before backtick
    res.send(`
      <html>
        <body style="font-family: system-ui, sans-serif;">
          <h1>Simkl Connected ✅</h1>
          <p>You can close this tab and return to the config page.</p>
          <a href="/">Back to config</a>
        </body>
      </html>
    `);
  } catch (e) {
    console.error("Simkl callback error:", e.response?.data || e.message);
    res.status(500).send("Error connecting to Simkl. Check server logs.");
  }
});

// -------- SIMKL FETCH (movie/tv/anime) --------

async function fetchSimklLists() {
  if (!config.simkl.accessToken || !config.simkl.clientId) {
    throw new Error("Simkl not configured or not connected");
  }

  const headers = {
    "Content-Type": "application/json",
    "Authorization": `Bearer ${config.simkl.accessToken}`,
    "simkl-api-key": config.simkl.clientId
  };

  const types = ["movie", "tv", "anime"];
  const statuses = ["completed", "watching"];

  const requests = [];

  for (const type of types) {
    for (const status of statuses) {
      const url =
        `https://api.simkl.com/sync/all-items/${type}/${encodeURIComponent(status)}` +
        `?extended=full&episode_watched_at=yes&memos=yes`;
      requests.push(
        axios.get(url, { headers }).then(r => ({
          type,
          status,
          data: r.data
        }))
      );
    }
  }

  const results = await Promise.all(requests);

  const out = {
    movie: { completed: [], watching: [] },
    tv: { completed: [], watching: [] },
    anime: { completed: [], watching: [] }
  };

  for (const r of results) {
    if (!out[r.type]) out[r.type] = {};
    out[r.type][r.status] = r.data;
  }

  return out;
}

// -------- OPENROUTER AI --------

const defaultSystemPrompt = `
You are an expert movie, TV series, and anime recommender for a Stremio add-on.

The user's viewing history comes from Simkl and is grouped into:
- movie (completed, watching)
- tv (completed, watching)
- anime (completed, watching)

Your job:
1. Analyze the user's taste in MOVIES, TV SERIES, and ANIME.
2. Generate recommendations in THREE separate lanes:
   - "movies"  = feature-length films (live-action or animated, but not series)
   - "series"  = NON-ANIME TV shows (live-action or non-anime animation, including mini-series, limited series, etc.)
   - "anime"   = ANIME TV shows or series (Japanese anime, donghua, Korean anime-style shows, etc.)

Lane rules:
- Do NOT mix types between lanes:
  - Movies only in "movies".
  - Non-anime TV shows only in "series".
  - Anime shows only in "anime".
- If something exists in multiple forms (e.g. an anime movie and an anime TV series), choose the form that best fits the lane you’re filling.
- Avoid duplicates across lanes. Each title should appear in at most one lane.
- Favor:
  - "series" lane → live-action or clearly non-anime TV.
  - "anime" lane → clear anime-style shows.
- You may recommend titles the user has not watched yet or has only partially watched if they strongly match the user's taste.

Output format (VERY IMPORTANT):
- Respond with ONLY a single JSON object, no markdown, no backticks, no comments, no extra text.
- The JSON must have EXACTLY this top-level shape:

{
  "movies": [
    {
      "id": "string",
      "title": "string",
      "year": 2022,
      "poster": "https://url-or-null",
      "background": "https://url-or-null",
      "overview": "string description"
    }
  ],
  "series": [
    {
      "id": "string",
      "title": "string",
      "year": 2020,
      "poster": "https://url-or-null",
      "background": "https://url-or-null",
      "overview": "string description"
    }
  ],
  "anime": [
    {
      "id": "string",
      "title": "string",
      "year": 2019,
      "poster": "https://url-or-null",
      "background": "https://url-or-null",
      "overview": "string description"
    }
  ]
}

Field rules:
- "id": string identifier that Stremio/Cinemeta or other addons can reasonably resolve
  (e.g. "tt1375666" for IMDb, "tmdb:27205" for TMDB, "simkl:12345", etc.).
- "title": human-readable title.
- "year": original release year as a number if known, otherwise null.
- "poster": full URL string to a poster image, or null.
- "background": full URL string to a background/backdrop image, or null.
  - If you don't know a background, you may reuse the poster URL.
- "overview": a short one-paragraph summary in plain text.

NEVER:
- Wrap the JSON in any formatting like \`\`\`.
- Add keys other than "movies", "series", and "anime" at the top level.
- Add any explanation or commentary outside the JSON.
`.trim();

async function getAiRecommendations(simklData) {
  if (!config.openrouter.apiKey) {
    throw new Error("OpenRouter API key not configured");
  }

  const model = config.openrouter.model || "openrouter/auto";
  const systemPrompt = config.openrouter.systemPrompt || defaultSystemPrompt;

  const userContent =
    "You are generating recommendations for a Stremio add-on.\n\n" +
    "Here is the user's Simkl data grouped by type and status as JSON:\n\n" +
    JSON.stringify({ simkl: simklData }, null, 2);

  const resp = await axios.post(
    "https://openrouter.ai/api/v1/chat/completions",
    {
      model,
      messages: [
        { role: "system", content: systemPrompt },
        { role: "user", content: userContent }
      ],
      temperature: 0.7
    },
    {
      headers: {
        "Authorization": `Bearer ${config.openrouter.apiKey}`,
        "Content-Type": "application/json"
      },
      timeout: 60000
    }
  );

  const text = resp.data?.choices?.[0]?.message?.content;
  if (!text) {
    throw new Error("No content from OpenRouter response");
  }

  let parsed;
  try {
    parsed = JSON.parse(text);
  } catch (err) {
    console.error("Failed to parse OpenRouter JSON:", text);
    throw new Error("OpenRouter did not return valid JSON");
  }

  return parsed;
}

// -------- CACHE (15 minutes) --------

let recommendationsCache = {
  lastUpdated: 0,
  data: null
};

async function getRecommendationsCached() {
  const now = Date.now();
  const ttlMs = 1000 * 60 * 15;

  if (recommendationsCache.data && now - recommendationsCache.lastUpdated < ttlMs) {
    return recommendationsCache.data;
  }

  const simklData = await fetchSimklLists();
  const aiRes = await getAiRecommendations(simklData);

  recommendationsCache = {
    lastUpdated: now,
    data: aiRes
  };

  return aiRes;
}

// -------- STREMIO ADDON --------

const manifest = {
  id: "simkl-openrouter-ai-recs",
  version: "1.0.0",
  name: "Simkl + OpenRouter AI Recommendations",
  description: "AI-powered recommendations based on your Simkl history (Movies, TV Series, Anime)",
  types: ["movie", "series"],
  catalogs: [
    {
      type: "movie",
      id: "simkl-ai.movies",
      name: "AI Recommended Movies"
    },
    {
      type: "series",
      id: "simkl-ai.series",
      name: "AI Recommended Series"
    },
    {
      type: "series",
      id: "simkl-ai.anime",
      name: "AI Recommended Anime"
    }
  ],
  resources: ["catalog"]
};

const builder = new addonBuilder(manifest);

builder.defineCatalogHandler(async args => {
  const { id, type } = args;
  console.log("Catalog request:", id, type);

  try {
    const recs = await getRecommendationsCached();

    let list = [];
    if (id === "simkl-ai.movies") {
      list = recs.movies || [];
    } else if (id === "simkl-ai.series") {
      list = recs.series || [];
    } else if (id === "simkl-ai.anime") {
      list = recs.anime || [];
    }

    const metas = list.map(item => {
      const meta = {
        id: String(item.id),
        type,
        name: item.title || item.name || "Untitled"
      };

      if (item.year) meta.year = item.year;
      if (item.poster) meta.poster = item.poster;
      if (item.background || item.poster) {
        meta.background = item.background || item.poster;
      }
      if (item.overview || item.description) {
        meta.description = item.overview || item.description;
      }

      meta.posterShape = "poster";
      return meta;
    });

    return { metas };
  } catch (e) {
    console.error("Catalog handler error:", e.message);
    return { metas: [] };
  }
});

const addonInterface = getInterface(builder);

app.get("/manifest.json", (req, res) => {
  res.setHeader("Content-Type", "application/json");
  res.send(addonInterface.manifest);
});

app.get("/catalog/:type/:id.json", (req, res) => {
  addonInterface.get(`/catalog/${req.params.type}/${req.params.id}.json`, req, res);
});

// -------- START SERVER --------

app.listen(PORT, () => {
  console.log(`Server listening on port ${PORT}`);
});
EOF

# Install dependencies
RUN npm install --omit=dev

ENV NODE_ENV=production
ENV PORT=7000

EXPOSE 7000

CMD ["node", "server.js"]
