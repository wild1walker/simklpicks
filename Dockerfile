FROM node:20-alpine

WORKDIR /app

# Copy ANY zip in the repo (keep only one zip there)
COPY *.zip /tmp/app.zip

# Unzip and move the app (where package.json lives) to /app
RUN apk add --no-cache unzip \
 && mkdir -p /app/_unzip \
 && unzip -q /tmp/app.zip -d /app/_unzip \
 && PKG_JSON="$(find /app/_unzip -type f -name package.json | head -n1)" \
 && if [ -z "$PKG_JSON" ]; then echo "package.json not found in zip" && exit 1; fi \
 && PKG_DIR="$(dirname "$PKG_JSON")" \
 && cp -a "$PKG_DIR"/. /app/ \
 && rm -rf /app/_unzip /tmp/app.zip

# Install deps. If stremio-addon-sdk version is invalid, pin it to the latest and retry.
RUN set -eux; \
    if ! npm install --omit=dev; then \
      LATEST="$(npm view stremio-addon-sdk version)"; \
      npm pkg set dependencies.stremio-addon-sdk="$LATEST"; \
      npm install --omit=dev; \
    fi

ENV PORT=7769
EXPOSE 7769
CMD ["npm","start"]
