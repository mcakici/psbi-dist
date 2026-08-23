# PSBI

Self-hosted knowledge, problem-solving, and optional browser automation platform. Users work primarily from a Chrome/Edge extension. The appliance can run fully local (Ollama) or send embedding/LLM calls to a private/remote provider.

**Codename:** Problem Solver Business Intelligence. Brand name is not final.

## Layout

```text
apps/server       Laravel 13 Control Center / API
apps/extension    Manifest V3 React/Vite side panel
apps/agent        Go host agent + psbictl
packages/contracts    OpenAPI + JSON Schema + generated TS
packages/domain-types Shared enums
infra/compose         Postgres 18 + Redis
docs/development      Architecture package (source of truth)
```

## Toolchain

Pinned in `.tool-versions`: PHP 8.4, Node 22, pnpm 10, Go 1.26.

## Windows installation

For a public-release installation on Windows, follow the Turkish mini guide: [`WINDOWS_MINI_KURULUM.md`](WINDOWS_MINI_KURULUM.md).

## One-command local check

```powershell
pnpm install
pnpm icons
pwsh -File scripts/ci.ps1
```

Start data stores:

```powershell
pwsh -File scripts/dev.ps1
```

Then `cd apps/server; php artisan serve` and load `apps/extension/dist` as an unpacked Chrome extension.

## Commits

Conventional Commits (`feat:`, `fix:`, `docs:`, `chore:`). See `commitlint.config.js`.

## Try indexing (local)

```powershell
pwsh -File scripts/dev.ps1
cd apps/server
php artisan migrate --seed
php artisan psbi:index-source --all
php artisan serve
```

Appliance install (preflight + compose + migrate): `pwsh -File scripts/install.ps1`

Control Center: http://127.0.0.1:37641/login (`admin@psbi.local` / `password` local-only). Search at `/control/search` with URL `https://prod.x.com/aaa` and query `XML`. Wiki wizard and pause/resume live under `/control/sources`.

Load `apps/extension/dist` as an unpacked Chrome/Edge MV3 extension. Side panel search uses the active tab URL (workspace is never taken from the client). Recorder (optional host permission + debugger) submits GET list/detail traffic to `/api/v1/connectors/infer` and never stores cookies or Authorization headers.

HTTP wiki/work-tracker indexing is covered by `HttpWikiCrawler` and `WorkTrackerHttpIndexer` (GET-only, frontier pause/resume, follow watermarks).

## Phase status

- Faz 00 — monorepo/CI: landed
- Faz 01 — appliance Control Center, health, domain resolver, installer preflight, compose app/worker/scheduler + OCR tmpfs: in repo (Octane/Horizon UI still later)
- Faz 02 — parsers (HTML/JSON/XML), chunking, hash embeddings, exact/FTS/vector RRF lexical search
- Faz 03 — HTTP wiki crawler with frontier, allowlist, cycles, redirects, OCR alt-text
- Faz 04 — MV3 search + version handshake + connector recorder
- Faz 05 — work tracker HTTP list/detail/cursor, follow watermarks, previous-solution search
