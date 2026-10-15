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

This is source wiring only. A caller still must configure exactly one reviewed
user-assigned identity and grant it the required container-scoped Blob Data
Reader authority. Infrastructure, role assignment, image packaging and
provenance, Container Apps deployment, ingress/Entra authorization, cold-start
behavior, and native managed-identity acceptance remain separate qualification
work. Handler fixtures prove the request and failure contracts without Azure
authority. The clean-process fixture proves local composition and lifecycle,
not a deployed Container App or a successful managed-identity token exchange.

The platform contract follows Microsoft Learn's [managed identities in Azure
Container Apps](https://learn.microsoft.com/azure/container-apps/managed-identity).
