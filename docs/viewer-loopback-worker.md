# Maester viewer loopback worker

`Start-MaesterViewerWorker` is the read-only source boundary for a future
same-app viewer. It repeatedly calls `Read-MaesterViewerProjection` with a
caller-supplied store, tenant ID, and environment. Only a fully verified
projection becomes an immutable in-memory snapshot; replacement is atomic.
The worker never derives a blob key or storage request from an HTTP request.

The listener binds only `127.0.0.1` and defaults to port `8081`. It accepts
exact raw `GET` and `HEAD` requests for:

- `/report.html`: verified HTML bytes, or `503 unavailable`
- `/healthz`: process/listener liveness only
- `/readyz`: whether a current snapshot is eligible to be served

Queries, alternate or encoded paths, request bodies, WebSocket upgrades, and
other methods are rejected. Probes contain no tenant, environment, run,
storage, or error detail. Successful report responses include bounded
staleness metadata: run ID, generation, age in seconds, and whether the latest
refresh failed. These headers are intended for the trusted same-app proxy and
must not be treated as authorization or issuer proof.

## Bounds and failure behavior

- Poll interval: 100 milliseconds to 1 hour; default 30 seconds.
- Maximum verified HTML: 64 MiB; default 20 MiB. The projection reader also
  applies its fixed manifest, pointer, operation-count, and storage deadlines.
- Concurrent handlers: 1 to 64; default 4. Excess connections are aborted with
  a best-effort `503` status without scheduling another writer.
- Client write deadline: greater than zero and at most 15 seconds; default 5
  seconds. Shutdown cancels writes, aborts remaining responses, waits a bounded
  period, and releases the listener port.
- Maximum report age: greater than zero and at most 31 days; default 24 hours.
  Age is measured from the verified 20-digit generation, which is the captured
  UTC run-start tick value. A successful reread of the same projection does
  not renew its age. Future generations are never installed.

Startup is unavailable until the first successful read. A failed later refresh
keeps the last verified snapshot only while that snapshot remains within the
configured maximum age. Failure never replaces or extends the snapshot.
The cache retains one current snapshot; active handlers can each retain an older
snapshot until their write deadline. The configured concurrency limit bounds
those retained responses. The bounded projection read, HTML copy, runtime GC,
and network buffers need additional memory; HTML size alone is not the process
memory limit.

The module requires PowerShell 7.6 or later. `Start-MaesterViewerWorker` blocks
until its required cancellation token is canceled; its owner must supervise
that lifecycle. Cancellation is checked between projection reads and during the
poll wait. It cannot interrupt an in-progress caller-supplied `Store` callback.
The reviewed Azure Blob adapter bounds its HTTP operations, but the whole
projection read can take up to its documented sequential request budget, plus
credential acquisition and local processing. An arbitrary callback may run
longer. A future container supervisor must enforce a hard process termination
deadline separately from the bounded listener/write drain.
The current Windows test host permits the loopback
`HttpListener` prefix without a URL ACL. Container image, Linux runtime,
managed-identity token provider, ingress/authentication, cache
policy, and operational restart behavior remain deployment qualification work.
The in-memory source also does not claim that arbitrary Maester HTML is
self-contained or safe to render; report-content qualification remains open.

## Fixed Caddy boundary

`viewer/Caddyfile` listens on HTTP port 8080 for a future Container App ingress
that terminates HTTPS and enforces the reviewed Entra authorization policy.
It is source configuration, not enabled deployment input. It must not be exposed
as an unauthenticated public report server.

Caddy accepts only GET/HEAD with one of the three exact original request URIs
listed above, including case and encoding. Its sole upstream is the literal
`127.0.0.1:8081`; it removes request headers and sends only that fixed Host.
Automatic compression and environment proxies are disabled. Header sizes,
connections per upstream, and transport/server timeouts are bounded. Admin,
configuration persistence, automatic TLS management, and logging are disabled.
TLS and authorization remain platform requirements; request headers are not
identity proof inside the worker.

CI selects hash-pinned Caddy 2.11.7 and exercises both the real proxy-to-worker
path and a bounded synthetic upstream capture. The capture proves the actual
request target and sole Host header, rather than inferring header behavior from
response content. Local validation uses the same scripts:

```powershell
./tests/Test-ProxyHeaders.ps1 -CaddyPath <caddy-binary> -ConfigPath ./viewer/Caddyfile -OutputDirectory <new-directory>
./tests/Test-ViewerProxy.ps1 -Root $PWD.Path -CaddyPath <caddy-binary> -ConfigPath ./viewer/Caddyfile -OutputDirectory <another-new-directory>
```

These tests use synthetic reports, own their child processes, and require ports
8080, 8081 and 2019 to be unused. They verify port release after cleanup. Binary
hash pinning for tests is not signed container-image/SBOM/provenance qualification.

Configuration follows Caddy's documented [original URI matchers](https://caddyserver.com/docs/caddyfile/matchers),
[headers and HTTP transport](https://caddyserver.com/docs/caddyfile/directives/reverse_proxy),
and [global options](https://caddyserver.com/docs/caddyfile/options).
