# CLAUDE.md — Sourcegraph public-snapshot, local from-source work

This is the last public Sourcegraph snapshot (~v5.x). The local effort here runs
**code indexing / navigation / retrieval from source**, without Bazel, the `sg`
tool, the private `dev-private` repo, or a license.

## Where things live
- Local stack runbook, docs, and integration guide: **`local-codeintel-runbook/`**
  (`run-stack.sh`, `README.md`, `integration.md`, `scipgen/`). Use `run-stack.sh`
  for build/run/teardown — don't hand-roll service startup.
- Continuation state + pending tasks: **`.claude/session-handoff.md`**.
- Built binaries go in `.bin/` (and `.bin/zoekt/`).

## Durable rules
- **Build service binaries with the system Go (≥1.23), not the repo-pinned
  1.22.4.** 1.22.4-linked binaries fail at runtime on this macOS with
  `missing LC_UUID`. Exception: a few `internal/codeintel/codenav` *test* packages
  need `GOTOOLCHAIN=go1.22.4` (old `golang.org/x/tools` won't compile on Go 1.25).
- **Don't use Bazel / `sg` / `dev-private` for the local stack** — everything is
  plain `go build` + the runbook. The default `enterprise` commandsets hard-require
  `dev-private`; avoid them.
- **frontend is the config server**: run it with `CONFIGURATION_MODE=server`; every
  other service uses `client`. Set `SRC_PROF_HTTP=` (empty) on all to avoid the
  `:6060` debug-port clash.
- **API surfaces:** internal `:3090/.internal/{graphql,scip/upload}` is
  **unauthenticated** (service-to-service) — use it for local/backend calls, never
  expose it externally. Public `:3082/.api/...` needs `Authorization: token`.
- **Code positions are 0-based** (line & character), ranges half-open; SCIP upload
  Content-Type is `application/x-protobuf+scip` (gzip body).
- Local infra is Dockerized: Postgres `sg-testpg` (:5433), Redis `sg-redis` (:6380).
- Before adding new gotchas/run steps, update `local-codeintel-runbook/README.md`
  (gotchas list) and `.claude/session-handoff.md` — keep them the source of truth.
- These runbook files are currently **untracked inside the Sourcegraph tree**; do
  not commit them into upstream history without an explicit decision.
