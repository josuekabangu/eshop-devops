# eShop — DevOps Portfolio

**Josué Kabangu** — DevOps Engineer en apprentissage | Phase 1 (2026)

Application de référence Microsoft [dotnet/eShop](https://github.com/dotnet/eShop) — 12 microservices .NET — conteneurisée et déployée avec Docker, Kubernetes, Terraform et GitLab CI/CD.

---

## Documentation

| Doc | Contenu |
|-----|---------|
| [docker/DOCKER.md](docker/DOCKER.md) | Dockerfiles, docker-compose, 10 bugs résolus, quick start |
| [src/ESHOP.md](src/ESHOP.md) | Architecture applicative, 12 services, patches OAuth2 |
| [k8s/MANIFEST.md](k8s/MANIFEST.md) | k3s, registre local, manifests Kubernetes |

---

## Stack technique

| Outil | Rôle | Statut |
|-------|------|--------|
| Vagrant + VirtualBox | VM de développement — infrastructure immuable | ✅ Ph1 |
| Docker + Compose | Conteneurisation + orchestration locale | ✅ Ph1 |
| k3s | Kubernetes léger sur VM | 🔄 Ph1 |
| Terraform | Infrastructure as Code cloud | ❌ Ph2 |
| GitLab CI/CD | Pipeline automatisé | ❌ Ph2 |

---

## Piliers DevOps vécus

| Concept | Application concrète |
|---------|---------------------|
| **Idempotence** | Scripts Vagrant — relançables sans effet de bord |
| **Infrastructure Immuable** | VM Vagrant jetable, images Docker sans config figée |
| **GitOps** | Vagrantfile, Dockerfiles, compose, manifests versionnés |
| **12-Factor / séparation code-config** | Code immuable vs env vars injectées à l'exécution |
| **Stateless vs Stateful** | APIs interchangeables vs Postgres avec volume dédié |
| **Issuer OIDC stable** | IssuerUri fixé via env var — jamais déduit du réseau |
| **Data Protection Keys** | État cryptographique local → externaliser avant de scaler |

---

## Roadmap

| Phase | Objectif | Outils | Statut |
|-------|----------|--------|--------|
| Ph1 — Docker | 9 microservices + docker-compose | Docker, Vagrant | ✅ |
| Ph1 — K8s | Déployer sur k3s local | k3s, kubectl | 🔄 |
| Ph2 — IaC | Provisionner le cloud | Terraform, Azure | ❌ |
| Ph2 — CI/CD | Pipeline build → test → deploy | GitLab CI/CD | ❌ |
