# Docker — Phase 1

Conteneurisation de l'application eShop : 9 Dockerfiles + docker-compose orchestrant 12 services.

---

## Architecture (docker-compose)

```
┌──────────────────────────────────────────────────────────┐
│                     eshop-network                        │
│                                                          │
│  Infrastructure                                          │
│  ┌──────────┐  ┌───────┐  ┌──────────────────────────┐  │
│  │ postgres │  │ redis │  │ rabbitmq                 │  │
│  │ :5432    │  │ :6379 │  │ :5672 / UI :15672        │  │
│  └──────────┘  └───────┘  └──────────────────────────┘  │
│                                                          │
│  APIs .NET                                               │
│  ┌─────────────┐  ┌────────────┐  ┌──────────────────┐  │
│  │ catalog-api │  │ basket-api │  │  ordering-api    │  │
│  │ :5102       │  │ :5103      │  │  :5104           │  │
│  └─────────────┘  └────────────┘  └──────────────────┘  │
│  ┌──────────────┐  ┌──────────┐  ┌──────────────────┐   │
│  │ identity-api │  │  webapp  │  │  webhooks-api    │   │
│  │ :5223        │  │ :5100    │  │  :5110           │   │
│  └──────────────┘  └──────────┘  └──────────────────┘   │
│                                                          │
│  Workers                                                 │
│  ┌──────────────────┐  ┌──────────────────┐             │
│  │  order-processor │  │payment-processor │             │
│  └──────────────────┘  └──────────────────┘             │
└──────────────────────────────────────────────────────────┘
```

4 bases de données dans le même serveur Postgres : `catalogdb`, `identitydb`, `orderingdb`, `webhooksdb`.

---

## Environnement de travail — Vagrant

```ruby
config.vm.box = "ubuntu/jammy64"
config.vm.hostname = "eshop-devops"
config.vm.network "private_network", ip: "192.168.56.11"
config.vm.provider "virtualbox" do |vb|
  vb.memory = 6144
  vb.cpus = 4
end
config.vm.synced_folder "../eshop-devops", "/home/vagrant/EshopOnContainer",
  owner: "vagrant", group: "vagrant"
```

> ⚠️ `vagrant halt` pour éteindre, jamais `vagrant destroy` (supprime VM + disque).  
> Le code vit sur Windows via `synced_folder` — la VM est jetable.

### Configuration Git sur la VM

```bash
echo 'export GITHUB_TOKEN="ton_token_ici"' >> ~/.bashrc
source ~/.bashrc
git remote set-url origin https://${GITHUB_TOKEN}@github.com/josuekabangu/eshop-devops.git
```

---

## Contexte clé : dotnet/eShop utilise .NET Aspire

Le repo Microsoft orchestre ses services en C# (pas en YAML). La topologie a été traduite manuellement depuis `eShop.AppHost/Program.cs` → Dockerfiles + `docker-compose.yml`.

---

## Dockerfiles — pattern multi-stage

```dockerfile
FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src
ENV DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1
ENV DOTNET_CLI_TELEMETRY_OPTOUT=1
COPY eShop/Directory.Packages.props .
COPY eShop/Directory.Build.props .
COPY eShop/nuget.config .
COPY eShop/src ./src
RUN dotnet restore src/<Service>/<Service>.csproj
RUN dotnet publish src/<Service>/<Service>.csproj -c Release -o /app/publish --no-restore

FROM mcr.microsoft.com/dotnet/aspnet:10.0
WORKDIR /app
ENV ASPNETCORE_URLS=http://+:8080
COPY --from=build /app/publish .
EXPOSE 8080
ENTRYPOINT ["dotnet", "<Service>.dll"]
```

**WebApp uniquement** — patch OAuth2 appliqué dans le Dockerfile :
```dockerfile
COPY eShop/src ./src
COPY src/WebApp/Extensions.cs src/WebApp/Extensions/Extensions.cs
RUN dotnet restore ...
```

---

## Bugs rencontrés — diagnostic et résolution

### Bug 1 — Casse du nom de stage Docker

```dockerfile
FROM ... AS Build   # majuscule
COPY --from=build . # minuscule → erreur
```
**Fix :** convention tout-minuscule sur les 9 Dockerfiles.

---

### Bug 2 — Variable d'environnement figée dans l'image

```dockerfile
ENV ASPNETCORE_ENVIRONMENT=Production   # anti-pattern
```
**Fix :** supprimée, injectée via `docker-compose.yml`.  
**Principe :** *build once, deploy many*.

---

### Bug 3 — Mot de passe Postgres mal mappé

```yaml
RABBITMQ_DEFAULT_PASS: ${POSTGRES_PASSWORD}  # mauvaise clé
POSTGRES_HOST_AUTH_METHOD: trust             # masquait le bug
```
**Fix :** `POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}`, suppression de `trust`.

---

### Bug 4 — CRLF sur init-db.sh (Windows)

```
cannot execute: /docker-entrypoint-initdb.d/01-init-db.sh: required file not found
```
**Fix :** `sed -i 's/\r$//' init-db.sh` + `.gitattributes` : `*.sh text eol=lf`.

---

### Bug 5 — Race condition migrations EF Core

```
order-processor | relation "ordering.orders" does not exist
```
**Root cause :** `depends_on: service_healthy` garantit Postgres, pas le schéma EF.  
**Décision :** solution différée → `Job` Kubernetes (Phase 1 K8s).

---

### Bug 6 — `invalid_redirect_uri` (OAuth2)

**Fix :**
```yaml
identity-api environment:
  WebAppClient: "http://192.168.56.11:5100"
  WebhooksWebClient: "http://192.168.56.11:5114"
  BasketApiClient: "http://192.168.56.11:5103"
  OrderingApiClient: "http://192.168.56.11:5104"
  WebhooksApiClient: "http://192.168.56.11:5110"
```

---

### Bug 7 — `Correlation failed` (SameSite cookie)

**Fix dans `src/WebApp/Extensions.cs` :**
```csharp
options.ResponseMode = "query";
options.CorrelationCookie.SameSite = SameSiteMode.Lax;
options.NonceCookie.SameSite = SameSiteMode.Lax;
options.CorrelationCookie.SecurePolicy = CookieSecurePolicy.None;
options.NonceCookie.SecurePolicy = CookieSecurePolicy.None;
```

---

### Bug 8 — `Configuration missing value for: Identity:Url`

**Fix :**
```yaml
# basket-api, ordering-api, webhooks-api
Identity__Url: "http://identity-api:8080"
```

---

### Bug 9 — Double issuer Duende IdentityServer

```
warn: processed requests for 2 issuers: http://192.168.56.11:5223, http://identity-api:8080
```
**Root cause :** sans `IssuerUri` fixé, Duende déduit l'issuer depuis l'appelant. Navigateur → IP VM. basket-api → DNS interne. Jamais concordant → JWT rejeté.

**Fix :**
```yaml
identity-api environment:
  IdentityServer__IssuerUri: "http://192.168.56.11:5223"
```
```csharp
// src/Identity.API/Program.cs — patché via Dockerfile
options.IssuerUri = builder.Configuration["IdentityServer:IssuerUri"];
```
**Solution K8s :** `Ingress` avec `eshop.local` → un seul issuer par construction.

---

### Bug 10 — Data Protection Keys non persistées

```
warn: Storing keys in a directory that may not be persisted outside of the container.
```
**Impact K8s :** cookie Pod A rejeté par Pod B → perte de session aléatoire.  
**Solution (Phase 2/3) :**
```csharp
services.AddDataProtection()
    .PersistKeysToStackExchangeRedis(redisConnection, "DataProtection-Keys");
```

---

## Démarrage rapide

```bash
cp .env.example docker/.env   # remplir les variables
cd docker
docker compose up -d
docker compose ps
```

| Service | URL |
|---------|-----|
| WebApp | http://192.168.56.11:5100 |
| RabbitMQ UI | http://192.168.56.11:15672 |
| Identity | http://192.168.56.11:5223 |

---

## Progression Phase 1 Docker

| Étape | Statut |
|-------|--------|
| VM Vagrant + synced_folder | ✅ |
| 9 Dockerfiles multi-stage | ✅ |
| PostgreSQL + Redis + RabbitMQ | ✅ |
| 9 microservices .NET | ✅ |
| Login OAuth2 end-to-end | ✅ |
| IssuerUri fixé (Bug 9) | ✅ |
| **Phase 1 Docker complète** | **✅ 2026-07-22** |
