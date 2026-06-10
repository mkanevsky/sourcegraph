# Integration guide: code indexing & retrieval for an external app

How an external "code dev orchestration" app talks to this stack. Two capability
domains, intentionally decoupled:

- **Search / indexing** — full‑text + (optional) symbol search over repos (zoekt).
- **Precise navigation** — definitions / references / hover from uploaded SCIP.

All endpoints are served by `frontend`. There are **two surfaces**:

| Surface | Base | Auth | Use for |
|---|---|---|---|
| Public API | `http://localhost:3082/.api` (browser/caddy: `:3080`) | `Authorization: token <sg-token>` | external clients, prod-like |
| Internal API | `http://localhost:3090/.internal` | **none** (service-to-service trust) | a co-located backend; what the runbook/demo use |

Paths differ by surface: public `/.api/graphql`, `/.api/scip/upload`,
`/.api/search/stream`; internal `/.internal/graphql`, `/.internal/scip/upload`.
GraphQL/SCIP **shapes are identical** across surfaces.

> Positions are **0-based** (line & character), matching LSP. Ranges are
> half-open: `end` is exclusive.

---

## 1. Indexing — make a repo known

Precise nav and search both require the repo to be **registered and cloned**
first (an upload/search for an unknown repo fails or returns empty).

### 1a. Register a code host (external service, kind `OTHER`)

Set frontend env `EXTSVC_CONFIG_FILE=/path/to/extsvc.json` (read-only config) or
add via the site-admin GraphQL mutation `addExternalService`. The `OTHER` kind
takes a git base URL (**`git://`, `ssh://`, or `http(s)://` — not `file://`**):

```json
{ "OTHER": [
  { "url": "git://host:9418", "repos": ["my-repo"], "repositoryPathPattern": "{repo}" }
] }
```

`repo-updater` syncs the external service → inserts a `repo` row → `gitserver`
clones it. Poll readiness via GraphQL (below) until `mirrorInfo.cloned == true`.

### 1b. (Search) zoekt indexes automatically

Once a repo is cloned, `zoekt-sourcegraph-indexserver` picks it up within its
interval and writes a shard. No client action needed.

### 1c. (Precise nav) upload a SCIP index — REST

```
POST /.internal/scip/upload
     ?repository=<name>&commit=<40-hex-sha>&root=<subdir-or-empty>
     &indexerName=<tool>&indexerVersion=<v>
Content-Type: application/x-protobuf+scip        # REQUIRED exact value
Body: gzip( SCIP Index protobuf )                 # gzip-compressed
```

**Response DTO** (`200`):
```json
{ "id": "42" }      // numeric upload id as a string
```

Processing is async: `precise-code-intel-worker` parses → writes the codeintel
DB; then `worker` recomputes commit-graph **visibility**. Until visibility is
computed the `lsif` field (below) returns `null`. Treat upload→queryable as
eventually-consistent (poll, ~seconds in dev).

**Ingest DTO — the SCIP Index** (`github.com/sourcegraph/scip/bindings/go/scip`,
proto3; any language's protobuf bindings work):
```
Index {
  Metadata { Version, ToolInfo{Name,Version}, ProjectRoot, TextDocumentEncoding }
  Documents [ Document {
    Language, RelativePath,                      // path relative to upload `root`
    Occurrences [ Occurrence {
      Range: []int32,                            // [startLine,startChar,endChar] or
                                                 //   [startLine,startChar,endLine,endChar]
      Symbol: string,                            // SAME string links def<->refs
      SymbolRoles: int32                         // bit 0x1 = Definition, 0 = reference
    } ]
    Symbols [ SymbolInformation { Symbol, Documentation[] } ]  // Documentation -> hover
  } ]
}
```
A symbol string is `"<scheme> <pkg-manager> <pkg-name> <pkg-version> <descriptors>"`,
e.g. `scip-go gomod demo v0.0.0 Greet().`. The processor validates each
`RelativePath` against `gitserver` at `commit`, so paths must exist at that commit.

> Generate real indexes with `scip-go` / `scip-typescript` / etc. `scip-go`
> can't be `go install`ed from this snapshot (its deps reference the now-private
> `sourcegraph/lib`); produce SCIP elsewhere or hand-build (see `scipgen/`).

---

## 2. Retrieval — query

### 2a. Search — streaming HTTP (lightest), SSE

```
GET /.api/search/stream?q=<query>&v=V3&t=<literal|regexp|structural>&display=<n>
Accept: text/event-stream
```
Query language in `q`: `repo:`, `file:`, `lang:`, `case:`, `sym:`, boolean, regex.

**Event DTOs** (`internal/search/streaming/http/events.go`), SSE `event:` names:
- `matches` → array of match objects, discriminated by `type`:
  ```
  EventContentMatch {
    type: "content", path, repositoryID, repository, branches[], commit,
    lineMatches?[ { line, lineNumber, offsetAndLengths: [[off,len],...] } ],
    chunkMatches?[ { content, contentStart:{offset,line,column}, ranges:[Range] } ]
  }
  EventPathMatch  { type:"path", path, repository, ... }
  EventRepoMatch  { type:"repo", repository, ... }
  EventSymbolMatch{ type:"symbol", path, symbols:[{name,kind,line,...}], ... }
  ```
- `progress` → `{ done, matchCount, durationMs, skipped[] }`
- `error` → `{ name, message }`
- `done` → terminal

### 2b. Search — GraphQL (structured)

`POST /.internal/graphql` (or `/.api/graphql`):
```graphql
query($q:String!){ search(query:$q, version:V3, patternType:literal){
  results{
    matchCount
    results{ __typename ... on FileMatch{
      repository{ name }
      file{ path }
      lineMatches{ lineNumber preview offsetAndLengths }
      chunkMatches{ content ranges{ start{line character} end{line character} } }
    } }
  }
}}
```
`SearchResults.results` is a union: `FileMatch | CommitSearchResult | Repository`.
Verified response shape:
```json
{ "data": { "search": { "results": {
  "matchCount": 5,
  "results": [ { "__typename":"FileMatch",
    "file": { "path":"greeter.go" },
    "lineMatches": [ { "lineNumber":3, "preview":"func Greet(name string) string {" } ] } ]
}}}}
```

### 2c. Precise navigation — GraphQL

```graphql
query($repo:String!,$rev:String!,$path:String!,$line:Int!,$char:Int!){
  repository(name:$repo){ commit(rev:$rev){ blob(path:$path){
    lsif {                                # null until an upload is visible here
      definitions(line:$line, character:$char){
        nodes{ resource{ path } range{ start{line character} end{line character} } }
      }
      references(line:$line, character:$char, first:100){
        nodes{ resource{ path } range{ start{line character} end{line character} } }
        pageInfo{ hasNextPage endCursor }
      }
      hover(line:$line, character:$char){ markdown{ text } range{ start{line character} end{line character} } }
    }
  }}}
}
```
Verified DTOs:
- definitions/references → `LocationConnection { nodes:[Location], pageInfo }`,
  `Location { resource:{ path }, range:{ start:{line,character}, end:{...} } }`.
- hover → `{ markdown: { text: "```go\nfunc Greet(...)\n```\n\n..." }, range }`.

`lsif == null` ⇒ no visible precise data at that blob/commit (no upload yet, or
visibility not computed). Empty `nodes` ⇒ no symbol at that position.

### 2d. Standalone zoekt JSON (no frontend/Postgres) — alternative for search-only

If an app only needs search, skip this whole stack and use zoekt directly:
```
GET http://localhost:6070/search?q=<query>&format=json   # web.ApiSearchResult
```
`ApiSearchResult { QueryStr, Query, Stats{...}, FileMatches:[{ FileName, Repo,
Language, Branches[], Matches:[{ URL, FileName, LineNum, Fragments:[{Pre,Match,Post}] }] }] }`.

---

## 3. Readiness / status helpers (GraphQL)

```graphql
{ repository(name:"my-repo"){ name mirrorInfo{ cloned cloneInProgress } } }   # clone status
{ repository(name:"my-repo"){ commit(rev:"<sha>"){ oid } } }                  # commit resolvable?
```
Upload state lives in the frontend DB table `lsif_uploads(state, content_type,
failure_message)` — states: `uploading → queued → processing → completed | errored`.

---

## 4. API considerations / gotchas for clients

- **Auth:** public surface needs `Authorization: token <sg-token>` (create via
  site-admin UI or `createAccessToken` mutation). Internal surface (`:3090`) is
  unauthenticated by design — never expose it outside the trusted network.
- **Ordering:** register+clone repo → (search auto-indexes) / (upload SCIP) →
  poll until queryable. Don't upload for a commit `gitserver` can't resolve.
- **Eventual consistency:** SCIP upload → queryable has a lag (worker commit
  graph). Poll `lsif.definitions` (or table state) rather than assuming instant.
- **Content-Type matters:** SCIP upload must be `application/x-protobuf+scip`
  and the body **gzip-compressed**; wrong type → upload `errored`.
- **Positions are 0-based**, ranges half-open. Off-by-one is the #1 client bug.
- **Pagination:** `references`/large result sets use `first` + `pageInfo.endCursor`
  (`after:`). Search supports `display`/`count` limits; stream emits `progress`.
- **Multipart uploads:** large SCIP indexes use the multipart upload protocol
  (`uploadId` + parts); single-shot POST (shown here) is fine for modest sizes.
- **Symbol search** needs `universal-ctags`+`scip-ctags` on the indexserver;
  without them, search is text-only (current runbook state).
- **GraphQL is POST-only**; rate limiting differs for anonymous vs authed.
- **Versioning:** this is the v5.x public snapshot; GraphQL fields can differ
  from current Sourcegraph (e.g. uploads connection field names). Introspect if
  unsure: `{ __type(name:"Repository"){ fields{ name } } }`.

---

## 5. Endpoint quick-reference

| Capability | Method + path | Key DTO |
|---|---|---|
| Register repo | `EXTSVC_CONFIG_FILE` / `addExternalService` | OTHER config JSON |
| Clone status | GraphQL `repository.mirrorInfo.cloned` | bool |
| SCIP upload | `POST /.internal/scip/upload` (`x-protobuf+scip`, gzip) | `{id}` ← SCIP `Index` |
| Search (stream) | `GET /.api/search/stream` | SSE `matches/progress/done/error` |
| Search (GraphQL) | `POST /.internal/graphql` `search(...)` | `SearchResults`/`FileMatch` |
| Definitions/refs | GraphQL `...blob.lsif.definitions/references` | `LocationConnection` |
| Hover | GraphQL `...blob.lsif.hover` | `{ markdown{text}, range }` |
| Search-only (no stack) | `GET :6070/search?...&format=json` | `web.ApiSearchResult` |
