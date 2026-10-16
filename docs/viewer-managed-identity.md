# Viewer managed identity source wiring

`Start-MaesterViewer.ps1` is the runnable source entrypoint for the read-only
viewer process. It composes an explicit Container Apps user-assigned managed
identity credential, the existing Azure Blob projection store, and the existing
loopback worker. Storage account, projection container, canonical tenant ID,
environment token, canonical nonzero identity client ID, and every listener or
size setting are validated before the worker starts listening.

The credential has no Azure SDK, login command, device-code path, default
credential chain, system-assigned fallback, or CLI fallback. On an actual token
refresh it rereads `IDENTITY_ENDPOINT` and `IDENTITY_HEADER`, because the
platform rotates the header value. It accepts only an absolute HTTP endpoint
whose host is `localhost` or a numeric loopback address, with no userinfo,
query, fragment, control character, or backslash, and with the exact
`/msi/token` path. The request adds only these fixed query values:

- `api-version=2019-08-01`
- `resource=https://storage.azure.com/`
- the configured user-assigned identity `client_id`

The production handler disables redirects, proxies, cookies, preauthentication,
default credentials, and ambient credentials. One deadline of at most ten
seconds covers response headers and the streamed response body. Only HTTP 200
and a nonempty JSON body of at most 64 KiB are accepted. A declared body length
must equal the completed stream length.

The response must contain a nonempty opaque `access_token`, exact `Bearer`
token type, exact storage resource, the configured client ID, and an integer
Unix `expires_on`. The token is not parsed as a JWT and no signature or token
claim is asserted. The credential holds at most one read-only `SecureString`.
The existing Blob callback borrows it for a sequential request; the credential
owner disposes it on replacement and shutdown. Cache validity ends at the
earlier of two minutes before service expiry or ten minutes after acquisition.
An expired cache is never returned after refresh failure.

All acquisition failures surface the same closed error without the endpoint,
platform header, response body, access token, or provider details. The composed
entrypoint similarly closes runtime failures and disposes the credential owner.
The runnable script supervises cancellation from console interruption and, on
non-Windows hosts, `SIGTERM`.

The reviewed source passed all 139 repository tests on PowerShell 7.6.6 locally
and in Linux CI, including the runnable process and Linux cancellation path.
A disposable, no-ingress Container Apps Job then ran the exact source from
commit `60b8f15aebf71c91e81a16344a08720c38dd5c5c` with file hashes verified
before import. All 13 native checks passed on PowerShell 7.6.6: the selected
user-assigned identity acquired a storage token, read the exact private
synthetic Unicode report, and reused its bounded token cache. Archive listing
and projection writes both returned HTTP 403 with
`AuthorizationPermissionMismatch`; the report remained unchanged. An unknown
identity failed without fallback. The actual runnable viewer reached readiness,
served the exact report bytes, handled Linux `SIGTERM` with exit code zero,
emitted no child output, and released its listener.

The native job used only a projection-container Blob Data Reader assignment for
the viewer identity. It had no ingress, archive permission, or end-user audience.
The temporary publisher assignment and owned lab resources were removed and
absence verified after testing. Failed deployment evidence was preserved.

This remains unwired source. A caller still must configure exactly one reviewed
user-assigned identity and its container-scoped reader role. Production image
packaging, signing/SBOM/provenance, runner publication, reviewed shared component
pin, infrastructure integration, HTTPS ingress/Entra authorization with concrete
allowed and denied users, real report assets, cold-start/scale behavior, and
rollback qualification remain open. The synthetic job proves the managed
identity and runnable worker boundary; it does not establish end-user report
delivery or qualify a production container image.

The platform contract follows Microsoft Learn's [managed identities in Azure
Container Apps](https://learn.microsoft.com/azure/container-apps/managed-identity).
