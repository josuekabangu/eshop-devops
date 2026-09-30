# eShop DevOps — Roadmap Junior to Senior

Projet central de ma roadmap 12 mois vers Senior DevOps / Platform Engineer.

---

## 🎯 Objectif du projet

Prendre l'application de référence [dotnet/eShop](https://github.com/dotnet/eShop) et construire, à la main puis en l'automatisant progressivement, une chaîne DevOps complète : conteneurisation, orchestration Kubernetes, CI/CD, packaging Helm, GitOps, Infrastructure as Code, configuration management sur un vrai cloud (AWS), et observabilité. Rôle 100% infrastructure — zéro ligne de code applicatif écrite, uniquement consommée telle quelle.

---

## 🏗️ Architecture — vue locale (K3s sur Vagrant)

```
┌─────────────────────────────────────────────────────────────┐
│                     VM Vagrant (Ubuntu 22.04)                │
│                        192.168.56.11                         │
│                                                                │
│  ┌──────────────────────────────────────────────────────┐   │
│  │                    Cluster K3s                         │   │
│  │  Infra (StatefulSet)      Applicatif (Deployment)       │   │
│  │  postgres / rabbitmq /    catalog-api / identity-api /  │   │
│  │  redis                    ordering-api / basket-api /   │   │
│  │                            webhooks-api / webhook-client │   │
│  │                            / order-processor /           │   │
│  │                            payment-processor / webapp    │   │
│  │                                                            │   │
│  │  Observabilité (namespace observability)                 │   │
│  │  Prometheus + Grafana (:30300) + Loki + Promtail          │   │
│  └──────────────────────────────────────────────────────┘   │
│                                                                │
│  ArgoCD (GitOps) + ApplicationSet (12 composants)             │
└─────────────────────────────────────────────────────────────┘
                              ▲
                    synchronisation continue
                              │
                    GitHub Repo (source de vérité)
                              │
                    GitHub Actions (CI, matrix)
                              │
                              ▼
                    ghcr.io (12 packages)
```

## 🏗️ Architecture — vue cloud (AWS, Terraform + Ansible)

```
┌──────────────────────────────────────────────────────────┐
│                   AWS VPC (10.0.0.0/16)                    │
│                                                              │
│  Subnets publics (2 AZ)        Subnets privés (2 AZ)        │
│  ┌────────────────────┐        ┌────────────────────┐      │
│  │  EC2 (K3s + ArgoCD) │        │  (réservé RDS,       │      │
│  │  postgres +          │        │   non activé          │      │
│  │  catalog-api          │        │   actuellement)        │      │
│  └────────────────────┘        └────────────────────┘      │
│                                                              │
│  Security Groups : SSH restreint à l'IP admin,               │
│  RDS accessible uniquement depuis le SG de l'EC2             │
└──────────────────────────────────────────────────────────┘
        ▲
        │ Terraform (provisioning) + Ansible (configuration)
        │
   VM Vagrant (control node)
```

---

## 📦 Stack technique

| Couche | Outils |
|---|---|
| Virtualisation locale | Vagrant + VirtualBox |
| Conteneurisation | Docker, Docker Compose |
| Orchestration | Kubernetes (K3s) — local et sur AWS EC2 |
| Packaging | Helm |
| GitOps | ArgoCD (+ ApplicationSet, générateurs `git.directories` et `list`) |
| CI/CD | GitHub Actions (matrix build) |
| Registre d'images | GitHub Container Registry (ghcr.io) |
| Infrastructure as Code | Terraform (modules `networking`, `ec2`, `rds`) |
| Configuration management | Ansible (installation K3s + ArgoCD, idempotent) |
| Observabilité | Prometheus, Grafana, Loki, Promtail (charts communautaires) |
| Cloud | AWS (VPC, EC2, RDS, IAM) |
| Application | .NET 10, PostgreSQL (pgvector), RabbitMQ, Redis |

---

## 📁 Structure du repo

```
EshopOnContainer/
├── vagrant/
│   └── Vagrantfile              # provisioning VM
├── eShop/                       # code source applicatif (dotnet/eShop)
├── docker/
│   ├── docker-compose.yml       # stack complète en local (référence historique)
│   ├── DOCKER.md                # doc Phase 1 — Dockerfiles, compose, bugs
│   └── scripts/postgres/
├── src/                         # Dockerfiles des 9 services applicatifs
│   └── ESHOP.md                 # doc architecture applicative, patches OAuth2
├── registry/
│   ├── docker-compose.yml       # registre Docker local (dev, obsolète depuis CI)
│   └── REGISTRY.md
├── k8s/                         # manifests Kubernetes bruts (référence historique)
│   ├── MANIFEST.md              # doc migration Compose → K8s, toutes les étapes
│   └── postgres/ rabbitmq/ redis/ catalog-api/ identity-api/ ordering-api/ ...
├── helm/                        # 12 charts — source de vérité du déploiement K8s local
│   ├── HELM.md                  # doc conversion K8s → Helm, tous les charts
│   └── postgres/ rabbitmq/ redis/ catalog-api/ identity-api/ ordering-api/ ...
├── argocd/
│   ├── ARGOCD.md                # doc GitOps
│   └── eshop-applicationset.yaml # ApplicationSet local, genere les 12 Applications
├── .github/
│   ├── CI.md                    # doc pipeline CI
│   └── workflows/build-push-all.yml
├── terraform/
│   ├── TERRAFORM.md             # doc IaC — pilote S3, modules networking + ec2 + rds
│   ├── main.tf / variables.tf / outputs.tf   # racine, appelle les modules
│   ├── networking/              # VPC, subnets publics/privés, routage
│   ├── ec2/                     # instance, Security Group, K3s user_data
│   └── rds/                     # base managée, isolée en subnet privé
├── ansible/
│   ├── ANSIBLE.md               # doc config management — K3s + ArgoCD sur EC2
│   ├── inventory.ini / ansible.cfg
│   ├── k3s-install.yml           # installation K3s idempotente
│   ├── argocd-install.yml        # installation ArgoCD + ApplicationSet AWS
│   └── eshop-applicationset-aws.yaml
├── observability/
│   ├── OBSERVABILITY.md          # doc — Prometheus/Grafana/Loki, bug datasource
│   ├── prometheus-values.yaml    # Prometheus + Grafana (kube-prometheus-stack)
│   └── loki-values.yaml          # Loki + Promtail (loki-stack)
└── DEVOPS.md                    # index racine — stack, piliers, roadmap à jour
```

⚠️ **Sources de vérité actives, à ne modifier que par ces canaux :**
- Déploiement K8s local → `helm/*`, appliqué via ArgoCD (`argocd/eshop-applicationset.yaml`)
- Infrastructure AWS → `terraform/*`, appliqué via `terraform apply`
- Configuration serveur AWS → `ansible/*`, appliqué via `ansible-playbook`
- Observabilité → `observability/*`, appliqué via `helm install`/`upgrade`

`docker-compose.yml` et `k8s/*.yaml` bruts sont des références historiques, conservées pour la documentation — ne plus les modifier pour faire évoluer un déploiement réel.

---

## 📚 Index de la documentation

Chaque grande étape a sa doc colocalisée avec le code qu'elle décrit — pas de dossier `docs/` séparé, la documentation vit à côté de ce qu'elle documente.

| Document | Contenu |
|---|---|
| [DEVOPS.md](DEVOPS.md) | Index vivant : stack technique, piliers DevOps, roadmap, statuts à jour |
| [docker/DOCKER.md](docker/DOCKER.md) | Phase 1 — 9 Dockerfiles multi-stage, `docker-compose.yml`, 10 bugs diagnostiqués |
| [src/ESHOP.md](src/ESHOP.md) | Architecture applicative, 12 services, patches OAuth2 |
| [k8s/MANIFEST.md](k8s/MANIFEST.md) | Migration Compose → K8s : StatefulSets (postgres, rabbitmq, redis), Deployments (les 9 services applicatifs), tous les bugs par étape |
| [registry/REGISTRY.md](registry/REGISTRY.md) | Registre Docker local, interface web, bugs DNS interne/externe et CORS |
| [.github/CI.md](.github/CI.md) | Pipeline GitHub Actions, bascule vers GHCR, bug gitlink/`.gitignore`, workflow `matrix` |
| [helm/HELM.md](helm/HELM.md) | 12 charts Helm, décision "un chart par service", résolution structurelle du `${VAR}`, tous les bugs de templating |
| [argocd/ARGOCD.md](argocd/ARGOCD.md) | Installation ArgoCD, `ApplicationSet`, bug CRD, bilan final |
| [terraform/TERRAFORM.md](terraform/TERRAFORM.md) | IaC — fondamentaux Terraform, pilote AWS S3, modules `networking`/`ec2`/`rds` complets, isolation réseau validée par preuve fonctionnelle |
| [ansible/ANSIBLE.md](ansible/ANSIBLE.md) | Config management — K3s + ArgoCD idempotents sur EC2, incident de sécurité (clé AWS) et incident de capacité (RAM/disque) résolus |
| [observability/OBSERVABILITY.md](observability/OBSERVABILITY.md) | Mini-cours 3 piliers, installation Prometheus/Grafana/Loki, bug de conflit de datasources (`isDefault`), premiers insights de consommation réelle des composants eShop |

---

## 🐛 Récapitulatif des dettes techniques assumées

| Dette | Description | Piste de résolution future |
|---|---|---|
| Secrets dupliqués entre charts Helm | Mots de passe en dur dans plusieurs `values.yaml` | Gestionnaire de secrets externe (Vault, AWS Secrets Manager) |
| `docker-entrypoint-initdb.d` pour la création des bases | Provisioning couplé au cycle de vie du StatefulSet Postgres | `Job` Kubernetes dédié |
| Probes `tcpSocket` plutôt que health check applicatif réel | Ne vérifie que l'ouverture du port | Endpoint `/readyz` minimal, non conditionné à `Development` |
| Packages GHCR publics | Pas d'authentification requise pour puller les images | `imagePullSecret` + packages privés — câblage Helm (`values.yaml`/`deployment.yaml` des 9 charts) déjà conçu, reste à appliquer : rendre les packages privés côté GitHub + générer un PAT + créer le secret K8s |
| Tag `latest` dans les manifests Helm | Pas de garantie de version figée | Référencer le SHA du commit — job CI `update-helm-tags` (bump automatique après build, commit `[skip ci]`) déjà conçu, reste à appliquer dans `build-push-all.yml` |
| Aucune vérification CI sur le code Terraform | `terraform fmt`/`validate` jamais exécutés avant merge | Workflow `terraform-checks.yml` sur PR (`fmt -check` + `validate`, sans `plan` tant que le state est local) déjà conçu, reste à ajouter dans `.github/workflows/` |
| State Terraform local (`terraform.tfstate`) | Pas de verrouillage, pas de partage d'équipe | Backend distant S3 + verrouillage DynamoDB |
| `skip_final_snapshot = true` sur RDS | Aucun snapshot conservé à la destruction | À retirer avant tout scénario proche de la production |
| Module Terraform `rds` désactivé sur AWS | Non utilisé pour le test K3s-sur-EC2 (RDS externe redondant avec le Postgres interne au cluster) | Réactiver pour explorer une architecture avec base externalisée |
| Instance EC2 sous-dimensionnée pour la stack complète | `t3.small` (2 Go) ne supporte qu'un sous-ensemble d'eShop | Instance plus grande une fois la restriction Free Tier levée |
| `adminPassword` Grafana en clair dans `prometheus-values.yaml` | Mot de passe admin non géré via Secret | Référencer un `Secret` Kubernetes existant plutôt qu'une valeur en dur |
| Alerting Prometheus désactivé | `alertmanager.enabled: false` | Activer une fois les dashboards de base bien maîtrisés |
| Tracing distribué non implémenté | Pilier "traces" de l'observabilité non couvert | Instrumenter le code via .NET Aspire natif ou Tempo/Jaeger |

---

## 🔐 Incidents traités durant ce parcours

### Incident de sécurité — clé AWS compromise
Une clé d'accès IAM a été exposée (collée en chat, committée dans `TERRAFORM.md`). AWS l'a automatiquement mise en quarantaine. Actions : révocation complète, nouvelle clé générée, nettoyage de l'état actuel du repo, réécriture de l'historique Git via `git filter-repo`, force-push. Détail complet : `ansible/ANSIBLE.md`.

### Incident de capacité — saturation mémoire/disque sur EC2
Le cluster K3s + ArgoCD + applications a saturé la RAM (2 Go) et approché la limite disque (8 Go) d'une instance `t3.small`. Diagnostic via `free`/`top`/`df`, résolution par ajout de swap, désactivation de composants ArgoCD non essentiels (dex-server, notifications-controller). Détail complet : `ansible/ANSIBLE.md`.

### Incident applicatif — CrashLoopBackOff Grafana (conflit de datasources)
Deux `ConfigMap` de datasources marqués `isDefault: true` simultanément (Prometheus + Loki, ce dernier créé automatiquement malgré `grafana.enabled: false`) ont bloqué le démarrage complet de Grafana en cascade. Diagnostic réalisé via export PDF suite à des difficultés de transmission de logs en texte brut. Détail complet : `observability/OBSERVABILITY.md`.

---

## 🚀 Démarrage rapide

### Stack locale (K3s sur Vagrant)
```bash
vagrant up
vagrant ssh
kubectl get applications -n argocd   # 12 composants Synced/Healthy
```
Accès : `http://192.168.56.11:5100` (webapp), `:5223` (identity-api), `:5114` (webhook-client), `:30300` (Grafana)

### Infrastructure AWS (Terraform + Ansible)
```bash
cd terraform
terraform init
terraform apply -var="my_ip=$(curl -s ifconfig.me)"

cd ../ansible
ansible-playbook -i inventory.ini k3s-install.yml --user ubuntu --private-key ~/.ssh/eshop-aws-key
ansible-playbook -i inventory.ini argocd-install.yml --user ubuntu --private-key ~/.ssh/eshop-aws-key
```
⚠️ Toujours détruire après usage : `terraform destroy -var="my_ip=$(curl -s ifconfig.me)"`

### Observabilité
```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  -n observability --create-namespace -f observability/prometheus-values.yaml
helm install loki grafana/loki-stack -n observability -f observability/loki-values.yaml
```
Grafana : `http://192.168.56.11:30300` — mot de passe admin :
```bash
kubectl get secret --namespace observability -l app.kubernetes.io/component=admin-secret -o jsonpath="{.items[0].data.admin-password}" | base64 --decode
```

---

## 🗺️ Position dans la roadmap 12 mois

| Phase | Focus | Statut |
|---|---|---|
| **Ph1** — GitOps & CI/CD | Docker, K8s manuel, CI, GitOps | ✅ Complétée et dépassée |
| **Ph2** — Infra & Observabilité | Terraform, Ansible, stack d'observabilité | ✅ Complétée (Terraform, Ansible, Prometheus/Grafana/Loki) |
| **Ph3** — Certifications & Plateforme | CKA, CKS, Terraform Associate, AWS DevOps Pro | 🔄 Prochaine étape |
| **Ph4** — SRE & Portfolio | Chaos Engineering, articles, entretiens | À venir |
