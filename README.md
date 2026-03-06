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
- **3 Entra ID app registrations** (already created):
  1. **Client app** — used by the MCP client to get tokens
  2. **Middle-tier API app** — defines `access_mcp` scope, performs OBO, has `User.Read` delegated permission
  3. **APIM/Resource app** (if separate)

## Quick Start

### 1. Initialize the environment

```bash
azd init
```

### 2. Set required environment variables

```bash
azd env set ENTRAID_TENANT_ID <your-tenant-id>
azd env set OBO_CLIENT_ID <middle-tier-app-client-id>
azd env set OBO_CLIENT_SECRET <middle-tier-app-client-secret>
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

| Named Value | Description | Secret |
|---|---|---|
| `entraid-tenant` | Entra ID tenant ID | No |
| `obo-client-id` | Middle-tier app registration client ID | No |
| `obo-client-secret` | Middle-tier app registration client secret | Yes |

## Security Notes

- The Function App itself does not validate tokens — APIM acts as the auth gateway
- Client secrets are stored as APIM secret named values (consider Key Vault-backed named values for production)
- The OBO exchange ensures the Function App only receives Graph tokens, never the original client token
- For defense-in-depth, consider restricting Function App access to APIM only (VNet integration or function access keys)
