# Kubernetes — Phase 1 (k3s)

Déploiement de l'eShop sur k3s — Kubernetes léger sur la VM Vagrant existante.

---

## Pourquoi k3s et pas minikube

| | minikube | k3s |
|-|----------|-----|
| Architecture | VM dans la VM (nested) | Binaire unique sur l'OS |
| Taille | ~300 MB + VM | ~70 MB |
| RAM minimale | 2 GB (VM interne) | 512 MB |
| Adapté à notre VM 6 GB | ❌ | ✅ |

k3s installe directement Kubernetes sur Ubuntu — pas d'hyperviseur intermédiaire.

---

## Infrastructure k3s

```
VM eshop-devops (192.168.56.11)
├── k3s v1.36.2
│   ├── containerd (store d'images séparé de Docker)
│   ├── CoreDNS
│   ├── Traefik (Ingress controller)
│   └── local-path-provisioner (PVC → /var/lib/rancher/k3s/storage/)
├── kubectl → ~/.kube/config
├── registry:2 (:5000) ← pont entre Docker et k3s
├── /etc/docker/daemon.json ← Docker accepte le registre HTTP
└── /etc/rancher/k3s/registries.yaml ← k3s accepte le registre HTTP
```

---

## Installation

### 1. Installer k3s

```bash
curl -sfL https://get.k3s.io | sh -
```

Installe : k3s, containerd, CoreDNS, Traefik, local-path-provisioner.
Crée : `/etc/systemd/system/k3s.service` (démarrage automatique).

### 2. Configurer kubectl sans sudo

```bash
mkdir -p ~/.kube
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
sudo chown vagrant:vagrant ~/.kube/config
echo 'export KUBECONFIG=~/.kube/config' >> ~/.bashrc
source ~/.bashrc
kubectl get nodes
```

> ⚠️ Sans `export KUBECONFIG`, k3s kubectl cherche `/etc/rancher/k3s/k3s.yaml` → `permission denied`.

### 3. Registre Docker local (pont Docker ↔ k3s)

> 📄 Registre géré via Docker Compose (`registry:2` + UI `joxit/docker-registry-ui`) — voir [`registry/REGISTRY.md`](../registry/REGISTRY.md) pour le détail complet (manifeste, bugs CORS/DNS interne-externe, workflow build→push→pull). Remplace l'ancienne commande `docker run` ponctuelle.

**Pourquoi un registre ?** Docker et k3s ont des stores d'images indépendants :
```
docker build → /var/lib/docker/   (invisible par k3s)
k3s pull     → /var/lib/rancher/  (invisible par Docker)
```
Solution : `docker push → registre:5000 ← k3s pull`

### 4. Autoriser HTTP côté Docker

```bash
sudo tee /etc/docker/daemon.json <<EOF
{
  "insecure-registries": ["192.168.56.11:5000"]
}
EOF
sudo systemctl restart docker
```

Sans cette config : `http: server gave HTTP response to HTTPS client`

### 5. Autoriser HTTP côté k3s

```bash
sudo tee /etc/rancher/k3s/registries.yaml <<EOF
mirrors:
  "192.168.56.11:5000":
    endpoint:
      - "http://192.168.56.11:5000"
EOF
sudo systemctl restart k3s
```

### 6. Valider le pipeline complet

```bash
docker pull hello-world
docker tag hello-world 192.168.56.11:5000/hello-world
docker push 192.168.56.11:5000/hello-world
kubectl run test --image=192.168.56.11:5000/hello-world --restart=Never
kubectl logs test   # → "Hello from Docker!"
kubectl delete pod test
```

Résultat validé :
```
NAME           STATUS   ROLES           AGE   VERSION
eshop-devops   Ready    control-plane   39m   v1.36.2+k3s1
```

---

## Workflow image → k3s

```bash
# 1. Build
docker build -t catalog-api:latest src/CatalogApi/

# 2. Tag
docker tag catalog-api:latest 192.168.56.11:5000/catalog-api:latest

# 3. Push vers registre local
docker push 192.168.56.11:5000/catalog-api:latest

# 4. Déployer (k3s pull depuis le registre)
kubectl apply -f k8s/catalog-api.yaml
```

---

## Manifests — état actuel

| Manifest | Statut | Description |
|----------|--------|-------------|
| `postgres/postgres-statefulset.yaml` | ✅ Validé | PostgreSQL — StatefulSet + PVC |
| `redis/redis-statefulset.yaml` | ✅ Validé | Redis — StatefulSet + PVC (AOF, persistance confirmée) |
| `rabbitmq/rabbitmq-statefulset.yaml` | ✅ Validé | RabbitMQ — StatefulSet + PVC (identité de nœud liée au hostname) |
| `identity-api.yaml` | ❌ | Duende IdentityServer |
| `catalog-api/catalog-deployment.yaml` | ✅ Validé | Catalog API — Deployment stateless, premier service applicatif |
| `basket-api.yaml` | ❌ | Basket API |
| `ordering-api.yaml` | ❌ | Ordering API |
| `webapp.yaml` | ❌ | Blazor WebApp (BFF) |
| `migrations-job.yaml` | ❌ | Job EF Core (Bug 5 Phase 1 Docker) |
| `ingress.yaml` | ❌ | Traefik — `eshop.local` |

---

## Migration Docker Compose → Kubernetes — Méthode générale

Traduire manuellement les services de `docker-compose.yml` en manifests Kubernetes, un service à la fois, en commençant par les services stateful (les plus structurants).

### Correspondance Compose → Kubernetes

| Dans `docker-compose.yml` | Devient en Kubernetes | Rôle |
|---|---|---|
| `services.<name>` | `Deployment` (stateless) ou `StatefulSet` (stateful) | Combien de réplicas, comment les faire tourner/redémarrer |
| `image` / `build` | `spec.template.spec.containers[].image` | L'image à exécuter — jamais buildée dans le cluster, doit exister sur un registre |
| `ports` | `Service` (objet séparé) | Expose le Pod aux autres services |
| `environment` (non sensible) | `ConfigMap` | Configuration versionnable sans risque |
| `environment` (sensible) | `Secret` | Mots de passe, tokens, connection strings |
| `depends_on` | ❌ N'existe pas — remplacé par `readinessProbe` + retry applicatif | K8s ne garantit aucun ordre de démarrage entre objets indépendants |
| `volumes` | `PersistentVolumeClaim` (+ `volumeClaimTemplates` pour un StatefulSet) | Stockage persistant découplé du cycle de vie du Pod |
| `networks` | Automatique — DNS interne natif entre tous les Pods du cluster | — |
| `healthcheck` | `livenessProbe` / `readinessProbe` | Deux rôles distincts |

### Étapes de traduction, dans l'ordre

1. **Identifier stateless vs stateful** → conditionne `Deployment` vs `StatefulSet`
2. **Séparer la config sensible de la config normale** → `Secret` vs `ConfigMap`
3. **Décider comment le service sera atteint** → `Service` ClusterIP (interne) vs headless (StatefulSet) vs Ingress (externe)
4. **Traduire les dépendances de démarrage** → `readinessProbe` + retry côté code, jamais un équivalent direct de `depends_on`
5. **Écrire et appliquer un objet à la fois**, vérifier avant de passer au suivant

⚠️ **Point clé à ne jamais oublier** : `depends_on` n'a pas d'équivalent K8s. C'est le changement de paradigme le plus important de cette migration — Kubernetes ne fait aucune garantie d'ordre de démarrage entre objets, contrairement à Docker Compose avec `condition: service_healthy`.

---

## Étape 1 — Postgres en `StatefulSet`

### Pourquoi StatefulSet et pas Deployment

| | `Deployment` | `StatefulSet` |
|---|---|---|
| Identité des Pods | Interchangeable, nom aléatoire | Stable et ordonnée (`postgres-0`) |
| Volume | Généralement partagé entre réplicas | Dédié et stable par Pod (`volumeClaimTemplates`) |
| Ordre démarrage/arrêt | Aucune garantie | Séquentiel |
| DNS | Change à chaque recréation | Stable par Pod, via Service headless |

Postgres a besoin d'une **identité stable + un volume dédié et non partagé** par instance — un `Deployment` classique ne peut garantir ni l'un ni l'autre par construction.

### Les 4 fichiers produits

```
k8s/postgres/
├── postgres-secret.yaml       (Secret — mot de passe)
├── postgres-configmap.yaml    (ConfigMap — script d'init des bases)
├── postgres-service.yaml      (Service headless)
└── postgres-statefulset.yaml  (StatefulSet — le Pod Postgres lui-même)
```

**`postgres-secret.yaml`** — stocke le mot de passe, référencé par le StatefulSet via `secretKeyRef`. `stringData` accepte du texte brut, encodé en base64 automatiquement par K8s au stockage.

**`postgres-configmap.yaml`** — traduction du bind mount Compose (`./scripts/postgres/init-db.sh:/docker-entrypoint-initdb.d/...`) en `ConfigMap` monté au même chemin dans le conteneur.

**`postgres-service.yaml`** — `clusterIP: None` désactive le load-balancing classique et donne à la place une entrée DNS **par Pod** (`postgres-0.postgres.default.svc.cluster.local`) — indispensable pour cibler une instance précise plutôt que n'importe laquelle.

**`postgres-statefulset.yaml`** — `serviceName` le relie au Service headless, `volumeClaimTemplates` crée un PVC dédié par réplica (`data-postgres-0`), `PGDATA` pointe vers un sous-dossier du volume pour éviter les artefacts système sur le point de montage.

### Bugs rencontrés et corrigés

**Bug 1 — `replicas: 3` (erreur conceptuelle grave)**
Root cause : confondre "scaler un StatefulSet" avec "créer un cluster Postgres répliqué". `replicas: 3` crée 3 instances Postgres **totalement indépendantes**, chacune avec son propre volume vide, **sans synchronisation de données**. Une vraie réplication Postgres nécessite du streaming replication ou un opérateur dédié (Zalando, CloudNativePG, Patroni) — hors de portée d'un StatefulSet fait main.
Fix : `replicas: 1`.
Principe : Stateful ≠ réplication automatique. L'erreur la plus dangereuse possible sur une base de données K8s — silencieuse au démarrage, catastrophique en usage (incohérence de données selon le Pod qui répond).

**Bug 2 — `valueFROM` (casse incorrecte)**
Root cause : `valueFrom` mal capitalisé, champ non reconnu par l'API Kubernetes.
Fix : correction de la casse exacte.
Principe : YAML Kubernetes est strictement sensible à la casse ; un champ mal nommé peut être silencieusement ignoré selon le contexte, sans erreur explicite.

**Bug 3 — `PGDATA` manquant**
Root cause : sans `PGDATA` pointant vers un sous-dossier (`/pgdata`), `initdb` peut refuser de s'initialiser si le point de montage contient des artefacts système (`lost+found`).
Fix : ajout de `PGDATA: /var/lib/postgresql/data/pgdata`, reproduisant la configuration Docker Compose d'origine.

**Bug 4 — `postgres-configmap.yaml` : `kind: Secret` au lieu de `ConfigMap`, `apiVersion` vide**
Root cause : copie/adaptation incomplète — le fichier destiné à être un ConfigMap déclarait `kind: Secret` avec un `apiVersion` vide (invalide). Le StatefulSet référence un objet `configMap` par nom ; un objet `Secret` de même nom ne peut pas le satisfaire (types différents, pas de conflit de nom détecté).
Fix : `apiVersion: v1`, `kind: ConfigMap`.

**Bug 5 — `postgres-secret.yaml` : structure YAML invalide**
Root cause : `POSTGRES_PASSWORD` indenté directement sous `type: Opaque` (un champ scalaire, qui ne peut pas avoir d'enfants) — absence de la clé parente `data`/`stringData`.
Fix : ajout de `stringData:` comme parent.

### Validation en conditions réelles sur k3s

```bash
kubectl get svc postgres        # ClusterIP: None → Service headless (requis pour StatefulSet)
kubectl get endpoints postgres  # 10.42.0.10:5432 → Pod bien routé
kubectl run pg-test --rm -it --image=postgres:15 --restart=Never -- \
  psql -h postgres -U postgres -d catalogdb   # connexion réseau OK
kubectl delete pod postgres-0   # simulate crash/reschedule
kubectl get pods -w             # revient en postgres-0 (même nom)
kubectl exec -it postgres-0 -- psql -U postgres -l   # les 4 bases toujours présentes
```

Résultat : le Pod redémarre avec la même identité et retrouve son volume — persistance confirmée, comportement StatefulSet correct.

---

## Étape 2 — RabbitMQ & Redis en `StatefulSet`

### Contexte

Suite à la migration de Postgres, `catalog-api` a révélé une dépendance croisée non résolue : il a besoin de **RabbitMQ** (event bus) en plus de Postgres. Comme K3s (containerd) et Docker Compose (dockerd) utilisent des réseaux totalement isolés l'un de l'autre, `catalog-api` ne pourrait pas résoudre `rabbitmq` si ce dernier restait uniquement en Docker Compose.

**Décision prise :** migrer RabbitMQ vers K3s également, avant d'écrire le manifest `catalog-api`. Redis a été traité dans la foulée, par cohérence méthodologique (même famille de service stateful).

### 🐰 RabbitMQ

**Pourquoi StatefulSet et pas Deployment :** RabbitMQ maintient un état interne (files de messages non consommés, définitions d'exchanges/queues). Perdre ce volume au redémarrage d'un Pod ferait perdre des messages en transit. Même en instance unique aujourd'hui, un futur clustering RabbitMQ (haute disponibilité) exigerait une identité réseau stable par nœud — rôle du `StatefulSet`, pas du `Deployment`.

```
k8s/rabbitmq/
├── rabbitmq-secret.yaml
├── rabbitmq-service.yaml
└── rabbitmq-statefulset.yaml
```

**Point technique — `rabbitmq-service.yaml` :** deux ports exposés (`5672` AMQP, `15672` management) → chacun doit être **nommé** explicitement (`name: amqp`, `name: management`), une règle Kubernetes dès qu'un Service expose plus d'un port.

**Résultat de déploiement :** `rabbitmq-0` en `1/1 Running`, démarrage propre confirmé par les logs : Mnesia/Khepri initialisés, plugins démarrés (`rabbitmq_management`, `rabbitmq_prometheus`, `rabbitmq_federation`, `rabbitmq_management_agent`, `rabbitmq_web_dispatch`), listener AMQP actif sur le port 5672. Persistance confirmée après `kubectl delete pod rabbitmq-0` : le nom de nœud (`rabbit@rabbitmq-0`) reste identique après redémarrage.

### 🟥 Redis

**Subtilités de traduction depuis le Compose d'origine :**

```yaml
# docker-compose.yml — Redis
redis:
  image: redis:7
  command:
    - redis-server
    - --requirepass ${REDIS_PASSWORD}
    - --maxmemory 1gb
    - --maxmemory-policy allkeys-lru
    - --appendonly yes
    - --appendfsync everysec
  healthcheck:
    test: ["CMD", "redis-cli", "-a", "${REDIS_PASSWORD}", "ping"]
```

Deux points nécessitant une attention particulière :
1. Le mot de passe est un **argument de ligne de commande** (`--requirepass`), pas juste une variable lue passivement — il faut l'injecter dans `command`.
2. Le `healthcheck` utilise aussi ce mot de passe — même souci pour la probe K8s.

```
k8s/redis/
├── redis-secret.yaml
├── redis-service.yaml
└── redis-statefulset.yaml
```

**Point technique important — deux mécanismes de substitution différents :**

| Endroit | Syntaxe | Pourquoi |
|---|---|---|
| `command:` / `args:` | `$(REDIS_PASSWORD)` | Kubernetes substitue lui-même les champs `command`/`args` à partir des variables déclarées dans `env:` — mécanisme natif |
| `probe.exec.command` | `sh -c "redis-cli -a \"$REDIS_PASSWORD\" ping"` | Kubernetes **ne fait pas** cette substitution `$(VAR)` dans les probes — il faut passer par un shell qui lit la variable d'environnement réelle du conteneur |

⚠️ Confondre ces deux mécanismes est une source d'erreur fréquente : `$(VAR)` ne fonctionne que dans `command`/`args`, jamais dans les champs de probe.

**Résultat de déploiement :** `redis-0` : transition `0/1 Running` → `1/1 Running` en ~20 secondes (le temps que le `readinessProbe` confirme `PONG`). Logs confirmant la persistance AOF active : fichiers `appendonly.aof.1.base.rdb` et `appendonly.aof.1.incr.aof` créés au démarrage. Persistance confirmée après `kubectl delete pod redis-0` : `SET test-key hello` avant suppression, `GET test-key` → `"hello"` après redémarrage.

### Point de vigilance — pourquoi ni RabbitMQ ni Redis ne doivent scaler naïvement

Pour les deux services, `replicas: N > 1` sans mécanisme de clustering réel produirait des instances **indépendantes**, sans partage d'état :

- **Redis :** même avec `volumeClaimTemplates` (volume dédié par Pod), le cache en mémoire de chaque instance reste invisible aux autres — un client écrivant sur le Pod A ne verrait pas sa donnée si routé vers le Pod B. Un volume *partagé* entre plusieurs Pods serait pire : deux instances écrivant simultanément sur le même fichier AOF → corruption quasi certaine (Redis suppose être le seul écrivain).
- **RabbitMQ :** un vrai clustering nécessite une configuration de peer discovery et une gestion explicite du quorum — pas un simple `replicas: N`.

**Fix appliqué :** `replicas: 1` pour les deux, cohérent avec la leçon déjà tirée sur Postgres ([[statefulset-replicas-misconception]] — Bug 1 de l'Étape 1).

⚠️ **[PROD BEST PRACTICE]** Une vraie haute disponibilité pour ces deux services nécessite soit un mode cluster natif (Redis Cluster, RabbitMQ avec peer discovery), soit un opérateur Kubernetes dédié — hors de portée d'un `StatefulSet` fait main, sujet de Phase 2/3.

### Piliers consolidés durant cette étape

| Concept | Application concrète |
|---|---|
| **Outils de diagnostic natifs pour les probes** | `pg_isready`, `rabbitmq-diagnostics ping`, `redis-cli ping` — toujours préférer l'outil officiel de la techno à un simple test de port TCP, qui ne garantit jamais qu'un service est fonctionnellement prêt. |
| **Readiness vs Liveness** | *Readiness* : "dois-je recevoir du trafic ?" (retrait sans redémarrage). *Liveness* : "suis-je bloqué, faut-il me recréer ?" — délais de tolérance volontairement différents (`initialDelaySeconds` plus court pour readiness). |
| **Stateful ≠ réplication automatique** | Rappel transversal (déjà vu sur Postgres) : scaler un `StatefulSet` donne des identités et volumes séparés, jamais une synchronisation de données automatique. |
| **Substitution de variables : deux mécanismes distincts** | `$(VAR)` dans `command`/`args` (natif K8s) vs lecture shell classique (`$VAR` via `sh -c`) dans les probes — ne pas confondre les deux contextes. |

---

## Étape 3 — `catalog-api` (Deployment) — premier service applicatif

### Contexte

Premier `Deployment` stateless du projet, s'appuyant sur les 3 services d'infrastructure déjà migrés (`postgres`, `rabbitmq`, `redis`) et sur le registre Docker local pour la distribution d'image.

### Fichiers produits

```
k8s/catalog-api/
├── catalog-api-secret.yaml
├── catalog-deployment.yaml
└── catalog-api-service.yaml
```

Pas de `ConfigMap` pour ce service : le `docker-compose.yml` d'origine ne définissait que 2 variables, toutes deux sensibles (`ConnectionStrings__catalogdb`, `ConnectionStrings__eventbus`) — traduction fidèle, tout passe par un `Secret`.

**Pourquoi `ClusterIP` classique (pas headless) :** contrairement à Postgres/RabbitMQ/Redis, `catalog-api` est **stateless** — chaque replica est interchangeable, aucune raison de cibler une instance précise. Le load-balancing automatique d'un `Service` classique est ici l'objectif recherché, pas un problème à contourner.

**Pourquoi pas de `depends_on` :** aucun équivalent K8s n'existe. La résilience au démarrage repose sur deux mécanismes combinés : le retry natif des clients Npgsql/RabbitMQ côté code applicatif, et le `readinessProbe` qui empêche le `Service` de router du trafic tant que le Pod n'est pas jugé prêt.

### Bugs rencontrés et corrigés

**Bug 1 — `${VAR}` non substitué dans le Secret**
Symptôme : `Npgsql.PostgresException: 28P01: password authentication failed for user "${POSTGRES_USER}"`.
Root cause : contrairement à Docker Compose, **Kubernetes ne fait aucune substitution de variables** (`${VAR}`) dans les manifests YAML. `kubectl apply` envoie le fichier tel quel à l'API — la chaîne `${POSTGRES_USER}` a été stockée et utilisée littéralement comme nom d'utilisateur.
Fix : remplacement par les valeurs réelles, en dur, dans le Secret.
Point de vigilance additionnel : modifier un `Secret` référencé par un Pod déjà démarré ne redémarre pas automatiquement ce Pod — les variables d'environnement sont injectées une seule fois, au démarrage du conteneur. `kubectl rollout restart deployment catalog-api` est nécessaire après toute modification de Secret/ConfigMap consommé en variables d'environnement.
Principe : Kubernetes ne propose aucun mécanisme de templating natif dans ses manifests bruts — contrairement à Docker Compose et son fichier `.env`. Des outils comme Helm ou Kustomize existent pour combler ce manque (hors scope de cette étape).
Dette identifiée : les mots de passe Postgres et RabbitMQ existent maintenant dupliqués dans deux endroits (`postgres-secret.yaml`/`rabbitmq-secret.yaml` d'un côté, copiés en dur dans `catalog-api-secret.yaml` de l'autre) — aucune référence croisée entre Secrets. Un changement de mot de passe doit être répercuté manuellement partout où il est dupliqué. Solution à explorer en Phase 2/3 : gestionnaire de secrets externe (Vault, AWS Secrets Manager) comme source unique de vérité.

**Bug 2 — `readinessProbe` sur `/health`, endpoint inexistant en Production**
Symptôme : Pod en `Running` mais `0/1 READY` indéfiniment, malgré des logs applicatifs entièrement sains.
Root cause : dans `src/eShop.ServiceDefaults/Extensions.cs`, les endpoints `/health` et `/alive` sont mappés **uniquement** si `app.Environment.IsDevelopment()` — décision de sécurité intentionnelle des auteurs du repo (un endpoint de santé détaillé peut révéler des informations internes sensibles en production). Le Pod tournant en `ASPNETCORE_ENVIRONMENT=Production`, `/health` renvoie systématiquement 404 → le `readinessProbe` HTTP échoue en boucle.

Trois options évaluées :

| Option | Description | Trade-off |
|---|---|---|
| A. Retirer la condition `IsDevelopment()` | Exposer `/health`/`/alive` inconditionnellement | Réintroduit le risque de sécurité que les auteurs voulaient éviter |
| B. `readinessProbe`/`livenessProbe` de type `tcpSocket` | Vérifie uniquement que le port 8080 est ouvert | Ne garantit pas que l'app peut réellement parler à Postgres/RabbitMQ |
| C. Endpoint minimal dédié (`/readyz`), non conditionné, sans appel réseau | Solution la plus proche des pratiques de production réelles | Nécessite de modifier le code source et de rebuild l'image |

Décision prise : option B (`tcpSocket`), pour avancer rapidement sans modifier le code applicatif du repo tiers.

⚠️ Dette technique tracée : ce `tcpSocket` confirme uniquement que Kestrel écoute sur le port — il ne garantit pas que la connexion Postgres/RabbitMQ est fonctionnelle. Amélioration possible plus tard : implémenter l'option C, un endpoint `/readyz` minimal, **sans aucun appel réseau**.

**Pourquoi un endpoint de ce type ne doit jamais faire d'appel réseau :** un `readinessProbe` s'exécute en boucle continue pour toute la durée de vie du Pod. Si cet endpoint interrogeait Postgres/RabbitMQ à chaque appel, sous forte charge, les requêtes de probe s'ajouteraient au trafic applicatif réel sur des ressources déjà saturées. Un échec de probe dû à la surcharge retirerait le Pod de la rotation du Service, concentrant encore plus de trafic sur les Pods restants — panne en cascade auto-infligée, où le mécanisme censé protéger le système l'aggrave.

### Validation sur k3s

```
kubectl get pods
# catalog-api-8b947fcdc-wrmbd   1/1   Running

kubectl describe pod -l app=catalog-api | grep -A5 Events
# Pulling image "localhost:5000/catalog-api:latest"
# Successfully pulled image ... in 18ms
```

### Piliers consolidés durant cette étape

| Concept | Application concrète |
|---|---|
| **Pas de templating natif en K8s** | `${VAR}` n'est jamais substitué par `kubectl apply` — toute valeur doit être littérale dans le manifest, ou gérée via un outil dédié (Helm, Kustomize) non couvert ici. |
| **Immutabilité des variables d'environnement d'un Pod** | Modifier un Secret/ConfigMap référencé ne relance pas automatiquement les Pods qui le consomment — `kubectl rollout restart` est requis. |
| **Séparation "endpoint de diagnostic" vs "endpoint pour orchestrateur"** | Un health check applicatif complet (vérifie les dépendances) et une probe minimale pour l'orchestrateur (vérifie juste que le process répond) répondent à des besoins différents. |
| **Résilience distribuée** | Une probe ne doit jamais elle-même devenir un facteur d'aggravation de panne sous charge — principe transversal à tout système distribué. |
| **Absence de `depends_on`** | Résilience déléguée au code applicatif (retry client Npgsql/RabbitMQ) et aux probes, jamais à un ordre de démarrage garanti par la plateforme. |

---

## Dette technique identifiée — à traiter dans une session future

**Sujet :** le script `docker-entrypoint-initdb.d/01-init-db.sh` (création des 4 bases) reste, pour l'instant, couplé au cycle de vie du conteneur Postgres — exactement le même anti-pattern que le Bug 5 de la Phase 1 Docker (migrations EF Core exécutées via `HostedService` plutôt qu'un `Job` séparé), mais à l'étage "création de base" plutôt que "création de tables".

**Limites de cette approche :**
- Ne s'exécute qu'une seule fois, au premier démarrage sur volume vide — aucune notion de version
- Aucune traçabilité des changements (ajouter une 5ème base ne s'applique jamais rétroactivement)
- Pas de mécanisme de rollback
- Idempotence garantie seulement par la rigueur du script écrit à la main, pas par le mécanisme lui-même

**Décision prise :** rester sur cette approche pour l'instant (choix pédagogique — avancer étape par étape), avec l'intention explicite d'y revenir plus tard sous forme de **`Job` Kubernetes dédié**, séparé du `StatefulSet` Postgres, suivant le même principe que le futur Job de migration EF Core.

**Architecture cible (non implémentée) :**
```
Job "postgres-init-db"      → crée les bases vides, après que Postgres soit prêt
Job "<service>-migrate"     → applique les migrations EF Core, un par service, avant chaque Deployment applicatif
```

---

## Choix d'architecture à venir

### Migrations EF Core → Job (pas initContainer)

| | initContainer | Job |
|-|---------------|-----|
| Exécution | À chaque démarrage de Pod | Une fois par cluster |
| Problème | 3 replicas ordering-api → 3 migrations en parallèle → race condition | Exécuté avant le déploiement des services |
| Adapté pour | Vérification de prérequis | Migrations de base de données |

```yaml
# migrations-job.yaml (à venir)
apiVersion: batch/v1
kind: Job
metadata:
  name: eshop-migrations
spec:
  template:
    spec:
      containers:
      - name: migrations
        image: 192.168.56.11:5000/order-processor:latest
        command: ["dotnet", "OrderProcessor.dll", "--migrate-only"]
      restartPolicy: OnFailure
```

### Ingress → solution Bug 9 (double issuer, Phase 1 Docker)

Avec un `Ingress` Traefik exposant `eshop.local`, identity-api reçoit toutes les requêtes via le même hostname → un seul issuer par construction → Bug 9 disparaît.

```
Browser → eshop.local/identity → identity-api  (issuer = eshop.local)
basket-api → eshop.local/identity → identity-api (même issuer)
```

---

## Piliers consolidés durant cette étape

| Concept | Application concrète |
|---|---|
| **Stateless vs Stateful** | StatefulSet pour Postgres (identité stable, volume dédié) vs futur Deployment pour les API (interchangeables) |
| **Service headless vs classique** | `clusterIP: None` pour cibler une instance précise, pas du load-balancing arbitraire |
| **Séparation code/config/secrets** | `Secret` (sensible) vs `ConfigMap` (non sensible), tous deux référencés par nom depuis le StatefulSet, jamais en valeur brute |
| **Absence de `depends_on` en K8s** | Aucune garantie d'ordre de démarrage runtime entre objets — seule la résolution de références déclaratives (Secret/ConfigMap doivent exister) est concernée par l'ordre d'`apply` |
| **Séparation des responsabilités (dette identifiée)** | Un composant qui vit en continu (StatefulSet) ne devrait pas porter la responsabilité d'une opération ponctuelle (provisioning de données) — rôle destiné à un `Job` |

---

## Progression Phase 1 K8s

| Étape | Statut |
|-------|--------|
| Installation k3s | ✅ |
| kubectl sans sudo | ✅ |
| Registre local :5000 | ✅ |
| Docker daemon insecure-registries | ✅ |
| k3s registries.yaml | ✅ |
| Pipeline build→push→pull validé | ✅ |
| Postgres StatefulSet | ✅ |
| RabbitMQ StatefulSet | ✅ |
| Redis StatefulSet | ✅ |
| catalog-api Deployment | ✅ |
| Autres services | ❌ |

---

## 🔜 Prochaine étape

Traduction d'un service supplémentaire (`ordering-api` ou équivalent), en réutilisant la même méthode que pour `catalog-api`. Point d'attention à surveiller dès la prochaine étape : la duplication des secrets identifiée comme dette technique (Étape 3, Bug 1) — à traiter si le nombre de services dupliquant les mêmes identifiants Postgres/RabbitMQ devient trop important à maintenir manuellement.
