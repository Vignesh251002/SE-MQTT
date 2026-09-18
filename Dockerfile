FROM node:20-alpine

WORKDIR /app

RUN apk upgrade --no-cache openssl libssl3 libcrypto3 ca-certificates || apk upgrade --no-cache

COPY package.json package-lock.json* ./
RUN npm ci --omit=dev

COPY src ./src
#expose mqtt and websocket ports
EXPOSE 1883
EXPOSE 9001

CMD ["node", "--import", "./src/instrument.js", "src/index.js"]
