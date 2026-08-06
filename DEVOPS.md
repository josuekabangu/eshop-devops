# eShop — DevOps Portfolio

**Josué Kabangu** — DevOps Engineer en apprentissage | Phase 1 (2026)

Application de référence Microsoft [dotnet/eShop](https://github.com/dotnet/eShop) — 12 microservices .NET — conteneurisée et déployée avec Docker, Kubernetes, Helm, GitHub Actions, ArgoCD et (à venir) Terraform.

---

## Documentation

| Doc | Contenu |
|-----|---------|
| [docker/DOCKER.md](docker/DOCKER.md) | Dockerfiles, docker-compose, 10 bugs résolus, quick start |
| [src/ESHOP.md](src/ESHOP.md) | Architecture applicative, 12 services, patches OAuth2 |
| [k8s/MANIFEST.md](k8s/MANIFEST.md) | k3s, registre local, manifests Kubernetes |
| [registry/REGISTRY.md](registry/REGISTRY.md) | Registre Docker local (registry:2 + UI) |
| [.github/CI.md](.github/CI.md) | Pipeline GitHub Actions, bascule vers ghcr.io |
| [helm/HELM.md](helm/HELM.md) | Conversion manifests bruts → charts Helm — 12/12 composants |
| [argocd/ARGOCD.md](argocd/ARGOCD.md) | GitOps — ArgoCD + ApplicationSet, 12/12 Synced/Healthy |

---

## Stack technique

| Outil | Rôle | Statut |
|-------|------|--------|
| Vagrant + VirtualBox | VM de développement — infrastructure immuable | ✅ Ph1 |
| Docker + Compose | Conteneurisation + orchestration locale | ✅ Ph1 |
| k3s | Kubernetes léger sur VM — 12 composants validés bout en bout | ✅ Ph1 |
| GitHub Actions | Build + push automatique des 9 images vers ghcr.io | ✅ Ph2 |
| Helm | Charts par service — 12/12 composants convertis | ✅ Ph2 |
| ArgoCD | GitOps — ApplicationSet, 12/12 Synced/Healthy, selfHeal validé | ✅ Ph2 |
| Terraform | Infrastructure as Code cloud | ❌ Ph2 |

---

## Piliers DevOps vécus

| Concept | Application concrète |
|---------|---------------------|
| **Idempotence** | Scripts Vagrant — relançables sans effet de bord |
| **Infrastructure Immuable** | VM Vagrant jetable, images Docker sans config figée |
| **GitOps** | Vagrantfile, Dockerfiles, compose, manifests versionnés — puis réconciliation automatique via ArgoCD (`selfHeal`) |
| **12-Factor / séparation code-config** | Code immuable vs env vars injectées à l'exécution |
| **Stateless vs Stateful** | APIs interchangeables vs Postgres avec volume dédié |
| **Issuer OIDC stable** | IssuerUri fixé via env var — jamais déduit du réseau |
| **Data Protection Keys** | État cryptographique local → externaliser avant de scaler |

---

## Roadmap

| Phase | Objectif | Outils | Statut |
|-------|----------|--------|--------|
| Ph1 — Docker | 9 microservices + docker-compose | Docker, Vagrant | ✅ |
| Ph1 — K8s | Déployer sur k3s local | k3s, kubectl | ✅ |
| Ph2 — CI/CD | Build + push automatique des images | GitHub Actions, ghcr.io | ✅ |
| Ph2 — Packaging | Charts Helm, 12/12 composants | Helm | ✅ |
| Ph2 — GitOps | Réconciliation continue Git ↔ cluster | ArgoCD, ApplicationSet | ✅ |
| Ph2 — IaC | Provisionner le cloud | Terraform, Azure | ❌ |
