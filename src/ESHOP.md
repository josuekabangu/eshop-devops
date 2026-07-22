# Architecture applicative — eShop

Source : [dotnet/eShop](https://github.com/dotnet/eShop) — application de référence Microsoft, 12 services .NET 9/10 orchestrés initialement via .NET Aspire, retraduits en Docker Compose puis Kubernetes.

---

## Les 12 services

| Service | Type | Port | Rôle |
|---------|------|------|------|
| `catalog-api` | API REST | 5102 | Catalogue produits (PostgreSQL + pgvector) |
| `basket-api` | API REST | 5103 | Panier (Redis) |
| `ordering-api` | API REST | 5104 | Commandes (PostgreSQL, DDD) |
| `identity-api` | Identity | 5223 | Auth OAuth2/OIDC — Duende IdentityServer |
| `webhooks-api` | API REST | 5110 | Gestion webhooks (PostgreSQL) |
| `webapp` | Blazor | 5100 | Interface utilisateur (BFF + OIDC) |
| `webhooks-client` | Web | 5114 | Client de test pour webhooks |
| `order-processor` | Worker | — | Consomme événements RabbitMQ → EF migrations |
| `payment-processor` | Worker | — | Traitement paiement fictif |
| `postgres` | Infra | 5432 | 4 bases : catalog, identity, ordering, webhooks |
| `redis` | Infra | 6379 | Cache basket-api |
| `rabbitmq` | Infra | 5672 | Message broker (order events) |

---

## Flux OAuth2 (Authorization Code + PKCE)

```
Browser            WebApp (BFF)         identity-api         basket-api
   │                    │                    │                    │
   │  Clic "Login"      │                    │                    │
   │──────────────────▶ │                    │                    │
   │                    │ /connect/authorize  │                    │
   │                    │──────────────────▶ │                    │
   │◀───────────────────│                    │                    │
   │ redirect login page│                    │                    │
   │───────────────────────────────────────▶ │                    │
   │ POST credentials   │                    │                    │
   │                    │                    │ code               │
   │◀───────────────────────────────────────│                    │
   │ redirect + ?code=  │                    │                    │
   │──────────────────▶ │                    │                    │
   │                    │ /connect/token     │                    │
   │                    │──────────────────▶ │                    │
   │                    │◀──────────────────│                    │
   │                    │ access_token (JWT) │                    │
   │                    │                    │ Authorization:     │
   │                    │────────────────────────────────────────▶
   │                    │                    │ Bearer <jwt>       │
```

**Issuer** = `http://192.168.56.11:5223` — fixé via `IdentityServer__IssuerUri` (Bug 9).  
Les APIs valident le JWT avec `identity-api` comme autorité.

---

## Patches appliqués

### Patch 1 — Extensions.cs (Bug 7 SameSite)

Fichier : `src/WebApp/Extensions.cs` (copie dans `src/WebApp/Extensions/Extensions.cs`)

```csharp
// Options OpenIdConnect — remplace les valeurs par défaut Microsoft
options.ResponseMode = "query";
options.CorrelationCookie.SameSite = SameSiteMode.Lax;
options.NonceCookie.SameSite = SameSiteMode.Lax;
options.CorrelationCookie.SecurePolicy = CookieSecurePolicy.None;
options.NonceCookie.SecurePolicy = CookieSecurePolicy.None;
```

**Pourquoi :** Chrome/Edge 80+ rejette les cookies `SameSite=None` sans `Secure` (HTTPS). En développement HTTP, on descend à `Lax` et on désactive `SecurePolicy`.

**Application via Dockerfile (pas Vagrantfile) :**
```dockerfile
COPY eShop/src ./src
COPY src/WebApp/Extensions.cs src/WebApp/Extensions/Extensions.cs
RUN dotnet restore src/WebApp/WebApp.csproj
RUN dotnet publish ...
```

La correction est encodée dans l'image — logique DevOps : le patch appartient à la définition du conteneur.

---

### Patch 2 — Program.cs Identity API (Bug 9 IssuerUri)

Fichier : `src/Identity.API/Program.cs`

```csharp
builder.Services.AddIdentityServer(options =>
{
    options.IssuerUri = builder.Configuration["IdentityServer:IssuerUri"];
    // ...
});
```

Injecté via `docker-compose.yml` :
```yaml
identity-api:
  environment:
    IdentityServer__IssuerUri: "http://192.168.56.11:5223"
```

**Pourquoi `__` double underscore :** convention ASP.NET Core — le runtime traduit `IdentityServer__IssuerUri` en `IdentityServer:IssuerUri` (séparateur de hiérarchie).

---

## Organisation des Dockerfiles

```
eshop-devops/
├── src/
│   ├── CatalogApi/Dockerfile
│   ├── BasketApi/Dockerfile
│   ├── OrderingApi/Dockerfile
│   ├── Identity.API/Dockerfile
│   ├── WebApp/
│   │   ├── Dockerfile          ← inclut le patch Extensions.cs
│   │   └── Extensions.cs       ← copié dans eShop/src/WebApp/Extensions/ au build
│   ├── WebhookClient/Dockerfile
│   ├── Webhooks.API/Dockerfile
│   ├── OrderProcessor/Dockerfile
│   └── PaymentProcessor/Dockerfile
└── docker/
    ├── docker-compose.yml
    ├── .env
    └── init-db/
        └── 01-init-db.sh       ← crée les 4 bases PostgreSQL
```

Le sous-module `eShop/` contient le code source Microsoft non modifié. Les patches sont dans `src/` et appliqués au moment du `docker build`.

---

## Principe : ne pas forker le code source

Les services Microsoft ne sont pas modifiés directement dans `eShop/`. Les patches sont appliqués par couche :

| Niveau | Mécanisme |
|--------|-----------|
| Cookie SameSite | `COPY src/WebApp/Extensions.cs` dans Dockerfile → écrase le fichier avant `dotnet publish` |
| IssuerUri | Env var `IdentityServer__IssuerUri` injectée dans `docker-compose.yml` → lue dans `Program.cs` |
| Config services | Variables `Identity__Url`, `ConnectionStrings__*` via docker-compose |

Cela suit le principe **12-Factor App (III — Config)** : la configuration est séparée du code, injectée à l'exécution.
