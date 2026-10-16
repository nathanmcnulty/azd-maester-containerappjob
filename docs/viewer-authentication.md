# Staged viewer authentication

`infra/modules/maester-viewer-auth.bicep` is an unreferenced source module for a
later MCAJ-007 deployment stage. It writes the `current` auth configuration for
one existing Maester viewer Container App. It does not create or update the
Container App, ingress, identity, role assignments, application registration,
group, secret, DNS, or certificate.

The module accepts the exact existing Container App resource ID, the selected
subscription tenant ID, one existing Entra application client ID, and exactly
one approved Entra group ID. The tenant, client, and group inputs must be
canonical lowercase, nonzero GUIDs. The full app resource ID must resolve to the
current subscription and resource group. The tenant must match the selected
subscription, and the deployment must run in AzureCloud. The fixed setting name
`viewer-entra-client-secret` must
already exist on the Container App and reference the relying-party client
secret. No secret value is an input to this module.

The generated stable `Microsoft.App/containerApps/authConfigs@2025-07-01`
resource enables only Microsoft Entra ID. It uses the exact tenant v2 issuer,
accepts only the configured client ID as an explicit audience, and applies a
group-only default authorization policy containing the one approved group. It
does not add an allowed application or identity path. Anonymous requests return
401. There are no excluded paths or external redirect URLs. HTTPS is required,
forwarded host and protocol headers are ignored with `NoProxy`, and the token
store is disabled. After a later HTTPS ingress stage, an interactive browser can
start the server-directed flow at `/.auth/login/aad`; anonymous report requests
are not redirected automatically by this configuration.

## Deployment order

This module is deliberately not referenced by `infra/main.bicep` or any AZD
hook. A future owned deployment must stage the operations:

1. Create and read back the private Container App with ingress absent.
2. Provision the existing app setting and its secret through a separately
   reviewed secret-handling path.
3. Deploy this auth child resource and read back the complete auth policy.
4. Only after that readback, enable reviewed HTTPS ingress in a separate
   operation and validate the externally reachable authorization boundary.

The module reads the existing app and binds the auth properties to a fail-closed
check that `properties.configuration.ingress` remains absent. This is a template
guard, not native deployment evidence. The staged order avoids a joint ARM
update that could expose ingress before the child auth policy is present.

## Evidence boundary

Offline tests compile the module with pinned Bicep 0.46.1 and inspect the exact
resource graph, policy, ID bindings, and compiled ingress guard. No deployment,
secret lookup, Entra write, Graph call, consent, role grant, or ingress change is
performed.

Native allowed-user and denied-user behavior remains unproven. Group membership,
group-claim overage behavior, forged identity-header rejection, host and proxy
header handling, anonymous 401 behavior, `/.auth/login/aad`, callback behavior,
session cookies, client-secret resolution, and policy readback all require an
owned staged Azure acceptance run. Before that run, the Entra application must
also be configured to emit group claims suitable for this policy. Missing or
overage group claims must deny access; this module cannot create or repair those
claims. The module by itself does not prove a SaaS authorization claim or make
the private viewer reachable.
