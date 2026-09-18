# SD-MQTT (Node worker)

Long-running MQTT subscriber designed to run as a sidecar container in the same ECS Task as Mosquitto.

## What it does

- Subscribes to `location/updates`
- Ignores client-provided decoded addresses and resolves `live_address` on backend via Nominatim for every incoming location update
- Writes the latest user snapshot to Redis (hot path)
- Persists each location update to MySQL:
  - upsert into `user_locations`
  - insert into `user_location_histories`
- Publishes (Laravel-compatible JSON shape):
  - `location/response` (per update, built from Redis)
  - `group/location` (per update, geohash-neighbor strategy + recent-window filtering)
- Listens for external session toggle commands on MQTT:
  - topic: `user-location/live-address-session/toggle` (configurable)
  - payload: `{ "target_user_id": 2628, "viewer_user_id": 1001, "status": true }` or `{ "target_user_ids": [2628, 1002], "viewer_user_id": 1001, "status": true }`
  - when enabled and active, publishes one-time snapshot to `location/response` and `group/location`
  - publishes toggle result to `user-location/live-address-session/result` with:
    - `request_id`, `target_user_id`, `viewer_user_id`, `status`, `is_active`, `mqtt_snapshot_published`, `ok`
- Buffers every point of a “trip” in Redis and writes to MySQL only when the trip ends:
  - Trip ends by inactivity: if no updates arrive for `TRIP_END_INACTIVITY_SEC`
  - Flush uses a single MySQL transaction per trip:
    - bulk insert into `user_location_histories`
    - upsert the final point into `user_locations`

## Trip end (inactivity)

- A user’s trip is considered “active” as long as location updates keep arriving.
- If no updates arrive for `TRIP_END_INACTIVITY_SEC`, the worker:
  - reads the latest snapshot from Redis
  - flushes buffered trip points from Redis to MySQL
  - upserts `user_locations` for that user (same transaction)

## Redis keys

- `user:{id}:loc` (HASH): latest snapshot for a user (expires)
- `geo:active` (GEO): active users indexed by lon/lat
- `active:ts` (ZSET): last activity timestamp (unix seconds)
- `group:{geohashPrefix}` (SET): short-lived prefix group membership
- `group:ids` (HASH) + `group:ids:seq` (STRING counter): stable sequential `group_id` per `geohash_prefix`
- `group:sticky:{userId}` (STRING): sticky convoy `group_id` while a user is actively moving (TTL `GROUP_STICKY_TTL_SEC`)
- `trip:{userId}:points` (LIST): buffered points for the current trip
- `trip:{userId}:flushLock` (STRING): prevents duplicate trip flush across overlapping timers/instances

## MySQL schema requirements

Current location table:

- `user_locations.user_id` must be unique so the worker can upsert instead of inserting duplicates.
- One-time fix script: [sql/ensure_user_locations_unique_user_id.sql](sql/ensure_user_locations_unique_user_id.sql)

History table (recommended):

- If `MYSQL_ON_DUPLICATE_NOOP=1`, add a UNIQUE key like `(user_id, uuid)` on `user_location_histories` so retries/replays are safe.

## Environment variables

### MQTT

- `MQTT_URL` (optional; overrides host/port)
- `MQTT_PROTOCOL` (optional: `mqtt` | `mqtts` | `ws` | `wss`)
- `MQTT_HOST` (optional)
- `MQTT_PORT` (optional)
- `MQTT_USERNAME` / `MQTT_PASSWORD` (optional)
- `MQTT_CLIENT_ID` (optional)
- `MQTT_TOPIC_UPDATES` (default: `location/updates`)
- `MQTT_TOPIC_RESPONSE` (default: `location/response`)
- `MQTT_TOPIC_GROUP` (default: `group/location`)
- `MQTT_TOPIC_LIVE_ADDRESS_SESSION_TOGGLE` (default: `user-location/live-address-session/toggle`)
- `MQTT_TOPIC_LIVE_ADDRESS_SESSION_RESULT` (default: `user-location/live-address-session/result`)

### MQTT startup

By default the worker will exit non-zero if it cannot connect to MQTT within the grace period (so ECS restarts it).

- `MQTT_CONNECT_REQUIRED` (default: `1`)
- `MQTT_CONNECT_GRACE_MS` (default: `30000`)

### Sentry

Optional error and performance monitoring for the MQTT location loop (`location/updates` → `location/response` / `group/location`). When `SENTRY_DSN` is unset, Sentry is disabled and the worker runs normally.

- `SENTRY_DSN` (optional; Node project DSN)
- `SENTRY_ENVIRONMENT` (default: `development`)
- `SENTRY_TRACES_SAMPLE_RATE` (default: `0.1`; use `1` briefly to verify traces)
- `SENTRY_RELEASE` (optional)
- `SENTRY_ENABLE_LOGS` (default: `1`) send structured logs to Sentry **Explore → Logs**
- `SENTRY_LOG_MQTT_PAYLOADS` (default: `1`) include topic payload JSON on each MQTT log

Every inbound/outbound MQTT hop is logged to Sentry Logs with topic, direction, `user_id`, and payload data. Failures still appear under **Issues**.

Location hop timing (filter by `uuid` to compare Frontend vs SD-MQTT):

| Log message | Meaning | Key attributes |
|-------------|---------|----------------|
| `Arrived location/updates` | MQTT message hit the worker (before per-user queue) | `mqtt_arrived_at`, `location_captured_time`, `capture_to_arrive_ms` (**Gap A**: Frontend / network / broker) |
| `Received location/updates` | Processing started after queue wait | `process_started_at`, `queue_wait_ms`, `capture_to_process_ms` (**Gap B**: SD-MQTT queue) |
| `Published location/response` | Response published | `response_published_at`, `process_to_publish_ms`, `arrive_to_publish_ms`, `capture_to_publish_ms` (**Gap C**: processing) |
| `Published group/location` | Group publish | `group_published_at`, same gap ms fields |

Timing attributes are always sent even when `SENTRY_LOG_MQTT_PAYLOADS=0`.

### Redis

- `REDIS_URL` (default: `redis://127.0.0.1:6379`)
- `REDIS_LOC_TTL_SEC` (default: `130`)
- `REDIS_GROUP_TTL_SEC` (default: `60`)

### Trip buffering / trip end

- `TRIP_END_INACTIVITY_SEC` (default: `60`) end trip if no updates arrive
- `TRIP_BUFFER_TTL_SEC` (default: `172800`) TTL for `trip:{userId}:points`
- `TRIP_BUFFER_MAX_POINTS` (default: `0`) keep last N points per trip (0 = unlimited)

### Nearby logic

- `ACTIVE_WINDOW_SEC` (default: `20`)
- `NEARBY_RADIUS_M` (default: `250`)
- `NEARBY_LIMIT` (default: `200`)

### Group emission

- `GROUP_GEOHASH_PREFIX_LEN` (default: `5`)
- `GROUP_RECENT_WINDOW_SEC` (default: `60`)
- `GROUP_STICKY_TTL_SEC` (default: `20`) sticky convoy `group_id` TTL so co-moving users keep the same id across geohash hops, brief slowdowns, and leave/rejoin

### Live-address session storage

- `LIVE_ADDRESS_SESSION_KEY_PREFIX` (default: `live_address_sessions`)

Redis key model used by this service:
- key: `live_address_sessions:{targetUserId}`
- value: Redis hash where each field is `viewerUserId`
- enabling adds viewer field, disabling removes it
- key is deleted when no viewers remain

### Live-address resolution

- `LIVE_ADDRESS_ALWAYS_REUSE` (default: `1`) reuse last known `live_address` when Nominatim is skipped or returns empty
- `LIVE_ADDRESS_FALLBACK_LOOKUP_LAST` (default: `1`) when no prior address exists, try Nominatim using the last saved location (Redis, then MySQL)

### Nominatim

- `NOMINATIM_BASE_URL` (default: `https://nominatim.openstreetmap.org/reverse`)
- `NOMINATIM_TIMEOUT_MS` (default: `4000`)
- `NOMINATIM_USER_AGENT` (default: `sd-mqtt-worker/1.0`)

### MySQL

- `MYSQL_HOST` (default: `127.0.0.1`)
- `MYSQL_PORT` (default: `3306`)
- `MYSQL_USER` (default: `root`)
- `MYSQL_PASSWORD` (default: empty)
- `MYSQL_DATABASE` (required)
- `MYSQL_TABLE` (default: `user_location_histories`)
- `MYSQL_CURRENT_TABLE` (default: `user_locations`) current location table
- `MYSQL_UPSERT_CURRENT_ON_TRIP_END` (default: `1`) upserts into `MYSQL_CURRENT_TABLE` when a trip ends
- `MYSQL_REQUIRE_USER_LOCATIONS_UNIQUE` (default: `1`) requires `UNIQUE(user_id)` on `MYSQL_CURRENT_TABLE` (worker exits if missing)

Batch writing:

- `MYSQL_INSERT_BATCH_SIZE` (default: `500`)
- `MYSQL_ON_DUPLICATE_NOOP` (default: `1`) enables `ON DUPLICATE KEY UPDATE` no-op (add a UNIQUE key like `(user_id, uuid)` to make retries safe)

### Notes on MySQL cost

For 1 point / 4 seconds, avoid inserting per message. This worker buffers trip points in Redis and writes to MySQL only when the trip ends (inactivity), using a single MySQL transaction.

### Startup preflight

The worker will retry Redis/MySQL connectivity at startup and exit non-zero if they are not reachable within the grace period (useful for ECS health/restart behavior).

- `STARTUP_GRACE_MS` (default: `30000`)
- `STARTUP_RETRY_MS` (default: `1000`)

## Local run

### Option A: Run worker directly (no Docker)

```bash
npm install
MYSQL_DATABASE=your_db REDIS_URL=redis://127.0.0.1:6379 MQTT_URL=mqtt://127.0.0.1:1883 npm start
```

### Option B: Local Docker dependencies (Mosquitto + Redis) + worker in Docker

This repo’s [docker-compose.yml](docker-compose.yml) is intended for local development only.

1) Create a `.env` from `.env.example` and set at least:

- `MYSQL_DATABASE` (required)
- `MYSQL_HOST` (use `host.docker.internal` for WAMP MySQL on Windows)
- `MOSQUITTO_USERNAME` / `MOSQUITTO_PASSWORD`
- `REDIS_PASSWORD`

2) Start local Mosquitto + Redis + worker:

```bash
docker compose up -d --build
docker compose logs -f
```

Optional local MySQL (instead of WAMP/RDS):

```bash
docker compose --profile mysql up -d
```

If you enable the MySQL profile, set `MYSQL_HOST=mysql` (inside Docker) so the worker can connect.

Simulator notes:

- Your simulator can connect to `mqtt://localhost:1883`.
- Trip end is detected by inactivity: if no updates arrive for `TRIP_END_INACTIVITY_SEC`.

## ECS notes

- This repo’s [docker-compose.yml](docker-compose.yml) is **local development only**.
- In ECS/live, build and deploy **only the worker image** from [Dockerfile](Dockerfile).
- Run this worker as a separate container in the same ECS Task as Mosquitto.
- With `awsvpc` network mode, containers share the task ENI, so Mosquitto is reachable via `mqtt://127.0.0.1:1883` as long as it listens on `0.0.0.0`.
- For ElastiCache Redis, set `REDIS_URL` to the ElastiCache endpoint (Redis-compatible; not Memcached).
- Ensure security groups allow MySQL/Redis access (RDS / ElastiCache) from the task ENI.

### CI/CD guardrail

If you have a build pipeline, avoid `docker compose build` (which could build local-only images). Prefer building the worker explicitly:

- `docker build -t <your-ecr-repo>:<tag> -f Dockerfile .`

Or, if you do use Compose for builds:

- `docker compose build sd-mqtt-worker`
