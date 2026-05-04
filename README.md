# APIM MCP Secure — Azure Function App with OBO Auth

An Azure Function App with two HTTP endpoints, deployed behind Azure API Management (APIM) configured as an MCP server with OAuth 2.0 Protected Resource Metadata and On-Behalf-Of (OBO) token exchange.

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

### Auth Flow (GetMe)

1. MCP client authenticates with Entra ID → gets token with `access_mcp` scope
2. Client calls APIM with `Authorization: Bearer <token>`
3. APIM validates the JWT and performs OBO exchange (swaps `access_mcp` token for `User.Read` Graph token)
4. APIM forwards request to Function App with the Graph token in the `Authorization` header
5. Function App's GetMe endpoint calls Microsoft Graph `/me` and returns the user profile

## Prerequisites

- [Azure Developer CLI (azd)](https://learn.microsoft.com/azure/developer/azure-developer-cli/install-azd)
- [.NET 8 SDK](https://dotnet.microsoft.com/download/dotnet/8.0)
- [Azure Functions Core Tools v4](https://learn.microsoft.com/azure/azure-functions/functions-run-local)
- An Azure subscription
- **2 Entra ID app registrations** (see setup steps below)

## Entra ID App Registration Setup

You need two app registrations: a **client app** (used by the MCP client) and a **backend API app** (defines the `access_mcp` scope, performs OBO, holds the `User.Read` delegated permission).

### App 1 — Client App (MCP Client)

This is the public client your MCP client tool uses to sign users in and request tokens.

1. In the [Azure Portal](https://portal.azure.com), go to **Microsoft Entra ID → App registrations → New registration**.
2. Name it (e.g., `mcp-client`), leave the redirect URI blank for now, and click **Register**.
3. Note the **Application (client) ID** — this is what your MCP client will use.
4. Under **Authentication**, enable **Allow public client flows** (required for device code / interactive flows).
5. No client secret needed for this app.

### App 2 — Backend API App (OBO Middle-Tier)

This app defines the `access_mcp` scope that the client requests, and it performs the OBO exchange to get a Graph token on behalf of the user.

1. Register a new app (e.g., `mcp-backend-api`).
2. Note the **Application (client) ID** → this becomes `OBO_CLIENT_ID`.
3. **Expose an API:**
   - Set the **Application ID URI** to `api://<OBO_CLIENT_ID>` → this becomes `MCP_CLIENT_AUDIENCE`.
   - Add a scope named `access_mcp` (e.g., display name: "Access MCP Server"), set to **Admins and users**.
   - Under **Authorized client applications**, add App 1's client ID and authorize it for the `access_mcp` scope.
4. **API permissions:**
   - Add `Microsoft Graph → User.Read` (delegated).
   - Grant admin consent.
5. **Certificates & secrets:** Create a new client secret → this becomes `OBO_CLIENT_SECRET`.

## Quick Start

### 1. Initialize the environment

```bash
azd init
```

### 2. Set required environment variables

```bash
azd env set ENTRAID_TENANT_ID <your-tenant-id>
azd env set OBO_CLIENT_ID <app2-client-id>
azd env set OBO_CLIENT_SECRET <app2-client-secret>
azd env set MCP_CLIENT_AUDIENCE api://<app2-client-id>
azd env set APIM_PUBLISHER_EMAIL <your-email>
azd env set APIM_PUBLISHER_NAME <your-name>
```

### 3. Deploy to Azure

```bash
azd up
```

This provisions all infrastructure (Function App, APIM, Storage) and deploys the Function App code.

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
│   │   └── apim-apis.bicep         # APIs, operations, policies
│   └── policies/
│       ├── mcp-auth-policy.xml     # PRM metadata response
│       └── obo-getme-policy.xml    # OBO token exchange
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

## Security Notes

- The Function App itself does not validate tokens — APIM acts as the auth gateway
- Client secrets are stored as APIM secret named values (consider Key Vault-backed named values for production)
- The OBO exchange ensures the Function App only receives Graph tokens, never the original client token
- For defense-in-depth, consider restricting Function App access to APIM only (VNet integration or function access keys)
