# APIM MCP Secure — Azure Function App and Azure DevOps MCP with OBO Auth

An Azure Function App with two HTTP endpoints, plus a pass-through to the hosted Azure DevOps MCP server, deployed behind Azure API Management (APIM). APIM advertises OAuth 2.0 Protected Resource Metadata (PRM) and uses On-Behalf-Of (OBO) token exchange so downstream calls run with the signed-in user's delegated permissions.

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

APIM also forwards MCP traffic to `https://mcp.dev.azure.com/{organization}/mcp`.

### Auth Flow (GetMe)

1. MCP client authenticates with Entra ID → gets token with `access_mcp` scope
2. Client calls APIM with `Authorization: Bearer <token>`
3. APIM validates the JWT and performs OBO exchange (swaps `access_mcp` token for `User.Read` Graph token)
4. APIM forwards request to Function App with the Graph token in the `Authorization` header
5. Function App's GetMe endpoint calls Microsoft Graph `/me` and returns the user profile

### Auth Flow (Azure DevOps MCP pass-through)

1. The MCP client authenticates to the APIM MCP endpoint with the same `access_mcp` token.
2. APIM validates that token, then exchanges it using OBO for the configured delegated Azure DevOps MCP scope.
3. APIM forwards MCP Streamable HTTP requests to `https://mcp.dev.azure.com/{organization}/mcp` with the user's Azure DevOps MCP token.
4. The hosted server returns its native tool list and handles tool calls. For this demo, ask the client to list projects.

The user must have access to the Azure DevOps organization and projects. The delegated app permission limits what the client application can request; Azure DevOps still enforces the signed-in user's own permissions.

## Prerequisites

The sample exposes the hosted Azure DevOps MCP server at `/azure-devops-mcp/mcp`. The existing Function App and Graph example remain in place.

- [Azure Developer CLI (azd)](https://learn.microsoft.com/azure/developer/azure-developer-cli/install-azd)
- [.NET 8 SDK](https://dotnet.microsoft.com/download/dotnet/8.0)
- [Azure Functions Core Tools v4](https://learn.microsoft.com/azure/azure-functions/functions-run-local)
- An Azure subscription and an Azure DevOps Services organization connected to Microsoft Entra ID
- **2 Entra ID app registrations** (see setup steps below)
- The **Azure DevOps MCP** enterprise application provisioned in the tenant (application ID `2a72489c-aab2-4b65-b93a-a91edccf33b8`)

## Entra ID App Registration Setup

You need two app registrations: a **client app** (used by the MCP client) and a **backend API app** (defines the `access_mcp` scope and performs OBO to Microsoft Graph and Azure DevOps MCP).

### App 1 — Client App (MCP Client)

This is the public client your MCP client tool uses to sign users in and request tokens.

1. In the [Azure Portal](https://portal.azure.com), go to **Microsoft Entra ID → App registrations → New registration**.
2. Name it (e.g., `mcp-client`), leave the redirect URI blank for now, and click **Register**.
3. Note the **Application (client) ID** — this is what your MCP client will use.
4. Under **Authentication**, enable **Allow public client flows** (required for device code / interactive flows).
5. Add the `http://localhost:3456` loopback redirect URI under **Mobile and desktop applications** for the local `scripts/get-token.sh` helper.
6. No client secret needed for this app.

### App 2 — Backend API App (OBO Middle-Tier)

This app defines the `access_mcp` scope that the client requests, and performs OBO exchanges for Microsoft Graph and Azure DevOps MCP on behalf of the user.

1. Register a new app (e.g., `mcp-backend-api`).
2. Note the **Application (client) ID** → this becomes `OBO_CLIENT_ID`.
3. **Expose an API:**
   - Set the **Application ID URI** to `api://<OBO_CLIENT_ID>` → this becomes `MCP_CLIENT_AUDIENCE`.
   - Add a scope named `access_mcp` (e.g., display name: "Access MCP Server"), set to **Admins and users**.
   - Under **Authorized client applications**, add App 1's client ID and authorize it for the `access_mcp` scope.
4. **API permissions:**
   - Add `Microsoft Graph → User.Read` (delegated).
   - Add the delegated permission(s) required by the Azure DevOps MCP remote server. Follow the procedure below to provision the enterprise application if needed and inspect the permissions it actually publishes.
5. **Certificates & secrets:** Create a new client secret → this becomes `OBO_CLIENT_SECRET`.

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
4. Set `AZDO_MCP_SCOPE` to the fully qualified delegated scope: the enterprise application's resource identifier from `resourceIdentifiers`, followed by `/` and the selected enabled scope `value` from `scopes` (for example, `<resource-identifier>/<scope-value>`). Do not guess a scope from its display name. If the scope list is empty, or there is no suitable delegated permission for the project-listing tool, stop: the OBO deployment is not ready and you must resolve the Entra app permission with your tenant admin or Microsoft documentation/support before running `azd up`.

For the demo, the downstream MCP tool is `core_list_projects`. The signed-in user's Azure DevOps organization membership and project permissions still determine which project data the request can return; OAuth delegated consent does not grant the user additional Azure DevOps access.

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
azd env set OBO_CLIENT_SECRET <app2-client-secret>
azd env set MCP_CLIENT_AUDIENCE api://<app2-client-id>
azd env set AZDO_ORGANIZATION <your-azure-devops-organization>
azd env set AZDO_MCP_SCOPE <fully-qualified-azure-devops-mcp-delegated-scope>
azd env set APIM_PUBLISHER_EMAIL <your-email>
azd env set APIM_PUBLISHER_NAME <your-name>
```

Complete the [Azure DevOps MCP enterprise application and permission setup](#provision-the-azure-devops-mcp-enterprise-application-and-grant-permission) before setting `AZDO_MCP_SCOPE` or running deployment. `AZDO_MCP_SCOPE` must be the exact scope URI/identifier confirmed in the service principal and granted to App 2; if the enterprise app publishes multiple scopes, include only the required delegated scopes as space-separated values.

For a manual test token, request App 2's `access_mcp` scope with the public client:

```bash
./scripts/get-token.sh <app1-client-id> <tenant-id> api://<app2-client-id>/access_mcp
```

### 4. Deploy to Azure

```bash
azd up
```

This provisions all infrastructure (Function App, APIM, Storage) and deploys the Function App code.

The `azure-devops-mcp` pass-through preserves the hosted server's native tools, so adding a native Azure DevOps MCP tool does not require a separate Bicep operation. Use APIM's MCP server **Tools** configuration to curate the tools exposed to clients.

### 5. Connect and try the demo

Configure an MCP client to connect to `https://<apim-name>.azure-api.net/azure-devops-mcp/mcp` using the APIM OAuth flow. The client token is for `MCP_CLIENT_AUDIENCE` and the `access_mcp` scope; APIM performs the separate OBO exchange for Azure DevOps MCP. If testing with the token helper, provide its output through the client's secure bearer-token input rather than saving it in source control. In agent mode, ask: **“List the projects in my Azure DevOps organization.”**

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
│       └── obo-azdo-mcp-policy.xml # OBO token exchange for Azure DevOps MCP
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
| `obo-client-secret` | `OBO_CLIENT_SECRET` | Backend app (App 2) client secret — used for OBO token exchange | Yes |
| `mcp-client-audience` | `MCP_CLIENT_AUDIENCE` | Audience APIM validates incoming tokens against — set to `api://<OBO_CLIENT_ID>` | No |
| `azdo-mcp-scope` | `AZDO_MCP_SCOPE` | Fully qualified delegated scope on the Azure DevOps MCP API used by the OBO exchange | No |

## Security Notes

- The Function App itself does not validate tokens — APIM acts as the auth gateway
- Client secrets are stored as APIM secret named values (consider Key Vault-backed named values for production)
- The OBO exchange ensures the Function App only receives Graph tokens, never the original client token
- The Azure DevOps pass-through forwards the user's OBO token to the hosted MCP endpoint; it does not use a shared service identity or PAT.
- The pass-through exposes the hosted server's full native toolset. Restrict the published MCP tools and add APIM access controls/rate limits before exposing it broadly; the sample MCP APIs do not require APIM subscription keys.
- APIM's external MCP pass-through supports tools and resources, but not upstream MCP prompts; the project-listing demo uses a tool.
- MCP streaming can be disrupted if APIM diagnostic settings log response bodies. Keep response-body logging disabled for this MCP API.
- For defense-in-depth, consider restricting Function App access to APIM only (VNet integration or function access keys)

## Extending the MCP endpoint

Tools provided by `mcp.dev.azure.com` are forwarded without adding a Bicep resource for each tool; for this demo, discover the tool list and call the upstream project-listing tool. To use another Azure DevOps capability, grant only its required delegated permission to App 2 and update `AZDO_MCP_SCOPE` to the exact fully qualified scope value. If multiple delegated scopes are required, provide their space-separated scope URIs.

To add a custom tool that the hosted Azure DevOps MCP server doesn't provide, add a REST operation to the Function App's OpenAPI definition and map that operation in the existing `mcpTools` list in `infra/modules/apim-apis.bicep`.
