# Private viewer foundation

`infra/modules/maester-viewer-private.bicep` is an unreferenced source module for
the next MCAJ-007 phase. It composes the existing managed environment and the
existing `viewer-projection` blob container into one private Container App with
two normal containers: the reviewed PowerShell worker on loopback port 8081 and
the reviewed Caddy sidecar listening on port 8080 and proxying only to the
worker's loopback listener. The image entrypoints remain
owned by the images; the module supplies only the worker's canonical arguments.

The module creates one dedicated user-assigned identity and one
container-scoped `Storage Blob Data Reader` assignment. It has no system
identity, storage key, SAS, archive/latest access, writer role, registry
credentials, secret, volume, init container, ingress, hostname, auth
configuration, DNS, or certificate. The two containers share the attached
identity boundary. Image parameters must be immutable lowercase SHA-256
references from the currently supported public registry prefixes; registry
identity and signature verification are separate review gates.

The module is deliberately not referenced by `infra/main.bicep`, AZD hooks, or
the legacy `-IncludeWebApp` path. It is an unwired private experiment and is
not an authenticated, released, or reachable report viewer. It does not create
the projection container, publish reports, configure tenant/audience/group
authorization, or claim image provenance. `replicaFloor` is required and
bounded to 1 through 3; setting equal min/max replicas disables autoscaling in
this foundation. MCAJ-007 remains open pending immutable release provenance,
runner publication, HTTPS and native authorization, end-to-end denial/allow
tests, lifecycle rollback, and owned cleanup evidence.

Azure requires resource locations at deployment start, so `location` is an
explicit input. Before creating the Container App, the module reads the existing
managed environment and rejects a region mismatch. A failed deployment can still
leave the identity or Reader assignment created; deployment is not atomic.
The module validates the managed-environment and storage-account IDs against the
current subscription and resource group, and supplies the selected subscription's
lowercase tenant ID to the worker after checking the requested tenant.

The focused tests compile with Bicep 0.46.1 using typed stable 2025-07-01 Container
Apps APIs and inspect the exact resource, argument, identity and role graph.
Input-guard assertions are source/compiled-contract checks; native ARM rejection
of invalid parameters and deployment behavior remain untested in this phase.

The separate [staged authentication module](viewer-authentication.md) defines
the later Entra group policy. It also remains unreferenced and requires the app
to stay private while authentication is configured and read back.
