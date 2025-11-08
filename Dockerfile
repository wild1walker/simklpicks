FROM node:20-alpine

WORKDIR /app

# Copy ANY zip in the repo (use one zip only)
COPY *.zip /tmp/app.zip

# Unzip and move the actual app (where package.json lives) to /app
RUN apk add --no-cache unzip \
 && mkdir -p /app/_unzip \
 && unzip -q /tmp/app.zip -d /app/_unzip \
 && PKG_JSON="$(find /app/_unzip -type f -name package.json | head -n1)" \
 && if [ -z "$PKG_JSON" ]; then echo "package.json not found in zip" && exit 1; fi \
 && PKG_DIR="$(dirname "$PKG_JSON")" \
 && cp -a "$PKG_DIR"/. /app/ \
 && rm -rf /app/_unzip /tmp/app.zip

# Install deps (your zip's package.json should have stremio-addon-sdk pinned to 1.7.6)
RUN npm install --omit=dev

# Runtime config
ENV PORT=7769
EXPOSE 7769
CMD ["npm","start"]
