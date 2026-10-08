# APIM MCP Secure — Azure Function App, Azure DevOps and Fabric MCP with OBO Auth

An Azure Function App with two HTTP endpoints, plus pass-throughs to the hosted Azure DevOps and Fabric Core MCP servers, deployed behind Azure API Management (APIM). APIM advertises OAuth 2.0 Protected Resource Metadata (PRM) and uses On-Behalf-Of (OBO) token exchange so downstream calls run with the signed-in user's delegated permissions.

## Architecture

```
MCP Client
    │  (Bearer token with access_mcp scope)
    ▼
┌─────────────────────────────────────────────────┐
│  Azure API Management (MCP Server)              │
│                                                 │
│  obo-mcp-server API                             │
│    ├── GET /echo?name=...  → pass-through       │
│    └── GET /me → OBO exchange → Graph token     │
│  azure-devops-mcp API                           │
│    └── /mcp → OBO exchange → Azure DevOps MCP   │
│  fabric-mcp API                                 │
│    └── /mcp → OBO exchange → Fabric Core MCP    │
│                                                 │
│  mcp-auth API                                   │
│    └── /.well-known/oauth-protected-resource    │
│        (returns PRM JSON)                       │
└──────────────────────┬──────────────────────────┘
                       │
                       ▼
              ┌────────────────┐       ┌──────────────────┐
              │  Function App  │──────▶│ Microsoft Graph  │
              │  (.NET 8)      │       │ GET /v1.0/me     │
              └────────────────┘       └──────────────────┘
```

APIM links the Azure DevOps MCP API to the `azure-devops-mcp-backend` resource using `backendId`. The backend's exact endpoint is `https://mcp.dev.azure.com/{organization}` (no `/mcp` suffix). The public APIM endpoint remains `/azure-devops-mcp/mcp`.

The Fabric API uses the same external MCP pattern, linking to `fabric-mcp-backend` at the exact endpoint `https://api.fabric.microsoft.com/v1/mcp/core`. Its public APIM endpoint is `/fabric-mcp/mcp`. Both preserve the native toolset without defining individual REST operations or synthetic MCP tools.

### Auth Flow (GetMe)

1. MCP client authenticates with Entra ID → gets token with `access_mcp` scope
2. Client calls APIM with `Authorization: Bearer <token>`
3. APIM validates the JWT and performs OBO exchange (swaps `access_mcp` token for `User.Read` Graph token), authenticating the backend app with a federated managed-identity assertion
4. APIM forwards request to Function App with the Graph token in the `Authorization` header
5. Function App's GetMe endpoint calls Microsoft Graph `/me` and returns the user profile

### Auth Flow (Azure DevOps MCP pass-through)

1. The MCP client authenticates to the APIM MCP endpoint with the same `access_mcp` token.
2. APIM validates that token, then exchanges it using OBO for the configured delegated Azure DevOps MCP scope.
3. APIM forwards MCP Streamable HTTP requests to `https://mcp.dev.azure.com/{organization}` with the user's Azure DevOps MCP token.
4. The hosted server returns its native tool list and handles tool calls. For this demo, ask the client to list projects.

The user must have access to the Azure DevOps organization and projects. The delegated app permission limits what the client application can request; Azure DevOps still enforces the signed-in user's own permissions.

### Auth Flow (Fabric Core MCP pass-through)

1. The MCP client requests the existing backend API's `access_mcp` scope and calls `/fabric-mcp/mcp`.
2. APIM validates the inbound token against the configured API URI or backend app client ID.
3. APIM exchanges that token using the same OBO app registration for `https://api.fabric.microsoft.com/.default`.
4. APIM forwards Streamable HTTP requests to `https://api.fabric.microsoft.com/v1/mcp/core` using the resulting delegated Fabric token.
5. Fabric returns its native tools and enforces the signed-in user's workspace/item permissions for each call.

The client-facing scope remains `access_mcp`; clients must not request Fabric tokens directly for the APIM endpoint. `.default` requests the Fabric delegated permissions already configured and consented on the OBO app; it does not grant permissions or consent by itself.

## Prerequisites

The sample exposes the hosted Azure DevOps MCP server at `/azure-devops-mcp/mcp` and Fabric Core MCP at `/fabric-mcp/mcp`. The existing Function App and Graph example remain in place.

- [Azure Developer CLI (azd)](https://learn.microsoft.com/azure/developer/azure-developer-cli/install-azd)
- [.NET 8 SDK](https://dotnet.microsoft.com/download/dotnet/8.0)
- [Azure Functions Core Tools v4](https://learn.microsoft.com/azure/azure-functions/functions-run-local)
- An Azure subscription and an Azure DevOps Services organization connected to Microsoft Entra ID
- **2 Entra ID app registrations** (see setup steps below)
- The **Azure DevOps MCP** enterprise application provisioned in the tenant (application ID `2a72489c-aab2-4b65-b93a-a91edccf33b8`)
- For the Fabric demo, an active Fabric tenant in the configured Entra tenant and at least one workspace the signed-in user can access

## Entra ID App Registration Setup

You need two app registrations: a **client app** (used by the MCP client) and a **backend API app** (defines the `access_mcp` scope and performs OBO to Microsoft Graph, Azure DevOps MCP and Fabric). All OBO policies authenticate the backend app using a user-assigned managed identity as a federated credential; no OBO client secret is required.

### App 1 — Client App (MCP Client)

This is the public client your MCP client tool uses to sign users in and request tokens.

1. In the [Azure Portal](https://portal.azure.com), go to **Microsoft Entra ID → App registrations → New registration**.
2. Name it (e.g., `mcp-client`), leave the redirect URI blank for now, and click **Register**.
3. Note the **Application (client) ID** — this is what your MCP client will use.
4. Under **Authentication**, enable **Allow public client flows** (required for device code / interactive flows).
5. Add the `http://localhost:3456` loopback redirect URI under **Mobile and desktop applications** for the local `scripts/get-token.sh` helper.
6. No client secret needed for this app.

### App 2 — Backend API App (OBO Middle-Tier)

This app defines the `access_mcp` scope that the client requests, and performs OBO exchanges for Microsoft Graph, Azure DevOps MCP and Fabric on behalf of the user.

1. Register a new app (e.g., `mcp-backend-api`).
2. Note the **Application (client) ID** → this becomes `OBO_CLIENT_ID`.
3. **Expose an API:**
   - Set the **Application ID URI** to `api://<OBO_CLIENT_ID>` → this becomes `MCP_CLIENT_AUDIENCE`.
   - Add a scope named `access_mcp` (e.g., display name: "Access MCP Server"), set to **Admins and users**.
   - Under **Authorized client applications**, add App 1's client ID and authorize it for the `access_mcp` scope.
4. **API permissions:**
   - Add `Microsoft Graph → User.Read` (delegated).
   - Add the delegated permission(s) required by the Azure DevOps MCP remote server. Follow the procedure below to provision the enterprise application if needed and inspect the permissions it actually publishes.
   - Add the Fabric delegated permissions described below if using the Fabric passthrough.
5. After provisioning, configure the **federated credential** described below instead of creating a client secret.

### Federated credential for APIM's OBO identity

Bicep creates `id-obo-<resourceToken>` and attaches it to APIM as a **user-assigned managed identity**. APIM keeps its existing system-assigned identity for Application Insights. The user-assigned identity and App 2 must belong to the same Entra tenant.

After provisioning, open **App 2 → Certificates & secrets → Federated credentials → Add credential**. Select the **Managed identity** scenario and choose the newly created user-assigned identity. If configuring the fields manually, use:

| Field | Value |
|---|---|
| Issuer | `https://login.microsoftonline.com/<ENTRAID_TENANT_ID>/v2.0` |
| Subject | Identity's **principal/object ID**, exported as `AZURE_OBO_MANAGED_IDENTITY_PRINCIPAL_ID` |
| Audience | `api://AzureADTokenExchange` |
| Name | For example, `apim-obo-managed-identity` |

The identity's **client ID**, exported as `AZURE_OBO_MANAGED_IDENTITY_CLIENT_ID`, goes into the APIM named value `obo-managed-identity-client-id`; it is **not** the federated credential's subject. The backend app's `OBO_CLIENT_ID` stays unchanged. The identity needs no downstream API permissions or Azure RBAC assignments for this exchange: delegated permissions and consent remain on App 2.

Each OBO policy saves the incoming user token, obtains a managed-identity token for `api://AzureADTokenExchange`, and sends that credential as `client_assertion` with `client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer`. The user token remains the separate `assertion`, with `requested_token_use=on_behalf_of`. Only the resulting delegated OBO token is forwarded downstream; the managed-identity token is not a replacement for the user's token. Managed-identity acquisition fails closed, and APIM caches the credential token until expiry.

**Migration warning:** provisioning switches Graph, Azure DevOps and Fabric OBO policies immediately. OBO calls will fail until you create the matching federated credential and it propagates. Schedule this transition accordingly; clients, API URLs, audiences and delegated consent do not change. Bicep does not create or modify the app registration's federated credentials.

After verifying all three OBO paths, revoke the old backend client secret and remove its unused `obo-client-secret` APIM named value, `OBO_CLIENT_SECRET` azd environment value and GitHub Actions secret. Incremental provisioning does not delete the old named value automatically. Do not revoke the old secret before verification if you need it for rollback to the previous policies.

Reference: [Configure an application to trust a managed identity](https://learn.microsoft.com/entra/workload-id/workload-identity-federation-config-app-trust-managed-identity).

### Provision the Azure DevOps MCP enterprise application and grant permission

The hosted remote server's Entra enterprise application must exist in your tenant before App 2 can request a delegated token for it. Microsoft documents this as creating the service principal for the Azure DevOps MCP app. This step creates the enterprise application entry; it does not grant Azure DevOps access or change Azure resources.

1. Sign in to the tenant that backs the Azure DevOps organization with an account that has the **Application Administrator**, **Cloud Application Administrator**, or **Global Administrator** role:

   ```bash
   az login --tenant <entra-tenant-id> --allow-no-subscriptions
   az account show --query "{tenant:tenantId,user:user.name}" -o table
   ```

   Confirm the displayed tenant ID is the tenant for the Azure DevOps organization.
2. Check whether the service principal already exists:

   ```bash
   az rest --method get \
     --url "https://graph.microsoft.com/v1.0/servicePrincipals(appId='2a72489c-aab2-4b65-b93a-a91edccf33b8')" \
     --query "{name:displayName,appId:appId,resourceIdentifiers:servicePrincipalNames,scopes:oauth2PermissionScopes[?isEnabled].{value:value,name:adminConsentDisplayName,description:adminConsentDescription}}" \
     -o json
   ```

   If it returns `404` / `Request_ResourceNotFound`, create the service principal:

   ```bash
   az ad sp create --id 2a72489c-aab2-4b65-b93a-a91edccf33b8
   ```

   Run the inspection command again and confirm the result is named **Azure DevOps MCP**. If it already existed, do not create it again.
3. In **Microsoft Entra ID → App registrations → App 2 → API permissions**, select **Add a permission → APIs my organization uses**, find **Azure DevOps MCP** (app ID above), and select **Delegated permissions**. Choose the permission(s) appropriate for the operations you intend to expose, then add them and grant admin consent if required by your tenant.
4. Set `AZDO_MCP_SCOPE` to the scope advertised by the hosted server's OAuth Protected Resource Metadata:

   ```bash
   azd env set AZDO_MCP_SCOPE 'https://mcp.dev.azure.com/.default'
   ```

   This value was verified against the metadata for `FDPO-25-ORG`. To inspect the metadata for your organization:

   ```bash
   curl --fail --silent --show-error \
     'https://mcp.dev.azure.com/.well-known/oauth-protected-resource/<your-organization>' \
     | python3 -m json.tool
   ```

   The response advertises `scopes_supported: ["https://mcp.dev.azure.com/.default"]`. `.default` requests the delegated permissions configured and consented to for App 2 on that resource; it is not an Azure DevOps project permission and does not grant consent by itself. Do not replace it with a guessed project-read scope or the Azure DevOps REST API resource.

   If the enterprise application's enabled delegated scope list is empty, or the required permission cannot be selected and consented to for App 2, stop and resolve the permission setup before deployment. Confirming the advertised scope does not prove that the OBO exchange works: an authenticated end-to-end test is still required.

Reference: [Microsoft's remote Azure DevOps MCP setup](https://learn.microsoft.com/azure/devops/mcp-server/remote-mcp-server?view=azure-devops) and [missing enterprise application troubleshooting](https://learn.microsoft.com/azure/devops/mcp-server/remote-mcp-server-troubleshooting?view=azure-devops#cant-find-the-azure-devops-mcp-enterprise-application-in-the-tenant).

For the demo, the downstream MCP tool is `core_list_projects`. The signed-in user's Azure DevOps organization membership and project permissions still determine which project data the request can return; OAuth delegated consent does not grant the user additional Azure DevOps access.

### Configure Fabric delegated permissions

These are manual Entra configuration steps, not changes performed by `azd provision`:

1. Open the existing **backend API / OBO app** (App 2), then **API permissions → Add a permission → Power BI Service → Delegated permissions**. Fabric API scopes are published under Power BI Service.
2. Configure permissions for the native tools you intend to use:

   | Tool category | Delegated permission |
   |---|---|
   | Workspace listing, management, roles and folders | `Workspace.ReadWrite.All` |
   | Item management and item definitions | `Item.ReadWrite.All` |
   | Capacity listing | `Capacity.Read.All` |
   | OneLake catalog search | `Catalog.Read.All` |

   For a first workspace-listing test, `Workspace.Read.All` is sufficient instead of `Workspace.ReadWrite.All`. The passthrough still publishes the native toolset; tools lacking consented scopes or user permissions will fail rather than gain additional access. Review each operation's **Required Delegated Scopes** in the [Fabric REST reference](https://learn.microsoft.com/rest/api/fabric/) as the upstream toolset evolves.
3. Grant the required consent before connecting. OBO cannot display a downstream consent prompt, so resolve missing Fabric consent on App 2 first.
4. Keep the existing `access_mcp` scope and client authorization unchanged. No Fabric delegated permissions need to be added to the MCP client registration.

The named value `fabric-mcp-scope` defaults to `https://api.fabric.microsoft.com/.default`, verified against the [Fabric connection documentation](https://learn.microsoft.com/rest/api/fabric/articles/mcp-servers/core-remote/get-started-core) and the live [protected-resource metadata](https://api.fabric.microsoft.com/.well-known/oauth-protected-resource/v1/mcp/core). No new azd environment variable is required.

All native tools are exposed, including destructive workspace/item operations and permission changes. Fabric RBAC and delegated scopes remain the authorization boundaries; use client approval controls before allowing writes. The first demo should be **"List all my Fabric workspaces"**, which invokes `list_workspaces`.

### Claude connector without a client secret

Use a dedicated public-client registration with the existing backend API's delegated `access_mcp` permission. Register `https://claude.ai/api/mcp/auth_callback` under **Mobile and desktop applications**, not **Web** or **Single-page application**. Enter that registration's client ID in Claude and leave the client secret blank. Claude uses Authorization Code with S256 PKCE. This configuration was confirmed working for the Azure DevOps passthrough; validate connection and refresh separately for the Fabric connector.

For Claude to connect to Fabric through APIM, add the exact **public APIM Fabric URL** (`https://<apim-name>.azure-api.net/fabric-mcp/mcp`) to App 2's **Application ID URIs**, retaining its existing API URI and Azure DevOps URL. Use v2 access tokens (`api.requestedAccessTokenVersion: 2`); the policy already accepts the backend app's GUID audience. Follow Entra's [identifier URI restrictions](https://learn.microsoft.com/entra/identity-platform/identifier-uri-restrictions) if your tenant rejects the URL; do not use the upstream Fabric URL as App 2's identifier.

Leaving the client secret blank does not make a **Web** redirect a public client. Do not change the working VS Code or confidential-client registration; use the dedicated Claude public client. Backend OBO authentication is separate and uses the federated managed identity described above.

## Quick Start

### 1. Authenticate with Azure

```bash
azd auth login
```

### 2. Initialize the environment

```bash
azd init
```

### 3. Set required environment variables

```bash
azd env set ENTRAID_TENANT_ID <your-tenant-id>
azd env set OBO_CLIENT_ID <app2-client-id>
azd env set MCP_CLIENT_AUDIENCE api://<app2-client-id>
azd env set AZDO_ORGANIZATION <your-azure-devops-organization>
azd env set AZDO_MCP_SCOPE 'https://mcp.dev.azure.com/.default'
azd env set APIM_PUBLISHER_EMAIL <your-email>
azd env set APIM_PUBLISHER_NAME <your-name>
```

Complete the [Azure DevOps MCP enterprise application and permission setup](#provision-the-azure-devops-mcp-enterprise-application-and-grant-permission) before running deployment. The OBO policy requests `https://mcp.dev.azure.com/.default`, which uses App 2's configured and consented delegated permissions for the hosted MCP resource.

For a manual test token, request App 2's `access_mcp` scope with the public client:

```bash
./scripts/get-token.sh <app1-client-id> <tenant-id> api://<app2-client-id>/access_mcp
```

### 4. Deploy to Azure

```bash
azd up
```

This provisions all infrastructure (Function App, APIM, Storage and the OBO user-assigned managed identity) and deploys the Function App code. Before making OBO calls, complete the [federated credential setup](#federated-credential-for-apims-obo-identity) on App 2 using the new identity. The identity name, client ID and principal ID are exported to the azd environment; inspect them with `azd env get-values`.

The `azure-devops-mcp` pass-through preserves the hosted server's native tools, so adding a native Azure DevOps MCP tool does not require a separate Bicep operation. Use APIM's MCP server **Tools** configuration to curate the tools exposed to clients.

If the portal shows the Azure DevOps server's source as **API** rather than an external/passthrough server, update to the latest template and provision again. External MCP passthrough requires a backend resource linked using `backendId`; `serviceUrl` alone did not configure passthrough in this deployment. The template follows the [Azure-Samples external MCP pattern](https://github.com/Azure-Samples/AI-Gateway/blob/main/modules/apim-streamable-mcp/api.bicep), clears the old service URL and synthetic endpoint mapping, and preserves the client URL. The deployed APIM endpoint contract uses a dictionary even though the preview Bicep schema declares an array, so `any()` is limited to `mcpProperties`.

### 5. Connect and try the demo

Configure an MCP client to connect to `https://<apim-name>.azure-api.net/azure-devops-mcp/mcp` using the APIM OAuth flow. The client token is for `MCP_CLIENT_AUDIENCE` and the `access_mcp` scope; APIM performs the separate OBO exchange for Azure DevOps MCP. If testing with the token helper, provide its output through the client's secure bearer-token input rather than saving it in source control. In agent mode, ask: **“List the projects in my Azure DevOps organization.”**

For Fabric, complete the [Fabric delegated permission setup](#configure-fabric-delegated-permissions), then connect to `https://<apim-name>.azure-api.net/fabric-mcp/mcp` using the same APIM OAuth flow. The URL is also exported as `AZURE_APIM_FABRIC_MCP_URL`. In VS Code, add this server alongside your existing servers:

```json
{
  "servers": {
    "fabric-apim": {
      "type": "http",
      "url": "https://<apim-name>.azure-api.net/fabric-mcp/mcp"
    }
  }
}
```

For Claude, use the [secretless public-client configuration](#claude-connector-without-a-client-secret) above. Ask **"List all my Fabric workspaces"** and confirm the result matches the signed-in user's accessible workspaces. Test MCP initialization, tool discovery, a read-only tool call, and token refresh before treating the deployment as end-to-end verified. A successful template build or OBO response alone is not sufficient.

## Local Development

```bash
cd src/FunctionApp
func start
```

The Function App runs locally at `http://localhost:7071`:
- `GET http://localhost:7071/api/echo?name=World` — echoes the parameter
- `GET http://localhost:7071/api/me` — requires a valid Graph API Bearer token

## Project Structure

```
├── azure.yaml                      # azd configuration
├── infra/
│   ├── main.bicep                  # Main Bicep orchestration
│   ├── main.parameters.json        # Parameters
│   ├── abbreviations.json          # Resource naming
│   ├── modules/
│   │   ├── function-app.bicep      # Function App + Storage + ASP
│   │   ├── apim.bicep              # APIM instance + named values
│   │   └── apim-apis.bicep         # APIs, operations, MCP server definitions
│   └── policies/
│       ├── mcp-auth-policy.xml     # PRM metadata response
│       ├── obo-getme-policy.xml    # OBO token exchange for Graph
│       └── obo-remote-mcp-policy.xml # Shared OBO policy for Azure DevOps and Fabric MCP
└── src/
    └── FunctionApp/
        ├── Functions/
        │   ├── Echo.cs             # Echo endpoint
        │   └── GetMe.cs           # GetMe endpoint (Graph API)
        └── openapi.json            # OpenAPI spec for APIM import
```

## APIM Named Values

| Named Value | Source env var | Description | Secret |
|---|---|---|---|
| `entraid-tenant` | `ENTRAID_TENANT_ID` | Entra ID tenant ID | No |
| `obo-client-id` | `OBO_CLIENT_ID` | Backend app (App 2) client ID — used as the OBO actor | No |
| `obo-managed-identity-client-id` | Bicep-created identity | User-assigned identity client ID used to acquire the federated OBO credential | No |
| `mcp-client-audience` | `MCP_CLIENT_AUDIENCE` | Audience APIM validates incoming tokens against — set to `api://<OBO_CLIENT_ID>` | No |
| `azdo-mcp-scope` | `AZDO_MCP_SCOPE` | `https://mcp.dev.azure.com/.default`, advertised by the hosted MCP server and requested during OBO | No |
| `fabric-mcp-scope` | Bicep `fabricMcpScope` default | `https://api.fabric.microsoft.com/.default`, advertised by Fabric Core MCP and requested during OBO | No |

## APIM observability

All MCP authentication policies accept the configured `mcp-client-audience` and the backend app's GUID from the existing `obo-client-id` named value. This supports the configured API URI audience and the GUID audience used by Entra v2 access tokens without hardcoding an application ID. Keep `MCP_CLIENT_AUDIENCE` set to the API URI if you need both forms accepted.

Deployment creates workspace-backed Application Insights (`appi-<resourceToken>`) and a Log Analytics workspace (`log-<resourceToken>`) with 30-day workspace retention. APIM uses its system-assigned managed identity with the Monitoring Metrics Publisher role on Application Insights. The deploying identity must be allowed to create role assignments at that scope. No new environment variables are required.

Application Insights logging is enabled at **All APIs** with 100% sampling for this diagnostic sample, including OAuth metadata requests and failed requests. No headers are selected for logging, and client IP logging is disabled. The shared remote MCP policy emits separate `azdo-mcp` and `fabric-mcp` markers for inbound processing, the OBO token endpoint's HTTP status, and policy errors; those markers do not log tokens, secrets, or token response bodies. Neither passthrough creates an API-level logging override. This instruments APIM, not the Function App's internal code.

**Payload logging is disabled by default:** **Number of payload bytes to log** is **0** for frontend and backend requests and responses at **All APIs**. The template does not create API-specific diagnostic overrides; MCP APIs inherit the global configuration. Request statuses, timings, dependencies, and policy markers remain enabled. You can manually enable payload logging at **APIs → All APIs → Settings → Diagnostics Logs** in the portal for troubleshooting, but the next provisioning run restores the global code-defined zero-byte settings. Payloads can contain sensitive Azure DevOps content or credentials; the OBO exchange contains both user tokens and managed-identity credential tokens. Restrict telemetry access and handle any captured credentials as exposed. Response-body logging can buffer responses and disrupt MCP streaming; disable manual payload logging after diagnosis.

**Existing deployments with the old MCP override:** incremental provisioning does not delete resources removed from Bicep. Delete only the old Azure DevOps API-level Application Insights diagnostic once, so the API inherits **All APIs**. This does not delete the MCP API, global diagnostic, or Application Insights resource:

```bash
az rest --method delete \
  --url "https://management.azure.com/subscriptions/<subscription-id>/resourceGroups/<resource-group>/providers/Microsoft.ApiManagement/service/<apim-name>/apis/azure-devops-mcp/diagnostics/applicationinsights?api-version=2024-05-01"
```

Skip this cleanup for new deployments. After removing the override, configure any temporary payload logging at **All APIs**, not on the MCP server.

To update an existing deployment, pull `main` and run `azd provision` using your existing environment. Function code has not changed, so `azd up` is not required. Restart the APIM MCP connection after provisioning, then allow several minutes for telemetry ingestion.

In the resource group's **Application Insights** resource, open **Logs** and run:

```kusto
requests
| where timestamp > ago(30m)
| where url contains "/azure-devops-mcp" or url contains "/fabric-mcp" or url contains "/.well-known/oauth-protected-resource"
| project timestamp, name, url, resultCode, success, duration, operation_Id
| order by timestamp desc
```

Seeing `/azure-devops-mcp/mcp` confirms the client request reached APIM; a metadata request alone does not confirm an MCP request. Copy an `operation_Id` from the request and correlate policy markers and outgoing dependencies:

For Fabric, look for `/fabric-mcp/mcp`, `fabric-mcp` policy markers and a backend dependency to `api.fabric.microsoft.com`.

```kusto
union withsource=TelemetryTable requests, dependencies, traces
| where timestamp > ago(30m)
| where operation_Id == "<operation_Id from the request>"
| order by timestamp asc
```

Look for the inbound marker, the OBO HTTP status, and any dependency to `mcp.dev.azure.com`. A successful OBO status alone does not establish that APIM forwarded the MCP request. If there is no backend dependency, that is evidence to investigate, not proof of why routing failed. No telemetry can also indicate ingestion/identity propagation delays or logging configuration problems; verify logging with a known request before concluding the client never contacted APIM.

Telemetry ingestion incurs Azure Monitor charges. Reduce the sampling percentage in `infra/modules/monitoring.bicep` after troubleshooting. Do not add authentication headers to the logging configuration.

## Security Notes

- The Function App itself does not validate tokens — APIM acts as the auth gateway
- OBO uses a user-assigned managed identity federated to the backend app; no client secret is provisioned or sent. Restrict APIM policy-edit permissions because policy authors can use the attached identity to authenticate as the backend app.
- The OBO exchange ensures the Function App only receives Graph tokens, never the original client token
- The Azure DevOps pass-through forwards the user's OBO token to the hosted MCP endpoint; it does not use a shared service identity or PAT.
- The Fabric pass-through likewise forwards a delegated OBO token, not an app-only or managed identity token. Fabric still enforces the user's permissions; full native tools include destructive actions.
- The pass-through exposes the hosted server's full native toolset. Restrict the published MCP tools and add APIM access controls/rate limits before exposing it broadly; the sample MCP APIs do not require APIM subscription keys.
- APIM's external MCP pass-through supports tools and resources, but not upstream MCP prompts; the project-listing demo uses a tool.
- MCP streaming can be disrupted if APIM diagnostic settings log response bodies. The template disables payload logging; restore any manual diagnostic overrides to zero for normal operation.
- For defense-in-depth, consider restricting Function App access to APIM only (VNet integration or function access keys)

## Extending the MCP endpoint

Tools provided by `mcp.dev.azure.com` are forwarded without adding a Bicep resource for each tool; for this demo, discover the tool list and call `core_list_projects`. To use another Azure DevOps capability, review its required delegated permissions for App 2 and obtain consent as needed. Keep `AZDO_MCP_SCOPE` set to `https://mcp.dev.azure.com/.default`; the user's Azure DevOps permissions remain the final access boundary.

To add a custom tool that the hosted Azure DevOps MCP server doesn't provide, add a REST operation to the Function App's OpenAPI definition and map that operation in the existing `mcpTools` list in `infra/modules/apim-apis.bicep`.
