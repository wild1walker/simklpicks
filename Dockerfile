FROM node:20-alpine

WORKDIR /app

# copy your uploaded zip from the repo into the image
COPY simklpicks_v2.zip /tmp/app.zip

# unzip it into /app
RUN apk add --no-cache unzip \
  && mkdir -p /app/_unzip \
  && unzip -q /tmp/app.zip -d /app/_unzip \
  && if [ -d /app/_unzip/simklpicks_v2 ]; then mv /app/_unzip/simklpicks_v2/* /app/; else mv /app/_unzip/* /app/; fi \
  && rm -rf /app/_unzip /tmp/app.zip

# install dependencies
RUN npm install --omit=dev

EXPOSE 7769
CMD ["npm","start"]
