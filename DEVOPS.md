# eShop — Couche DevOps

**Josué Kabangu** — DevOps Engineer en apprentissage | Projet portfolio — Phase 1 (2026)  
Déploiement de l'application [dotnet/eShop](https://github.com/dotnet/eShop) (Microsoft Reference App) avec Docker, Kubernetes, Terraform et GitLab CI/CD.

---

## Stack technique

| Outil | Rôle | Phase |
|-------|------|-------|
| Vagrant + VirtualBox | VM de développement locale — infrastructure immuable | ✅ Ph1 |
| Docker + Compose | Conteneurisation + orchestration locale | ✅ Ph1 |
| Kubernetes | Orchestration en production | ⏳ Ph1 |
| Terraform | Infrastructure as Code cloud | ❌ Ph2 |
| GitLab CI/CD | Pipeline de déploiement | ❌ Ph2 |
| Azure / IBM Cloud | Hébergement cloud | ❌ Ph2 |

---

## 🎯 Objectif de la Phase 1

Apprendre à containeriser une application distribuée complexe **à la main**, sans outil d'abstraction (pas d'Aspire), pour comprendre en profondeur :
- La construction d'images Docker multi-stage
- L'orchestration multi-services via Docker Compose
- La gestion de la configuration, des secrets et des dépendances entre services
- Le diagnostic méthodique de pannes (root cause analysis)

**Règle d'or appliquée :** tout a été tapé à la main, rien copié-collé sans compréhension.

---

## Architecture locale (docker-compose)

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
│  APIs .NET (HTTP)                                        │
│  ┌─────────────┐  ┌────────────┐  ┌──────────────────┐  │
│  │ catalog-api │  │ basket-api │  │  ordering-api    │  │
│  │ :5102       │  │ :5103      │  │  :5104           │  │
│  └─────────────┘  └────────────┘  └──────────────────┘  │
│  ┌──────────────┐  ┌──────────┐  ┌──────────────────┐   │
│  │ identity-api │  │  webapp  │  │  webhooks-api    │   │
│  │ :5223        │  │ :5100    │  │  :5110           │   │
│  └──────────────┘  └──────────┘  └──────────────────┘   │
│                                                          │
│  Workers (pas de port)                                   │
│  ┌──────────────────┐  ┌──────────────────┐             │
│  │  order-processor │  │payment-processor │             │
│  └──────────────────┘  └──────────────────┘             │
└──────────────────────────────────────────────────────────┘
```

**4 bases de données** dans le même serveur Postgres : `catalogdb`, `identitydb`, `orderingdb`, `webhooksdb`.

---

## 🏗️ 1. Environnement de travail

### Choix : Vagrant (VM locale) plutôt que VPS ou machine nue

| Option | Retenue ? | Raison |
|--------|-----------|--------|
| Machine locale nue | ❌ | Pollue l'OS hôte, pas reproductible |
| VPS Hostinger | ❌ | Exposition réseau publique prématurée, pas fait pour être détruit/recréé |
| **Vagrant (VM locale)** | ✅ | Jetable, isolée, reproductible — incarne le principe d'**Infrastructure Immuable** dès la Phase 1 |

### Configuration retenue

```ruby
Vagrant.configure("2") do |config|
  config.vm.box = "ubuntu/jammy64"
  config.vm.hostname = "eshop-devops"
  config.vm.network "private_network", ip: "192.168.56.11"

  config.vm.provider "virtualbox" do |vb|
    vb.name = "eshop-devops"
    vb.memory = 6144
    vb.cpus = 4
  end

  # Le repo eshop-devops vit sur Windows — persistant même si la VM est détruite
  config.vm.synced_folder "../eshop-devops", "/home/vagrant/EshopOnContainer",
    owner: "vagrant", group: "vagrant"

  config.vm.provision "shell", inline: <<-SHELL
    set -e
    apt-get update -y
    if ! command -v docker &> /dev/null; then
      curl -fsSL https://get.docker.com | sh
      usermod -aG docker vagrant
    fi
    if ! docker compose version &> /dev/null; then
      apt-get install -y docker-compose-plugin
    fi
    if ! command -v git &> /dev/null; then
      apt-get install -y git
    fi
    # Cloner dotnet/eShop (code Microsoft, toujours disponible sur GitHub)
    if [ ! -d /home/vagrant/EshopOnContainer/eShop/.git ]; then
      git clone https://github.com/dotnet/eShop.git /home/vagrant/EshopOnContainer/eShop
      chown -R vagrant:vagrant /home/vagrant/EshopOnContainer/eShop
    fi
  SHELL
end
```

**Concepts illustrés :**
- **Idempotence** : chaque bloc `if ! command -v X` permet de relancer `vagrant provision` sans dupliquer les installations.
- **Réseau privé (`private_network`)** : IP stable joignable depuis l'hôte — équivalent conceptuel d'un `Service` Kubernetes.
- **synced_folder** : le code DevOps vit sur Windows, monté dans la VM. Si la VM est détruite, le code est toujours là.

> ⚠️ Toujours utiliser `vagrant halt` pour éteindre — `vagrant destroy` supprime la VM et son disque.

### Configuration Git sur la VM

```bash
echo 'export GITHUB_TOKEN="ton_token_ici"' >> ~/.bashrc
source ~/.bashrc
git remote set-url origin https://${GITHUB_TOKEN}@github.com/josuekabangu/eshop-devops.git
git add . && git commit -m "type: description" && git push
```

> ⚠️ Le token dans `~/.bashrc` est en clair — ne jamais commiter ce fichier. Pour la CI/CD (Phase 2), on utilisera des secrets GitLab.

---

## 📦 2. Choix du repository applicatif

### Découverte clé : `dotnet/eShop` utilise .NET Aspire, pas Docker Compose nativement

Le repo `dotnet/eShop` orchestre ses services via un projet **`eShop.AppHost`** écrit en C#, pas via un `docker-compose.yml` classique.

**Décision prise :** traduire nous-mêmes la topologie définie dans `eShop.AppHost/Program.cs` en Dockerfiles + `docker-compose.yml` manuels.

---

## 🐳 3. Dockerfiles — structure retenue

Modèle multi-stage appliqué aux 9 services :

```dockerfile
FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src
COPY eShop/Directory.Packages.props .
COPY eShop/Directory.Build.props .
COPY eShop/nuget.config .
COPY eShop/src ./src
# WebApp uniquement : patch OAuth2 SameSite
# COPY src/WebApp/Extensions.cs src/WebApp/Extensions/Extensions.cs
RUN dotnet restore src/<Service>/<Service>.csproj
RUN dotnet publish src/<Service>/<Service>.csproj -c Release -o /app/publish --no-restore

FROM mcr.microsoft.com/dotnet/aspnet:10.0
WORKDIR /app
ENV ASPNETCORE_URLS=http://+:8080
COPY --from=build /app/publish .
EXPOSE 8080
ENTRYPOINT ["dotnet", "<Service>.dll"]
```

---

## 🐛 4. Bugs rencontrés — diagnostic et résolution

### Bug 1 — Incohérence de casse sur le nom de stage Docker

```dockerfile
FROM mcr.microsoft.com/dotnet/sdk:10.0 AS Build   # ← majuscule
COPY --from=build /app/publish .                   # ← minuscule
```
**Fix :** convention tout-minuscule (`build`) sur les 9 Dockerfiles.

---

### Bug 2 — Variable d'environnement figée dans l'image

```dockerfile
ENV ASPNETCORE_ENVIRONMENT=Production   # ← anti-pattern
```
**Fix :** ligne supprimée, valeur injectée via `docker-compose.yml`.  
**Principe :** *build once, deploy many*.

---

### Bug 3 — Mot de passe Postgres mal mappé + authentification désactivée

```yaml
RABBITMQ_DEFAULT_PASS: ${POSTGRES_PASSWORD}   # ← mauvaise clé
POSTGRES_HOST_AUTH_METHOD: trust               # ← désactive l'auth
```
**Fix :** `POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}`, suppression de `trust`.

---

### Bug 4 — Script d'init Postgres en fins de ligne CRLF (Windows)

```
cannot execute: /docker-entrypoint-initdb.d/01-init-db.sh: required file not found
```
**Fix immédiat :** `sed -i 's/\r$//' init-db.sh`.  
**Fix permanent :** `.gitattributes` avec `*.sh text eol=lf`.

---

### Bug 5 — Race condition sur les migrations Entity Framework

```
order-processor | relation "ordering.orders" does not exist
```
**Root cause :** `depends_on: service_healthy` garantit que Postgres répond, pas que le schéma existe.  
**Décision :** solution différée → `Job` Kubernetes en Phase 1 K8s.

---

### Bug 6 — `invalid_redirect_uri` lors du login OAuth2

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

### Bug 7 — `Correlation failed` : cookie SameSite=None rejeté en HTTP

**Fix dans `Extensions.cs` :**
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
**Principe :** `Identity:Url` → `Identity__Url` (double underscore = séparateur de section ASP.NET Core).

---

### Bug 9 — Double issuer Duende IdentityServer

```
warn: You are using IdentityServer in trial mode and have processed requests for 2 issuers.
      The issuers used were: http://192.168.56.11:5223, http://identity-api:8080.
```
**Root cause :** sans `IssuerUri` fixé, Duende déduit l'issuer depuis l'URL de l'appelant. Navigateur → IP de la VM → `iss = http://192.168.56.11:5223`. basket-api → DNS interne → attend `iss = http://identity-api:8080`. Jamais concordant → JWT rejeté → `Unauthenticated` → 500.

**Fix :**
```csharp
// Program.cs — patché via Dockerfile
options.IssuerUri = builder.Configuration["IdentityServer:IssuerUri"];
```
```yaml
identity-api environment:
  IdentityServer__IssuerUri: "http://192.168.56.11:5223"
```
**Vérification :**
```bash
curl -s http://192.168.56.11:5223/.well-known/openid-configuration | grep issuer
```
**Solution structurelle K8s :** `Ingress` avec domaine unique (`eshop.local`) → un seul issuer par construction.

---

### Bug 10 — Data Protection Keys non persistées

```
warn: Storing keys in a directory '/root/.aspnet/DataProtection-Keys' that may not be persisted outside of the container.
```
**Impact Kubernetes :** chaque Pod génère son trousseau indépendant → cookie Pod A rejeté par Pod B → perte de session aléatoire.  
**Solution (Phase 2/3) :**
```csharp
services.AddDataProtection()
    .PersistKeysToStackExchangeRedis(redisConnection, "DataProtection-Keys");
```
**Principe :** une app peut sembler stateless tout en générant un état cryptographique local qui casse la scalabilité horizontale.

---

## ✅ Progression Phase 1

| Étape | Statut | Détails |
|-------|--------|---------|
| VM Vagrant | ✅ | Ubuntu 22.04, 6 Go RAM, Docker installé |
| 9 Dockerfiles | ✅ | Multi-stage build .NET SDK → ASP.NET runtime |
| Infrastructure (compose) | ✅ | PostgreSQL (4 DBs) + Redis + RabbitMQ |
| catalog-api | ✅ | :5102 |
| basket-api | ✅ | :5103 — Redis + JWT validation |
| ordering-api | ✅ | :5104 — JWT validation |
| order-processor | ✅ | worker |
| payment-processor | ✅ | worker |
| identity-api | ✅ | :5223 — IdentityServer (OIDC) |
| webhooks-api | ✅ | :5110 — JWT validation |
| webhook-client | ✅ | :5114 |
| webapp | ✅ | :5100 |
| Login OAuth2 end-to-end | ✅ | alice connectée — 2026-07-20 |
| IssuerUri fixé (Bug 9) | ✅ | `IdentityServer__IssuerUri` |
| **Phase 1 Docker** | ✅ | **2026-07-22** |
| Manifests Kubernetes (k3s) | 🔄 | Phase suivante |
| Terraform | ❌ | Phase 2 |
| CI/CD GitLab | ❌ | Phase 2 |

---

## 📚 5. Piliers DevOps consolidés

| Concept | Application concrète vécue |
|---------|---------------------------|
| **Idempotence** | Scripts Vagrant et `init-db.sh` — relançables sans effet de bord |
| **Infrastructure Immuable** | VM Vagrant jetable, images Docker sans config figée, synced_folder |
| **GitOps** | Vagrantfile, Dockerfiles, docker-compose.yml versionnés comme source de vérité |
| **Configuration Drift** | VM recyclée depuis un ancien projet, provisioning jamais rejoué |
| **12-Factor / séparation code-config** | Code immuable vs `ConnectionStrings__*` injectés à l'exécution |
| **Stateless vs Stateful** | Services API vs Postgres avec volume dédié |
| **SameSite Cookie Policy** | Chrome/Edge 80+ rejettent `SameSite=None` sans `Secure` en HTTP |
| **Issuer OIDC stable** | IssuerUri déduit selon l'appelant → 2 issuers → JWT rejeté |
| **Data Protection Keys** | État cryptographique local invisible → casse la scalabilité horizontale |

---

## 🚀 Démarrage rapide

```bash
git clone https://github.com/josuekabangu/eshop-devops.git && cd eshop-devops
cp .env.example docker/.env          # remplir les variables
cd docker && docker compose up -d
docker compose ps
```

| Service | URL |
|---------|-----|
| WebApp | http://192.168.56.11:5100 |
| RabbitMQ UI | http://192.168.56.11:15672 |
| Identity | http://192.168.56.11:5223 |

---

## 🔜 6. Transition vers k3s

- **`StatefulSet`** pour Postgres — identité de Pod stable + volume dédié
- **`Job`** pour les migrations EF — résout le Bug 5 correctement (1 exécution, pas N par replica)
- **`Ingress`** avec `eshop.local` — résout le Bug 9 par construction (1 issuer unique)
- **Data Protection Keys sur Redis** — résout le Bug 10 avant de scaler identity-api

---

## Roadmap

| Phase | Objectif | Outils |
|-------|----------|--------|
| **Ph1 — Docker** ✅ | 9 microservices + compose | Docker, Vagrant |
| **Ph1 — K8s** 🔄 | Déployer sur k3s local | k3s, kubectl |
| **Ph2 — IaC** | Provisionner le cloud | Terraform, Azure |
| **Ph2 — CI/CD** | Pipeline automatisé | GitLab CI/CD |
