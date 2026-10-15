# Viewer projection protocol candidate

This source-only candidate defines the private snapshot boundary for the optional
Container App viewer. It does not enable a viewer, change the Maester runner,
provision identities or roles, serve HTML, or add a shared component dependency.
Those integration and qualification gates remain in MCAJ-007.

## Fixed objects and identities

The publisher accepts a configured canonical nonzero tenant GUID, an environment
token matching `[A-Za-z0-9][A-Za-z0-9._-]{0,63}`, a canonical nonzero run GUID,
the run start instant, and bounded UTF-8 HTML bytes. It never accepts a blob URL
or blob key. The only object keys are:

- `latest.json`
- `runs/{runId}/manifest.json`
- `runs/{runId}/report.html`

The projection container is private and separate from report archives. Pointer
and manifest documents use closed schema `1.0`; unknown fields fail validation.
Both bind tenant, exact environment token, run ID, generation, derived object
key, byte length, and uppercase SHA-256. The pointer binds the exact manifest
bytes, and the manifest binds the exact HTML bytes. Default limits are 20 MiB
for HTML, 8 KiB for a manifest, and 2 KiB for the pointer. The HTML limit may be
configured only up to 64 MiB.

Generation is the required UTC `RunStartedAtUtc.UtcTicks`, formatted as exactly
20 decimal digits. The runner integration must capture this instant before it
starts Maester. Ordering assumes those capture clocks are sufficiently aligned;
the protocol does not replace them with report metadata. Comparisons are ordinal.
An equal generation is idempotent only for the same run and manifest hash;
another candidate is a collision. An older candidate may finish its immutable
objects but never replaces a newer pointer.

The HTML check proves only nonempty bounded strict UTF-8 beginning with an HTML
document marker. It does not sanitize active content, prove that a Maester report
is self-contained, qualify external assets, or make the content safe to serve.
Those content and viewer gates remain open.

## Publish and read algorithms

The publisher writes HTML and manifest with `If-None-Match: *`. A 412 response
causes one bounded GET and exact byte comparison; different existing bytes are
an immutable-object collision. The pointer is written last. Each of at most three
CAS attempts reads and validates the current pointer, compares generations, then
uses its opaque ETag with `If-Match`, or `If-None-Match: *` when absent. Storage
failures propagate, so an interrupted immutable write cannot claim publication.
The maximum callback budget is ten operations: two for each immutable object and
two for each pointer attempt.

The reader makes at most three snapshot attempts. Each attempt reads the fixed
pointer, its one derived manifest, and its one derived HTML object; validates all
identities, paths, lengths, and hashes; then rereads `latest.json`. It returns
HTML bytes only when the pointer ETag and bytes are unchanged. The maximum callback
budget is twelve operations. A changing pointer, malformed document, missing
object, foreign identity, or mismatched byte binding returns no partial snapshot.

## Azure Blob REST adapter

`New-MaesterAzureBlobProjectionStore` constructs commercial Azure HTTPS URLs
from a validated storage account, container, and one protocol key. It obtains a
`SecureString` bearer token from the supplied provider for each operation; it
does not log in or accept SAS/query input. Production operations create and
dispose their own `HttpClientHandler`, `HttpClient`, request, response, streams,
buffers, cancellation source, and plaintext token conversion. An injected HTTP
handler is test-only and remains caller-owned.

The handler disables redirects, proxies, cookies, default credentials, and
preauthentication. One configurable deadline, capped at 15 seconds, covers HTTP
headers and the streamed body after the token provider returns. The caller owns
credential acquisition: the provider must return a previously acquired token or
use its own bounded, noninteractive acquisition. These HTTP deadlines cannot
interrupt an arbitrary caller-supplied token provider. GET streams are bounded even when `Content-Length` is absent or false,
and truncated bodies fail. The adapter accepts GET 200/404 and PUT 201/412. A PUT
with `If-None-Match: *` also maps exactly HTTP 409 plus the single
`x-ms-error-code: BlobAlreadyExists` header to a create-only collision; other
409 responses fail. The publisher still reads and compares the existing bytes
before treating either collision status as idempotent.
Errors are reduced to a fixed message without token, URL, provider body, or query
details. With the protocol operation caps, the worst-case sequential deadline
budget for HTTP requests is 150 seconds for publishing and 180 seconds for reading
at the default 15 seconds, excluding credential acquisition and local processing.

Offline callback and typed HTTP-handler fixtures prove protocol behavior, not
live Azure Blob acceptance, managed-identity authority, viewer delivery, or
human-visible report access.

The source candidate passed 112 repository tests on PowerShell 7.6.6 and an
independent source review. A disposable lab account with shared keys and public
blob access disabled passed 11 native Blob checks using a cached delegated
identity: publication, exact-byte readback, repeat idempotence, newer and older
generation ordering, stale and create-only write rejection, interrupted
publication, corruption rejection, and exact restoration. The first attempt is
preserved: it exposed Azure's create-only `409 BlobAlreadyExists`, addressed by
the narrowly scoped mapping above and five transport regression cases. This
does not qualify managed identity, Caddy, Entra audiences, or the deployed viewer.
The temporary container role and exact owned resource group were removed, with
their absence verified after validation.

## Sources

- [Put Blob](https://learn.microsoft.com/en-us/rest/api/storageservices/put-blob)
- [Blob conditional headers](https://learn.microsoft.com/en-us/rest/api/storageservices/specifying-conditional-headers-for-blob-service-operations)
