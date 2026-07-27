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
| `identity-api/identity-deployment.yaml` | ✅ Validé | Duende IdentityServer — double Service (ClusterIP interne + NodePort externe) |
| `catalog-api/catalog-deployment.yaml` | ✅ Validé | Catalog API — Deployment stateless, premier service applicatif |
| `basket-api/basket-deployment.yaml` | ✅ Validé | Basket API — gRPC + Redis |
| `ordering-api/ordering-deployment.yaml` | ✅ Validé | Ordering API — premier service migré sans aucun bug |
| `order-processor/order-processor-deployment.yaml` | ✅ Validé | Worker en arrière-plan, sans Service (pas de port exposé) |
| `payment-processor/payment-processor-deployment.yaml` | ✅ Validé | Worker en arrière-plan, sans Service, Secret dédié (RabbitMQ uniquement) |
| `webhooks-api/webhooks-deployment.yaml` | ✅ Validé | Webhooks API — Postgres + RabbitMQ + Identity, aucun bug |
| `webhook-client/webhook-client-deployment.yaml` | ✅ Validé | Blazor OAuth2 client — NodePort seul, pas de Service interne |
| `webapp/webapp-deployment.yaml` | ✅ Validé | Blazor WebApp (BFF) — dernière pièce, double Service, catalogue + panier validés |
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

## Étape 4 — `identity-api` (Deployment + double exposition Service)

### Contexte

`ordering-api` référence `Identity__Url: "http://identity-api:8080"` dans son `docker-compose.yml` d'origine. Migrer `ordering-api` sans d'abord migrer `identity-api` aurait reproduit le même problème de réseaux isolés déjà rencontré avec RabbitMQ (Étape 2) : un nom de service Docker Compose inaccessible depuis K3s. Décision : migrer `identity-api` avant `ordering-api`.

### Particularité de ce service — double besoin d'exposition

Contrairement aux services précédents, `identity-api` doit être joignable par **deux publics différents**, avec des adresses différentes :
- Le **navigateur** (flux de login OAuth) → doit atteindre `http://192.168.56.11:5223` (port fixé dans `IssuerUri`, cohérent avec la Phase 1 Docker Compose)
- Les **autres services K8s** (`ordering-api`, futur `basket-api`...) → doivent atteindre `http://identity-api:8080` en interne

Un seul `Service` ne peut pas remplir ces deux rôles proprement — solution : **deux `Service` distincts pointant vers le même `Deployment`** (`identity-api`, ClusterIP interne, et `identity-api-external`, NodePort).

### Fichiers produits

```
k8s/identity-api/
├── identity-api-secret.yaml
├── identity-api-configmap.yaml
├── identity-deployment.yaml
├── identity-service.yaml            (interne, ClusterIP)
└── identity-service-external.yaml   (externe, NodePort)
```

`identity-api-configmap.yaml` reprend l'`IssuerUri` et les URLs client (`WebAppClient`, `BasketApiClient`...) telles quelles — ces services tournent encore en Docker Compose à ce stade, exposés sur ces mêmes ports via le mapping Compose existant. `identity-deployment.yaml` utilise `envFrom.configMapRef` pour injecter toutes les clés du ConfigMap d'un coup, plutôt qu'une entrée `env` par clé.

### Configuration K3s requise — extension de la plage NodePort

Par défaut, K3s restreint les `NodePort` à la plage **30000-32767**. Le port `5223` requis (cohérence avec `IssuerUri` déjà fixé en Phase 1) est en dehors de cette plage.

```bash
sudo mkdir -p /etc/systemd/system/k3s.service.d
sudo tee /etc/systemd/system/k3s.service.d/nodeport-range.conf <<EOF
[Service]
ExecStart=
ExecStart=/usr/local/bin/k3s server --service-node-port-range=5000-32767
EOF
sudo systemctl daemon-reload
sudo systemctl restart k3s
```

⚠️ **[PROD BEST PRACTICE]** Élargir la plage NodePort est acceptable pour du dev local avec des ports hérités. En prod réelle, l'exposition externe passerait plutôt par un `Ingress` avec un nom de domaine — pas de contrainte de plage de ports.

### Bugs rencontrés et corrigés

**Bug 1 — `kind: configMap` (casse incorrecte)**
Symptôme : `no matches for kind "configMap" in version "v1"`.
Root cause : Kubernetes attend `kind: ConfigMap` (casse exacte) — 3ᵉ occurrence de ce type d'erreur depuis le début du parcours (après `valueFROM` et `kind: Secret` au lieu de `ConfigMap`, tous deux sur Postgres).
Fix : correction de la casse.

**Bug 2 — `nodePort: 5223` hors plage autorisée**
Symptôme : `Invalid value: 5223: provided port is not in the valid range. The range of valid ports is 30000-32767`.
Root cause : plage NodePort par défaut de K3s incompatible avec le port hérité fixé dans `IssuerUri`.
Fix : extension de la plage via override systemd (voir ci-dessus).
Décision retenue plutôt que l'alternative : changer le port dans `IssuerUri` aurait cassé la cohérence avec toute la config OAuth déjà en place (tokens, redirections) — modifier la contrainte K3s a été jugé moins risqué que de propager un changement de port.

**Bug 3 — nom de Secret incohérent (`identity-api-sercret` vs `identity-api-secrets`)**
Symptôme : Pod bloqué en `CreateContainerConfigError`, sans logs applicatifs (`Error: secret "identity-api-secrets" not found`).
Root cause : faute de frappe dans le nom du Secret créé, différent de la référence dans le Deployment — Kubernetes ne fait aucun rapprochement approximatif entre noms d'objets.
Méthode de diagnostic : `kubectl describe pod <nom>`, section `Events` — contrairement à `kubectl logs` qui ne montre rien tant que le conteneur n'a jamais démarré, `describe` expose la cause exacte du blocage.
Fix : alignement des noms.

### Validation sur k3s

```
kubectl get pods
# identity-api-5cd765c8dd-ww9wj   1/1   Running

kubectl get svc identity-api identity-api-external
# identity-api-external   NodePort   ...   5223:5223/TCP

curl -s -o /dev/null -w "%{http_code}\n" http://192.168.56.11:5223/.well-known/openid-configuration
# 200
```

### Piliers consolidés durant cette étape

| Concept | Application concrète |
|---|---|
| **Double exposition Service pour un besoin double** | Un seul `Deployment` peut être ciblé par plusieurs `Service` différents, chacun avec un rôle distinct (interne vs externe) — pattern réutilisable pour tout service ayant ce même besoin dual. |
| **`kubectl describe pod` avant `kubectl logs`** | Pour tout Pod qui ne démarre jamais son conteneur (`CreateContainerConfigError`, `ImagePullBackOff`...), `describe` + section `Events` est la première commande à lancer — `logs` ne fonctionne que si le conteneur a démarré au moins une fois. |
| **Exactitude stricte des noms d'objets K8s** | 3ᵉ occurrence de bug de nommage depuis le début du parcours — Kubernetes ne tolère aucune approximation entre le nom déclaré et le nom référencé. |

---

## Étape 5 — `ordering-api` (Deployment)

### Contexte

Traduction débloquée par la migration préalable d'`identity-api` (Étape 4) : `ordering-api` référence `Identity__Url: "http://identity-api:8080"`, une dépendance qui aurait été inatteignable si `identity-api` était resté en Docker Compose.

**Résultat notable :** premier service migré **sans aucun bug** — confirmation que la méthode (Secret → ConfigMap → Service → Deployment, probes `tcpSocket`, build/push avant apply) est maintenant maîtrisée.

### Fichiers produits

```
k8s/ordering-api/
├── ordering-api-secret.yaml
├── ordering-api-configmap.yaml
├── ordering-deployment.yaml
└── ordering-api-service.yaml
```

**Point de méthode important :** `Identity__Url` pointe vers `http://identity-api:8080` — le `Service` **interne** (`ClusterIP`) créé à l'Étape 4 — et non vers `identity-api-external:5223` (réservé au navigateur). `ordering-api` est un service backend, sa communication avec `identity-api` reste entièrement interne au cluster.

### Flux de déploiement appliqué

```bash
# 1. Build + push — étape désormais systématique avant tout apply
docker build -f ../src/Ordering.API/Dockerfile -t localhost:5000/ordering-api:latest ..
docker push localhost:5000/ordering-api:latest

# 2. Vérification pull K3s
sudo k3s crictl pull localhost:5000/ordering-api:latest

# 3. Application des manifests
kubectl apply -f ordering-api-secret.yaml
kubectl apply -f ordering-api-configmap.yaml
kubectl apply -f ordering-api-service.yaml
kubectl apply -f ordering-deployment.yaml
```

### Résultat — succès dès la première tentative

`ordering-api-7df666454d-9rqcn` : `1/1 Running` en moins de 30 secondes. Logs confirmant :
- 4 migrations EF Core appliquées avec succès (`Initial`, `FixOrderitemseqSchema`, `Outbox`, `UseEnumForOrderStatus`)
- Création complète du schéma `ordering` (tables `buyers`, `orders`, `orderItems`, `paymentmethods`, `IntegrationEventLog`, séquences dédiées)
- Seed initial des `cardtypes`
- Connexion RabbitMQ démarrée (`Starting RabbitMQ connection on a background thread`)
- Application démarrée et à l'écoute sur le port 8080, `Hosting environment: Production`

Aucun bug rencontré — les erreurs de nommage, de casse YAML, et de gestion des `${VAR}` identifiées sur les étapes précédentes (Postgres, RabbitMQ, catalog-api, identity-api) ont toutes été évitées de manière proactive à l'écriture initiale des fichiers.

### Piliers consolidés durant cette étape

| Concept | Application concrète |
|---|---|
| **Séparation Secret / ConfigMap appliquée sans erreur** | Connection strings (sensibles) dans le Secret, `Identity__Url` (non sensible) dans le ConfigMap — distinction appliquée correctement dès l'écriture initiale, sans itération corrective. |
| **Interne vs externe, choix cohérent d'emblée** | `Identity__Url` pointant vers le Service `ClusterIP` interne, pas vers le NodePort externe — distinction déjà rencontrée à plusieurs reprises (registre Docker, Identity issuer) appliquée correctement sans erreur cette fois. |
| **Maturité méthodologique** | Premier service migré sans aucun bug de casse, de nommage, ou de référence — signe que la méthode de traduction Compose → K8s est désormais intégrée, pas seulement suivie mécaniquement. |

---

## Étape 6 — `order-processor`, `basket-api` & `payment-processor`

### `order-processor` — worker sans Service

`OrderProcessor` scanne périodiquement la base (`SELECT ... FROM ordering.orders WHERE ...`) et agit de façon autonome, sans jamais recevoir d'appel entrant d'un autre composant. Un `Service` Kubernetes n'a de raison d'être que pour donner une adresse stable à un composant **appelé** par d'autres — inutile ici. Décision prise par raisonnement avant l'écriture du manifest, pas découverte après un déploiement raté.

Réutilise le `Secret ordering-api-secrets` existant (mêmes connexions Postgres/RabbitMQ) plutôt que d'en dupliquer un identique — réponse partielle à la dette notée à l'Étape 3.

**Absence de probes :** sans port surveillé, K8s considère le Pod `Ready` dès que le conteneur démarre. Dette notée : un blocage silencieux du worker (ex: connexion RabbitMQ zombie sans crash du process) ne serait pas détecté.

Validé : `1/1 Running`, connexion RabbitMQ démarrée, scan périodique des commandes `Submitted` fonctionnel (logs identiques à la Phase 1 Docker Compose).

### `basket-api` — gRPC + Redis

`Basket.API` expose un service **gRPC** (HTTP/2) — sans impact sur la structure du manifest : un `Service` Kubernetes route au niveau TCP, sans distinction native entre HTTP/1.1 et HTTP/2. Point à anticiper pour une future étape Ingress : si `basket-api` devait être exposé via `Ingress`, celui-ci devrait explicitement supporter HTTP/2 (Traefik le fait nativement).

**Bug rencontré — mismatch de mot de passe Redis :**
Symptôme potentiel (détecté avant impact réel, la connexion Redis de StackExchange.Redis étant lazy) : `basket-api-secret.yaml` déclarait `ConnectionStrings__redis: "redis:6379,password=changeme"`, alors que `redis-secret.yaml` (Étape 2) avait `REDIS_PASSWORD` encodé en base64 pour `password`, pas `changeme`.
Diagnostic concluant : `kubectl exec -it redis-0 -- redis-cli -a changeme ping` → `WRONGPASS invalid username-password pair`.
Décision : réaligner les deux fichiers sur `changeme` (cohérent avec `REDIS_PASSWORD` dans `.env.example`), en réappliquant le Secret **et** en forçant `kubectl rollout restart` sur `redis` (StatefulSet) et `basket-api` (Deployment) — rappel de la leçon de l'Étape 3 : modifier un Secret ne relance jamais automatiquement les Pods qui le consomment.
Validé après correction : `redis-cli -a changeme ping` → `PONG`, `basket-api` `1/1 Running`.

**Point de validation notable :** aucune erreur gRPC `Unauthenticated` (celle qui affectait la Phase 1 Docker Compose à cause du double issuer sur `identity-api`) — confirmation indirecte que le fix `IssuerUri` de l'Étape 4 tient à travers un environnement d'exécution entièrement différent (K3s vs Docker Compose). Validation partielle cependant : aucun appel gRPC réel n'a encore été émis vers `basket-api` dans ce nouvel environnement (`webapp` pas encore migré).

### `payment-processor` — même pattern qu'`order-processor`

Worker sans `Service`, sans probes. Contrairement à `order-processor`, utilise un **Secret dédié** (`payment-processor-secrets`) plutôt qu'une réutilisation — ce service ne touche que RabbitMQ, pas Postgres, donc aucun Secret existant à partager. `ConnectionStrings__EventBus` en PascalCase, fidèle à la casse exacte du `docker-compose.yml` d'origine (différente de `ConnectionStrings__eventbus` ailleurs — vérifié avant de considérer ça comme une incohérence).

Validé : `1/1 Running`, connexion RabbitMQ démarrée.

### Piliers consolidés durant cette étape

| Concept | Application concrète |
|---|---|
| **Service = uniquement pour ce qui reçoit du trafic** | Confirmé en pratique avec `order-processor`/`payment-processor` : décision prise par raisonnement avant l'écriture du manifest. |
| **Réduction de duplication des Secrets, avec discernement** | `order-processor` réutilise `ordering-api-secrets` (mêmes dépendances qu'`ordering-api`) ; `payment-processor` a son propre Secret (dépendances différentes) — la réutilisation n'est pas systématique, elle dépend de ce qui est réellement partagé. |
| **Le protocole applicatif (gRPC) est transparent pour le Service K8s** | Un `Service` route au niveau TCP, sans connaissance de HTTP/1.1 vs HTTP/2 — seule une future couche Ingress devra en tenir compte explicitement. |
| **Un Secret modifié ne relance jamais les Pods automatiquement** | 2ᵉ occurrence de cette leçon (après l'Étape 3) — `kubectl rollout restart` reste un réflexe obligatoire après toute modification de Secret/ConfigMap consommé en variable d'environnement. |
| **Un fix de cause racine tient à travers un changement d'environnement** | Le correctif `IssuerUri` (Phase 1 Docker Compose) continue de fonctionner sans modification sur K3s — preuve que c'était une correction structurelle, pas un contournement local. |

---

## Étape 7 — `webhooks-api` (Deployment)

### Contexte

8ᵉ composant opérationnel sur K3s (3 infra + 5 applicatifs). `payment-processor` (worker minimal, dépendance unique à RabbitMQ, Secret dédié faute de connexion Postgres à partager) a déjà été traité et documenté à l'Étape 6. Seuls `webhook-client` et `webapp` restent à migrer pour compléter la stack eShop.

⚠️ **Remarque de nommage héritée du repo d'origine, non corrigée** (sur `payment-processor`) : `ConnectionStrings__EventBus` (E et B majuscules) diffère en casse de `ConnectionStrings__eventbus` utilisé ailleurs. Sans impact fonctionnel — les clés de configuration .NET sont insensibles à la casse — conservée telle quelle par fidélité au code source plutôt que "nettoyée" arbitrairement.

### `webhooks-api` — dépendances Postgres + RabbitMQ + Identity-API

Pattern identique à `catalog-api`/`ordering-api`/`webhooks-api` : connection strings (Postgres + RabbitMQ) dans un `Secret`, `Identity__Url` dans un `ConfigMap`.

```
k8s/webhooks-api/
├── webhooks-api-secret.yaml
├── webhooks-api-configmap.yaml
├── webhooks-deployment.yaml
└── webhooks-api-service.yaml
```

### Résultat de déploiement

`1/1 Running` en 51 secondes. Migration EF Core `Initial` appliquée avec succès sur `webhooksdb`, connexion RabbitMQ démarrée, Kestrel à l'écoute. Aucun bug de manifeste.

**Détail technique observé dans les logs (bénin, pas un bug) :**
```
Cannot load library libgssapi_krb5.so.2
Error: libgssapi_krb5.so.2: cannot open shared object file: No such file or directory
```
Npgsql tente par défaut une négociation **GSS encryption** (Kerberos), nécessitant une bibliothèque native absente de l'image `aspnet` minimale. Ce n'est pas une exception .NET structurée — remarquer l'absence de préfixe `info:`/`warn:`/`fail:` : c'est un `dlopen` natif qui écrit directement sur stderr, en dehors du logger ASP.NET. Npgsql détecte l'échec et retombe automatiquement sur une négociation TLS classique sans GSSAPI.

Juste après, `fail: ... Failed executing DbCommand` sur `SELECT "MigrationId" FROM "__EFMigrationsHistory"` est le comportement **normal** d'EF Core sur une base neuve : la table n'existe pas encore avant la première migration, la requête échoue une fois par construction (`relation does not exist`), et EF Core en déduit qu'il doit appliquer `Initial` — ce qui suit immédiatement. Probablement rencontré aussi sur `catalog-api`/`ordering-api`/`identity-api` (bases créées fraîches par le script d'init Postgres K8s), simplement pas visible dans les extraits de logs collés à l'époque.

### Piliers consolidés durant cette étape

| Concept | Application concrète |
|---|---|
| **Un Secret dédié quand aucune réutilisation n'est pertinente** | `payment-processor` n'a pas de dépendance Postgres commune avec un autre service migré — contrairement à `order-processor`/`ordering-api`, un Secret dédié était la bonne approche, pas une règle générale de "toujours dédupliquer". |
| **Incohérences de casse héritées du code source, à ne pas corriger sans raison** | `ConnectionStrings__EventBus` vs `ConnectionStrings__eventbus` : différence sans impact fonctionnel, conservée telle quelle par fidélité à la source. |
| **Avertissement natif vs erreur applicative** | Un message sans préfixe de logger structuré (`libgssapi_krb5`) provient d'une bibliothèque native, pas du code .NET — à diagnostiquer différemment d'une exception classique. |
| **Échec attendu sur base neuve** | Le premier `SELECT __EFMigrationsHistory` échoue systématiquement avant la toute première migration — normal, pas à confondre avec une vraie panne de connexion. |
| **Méthode stabilisée** | 8 services migrés consécutifs sans bug de structure (Secret/ConfigMap/Deployment/Service) — seuls les patterns spécifiques à chaque service demandent encore une adaptation. |

---

## Étape 8 — `webhook-client` & `webapp` (derniers composants)

### `webhook-client`

Aucune donnée sensible — uniquement des URLs (`IdentityUrl`, `CallBackUrl`) → `ConfigMap` seul, pas de `Secret`. Principe interne/externe confirmé une fois de plus : `IdentityUrl` en adresse externe (`192.168.56.11:5223`), le navigateur devant la résoudre pour la redirection OAuth, pas le serveur. Un seul `Service` `NodePort` (`webhook-client-external`) — pas de Service interne, rien d'autre dans le cluster n'appelle ce composant.

Port `5114` hors plage NodePort par défaut, mais déjà couvert par l'élargissement `5000-32767` fait à l'Étape 4 — aucune configuration supplémentaire nécessaire.

Validé : `1/1 Running`, page "Order management" affichée via `http://192.168.56.11:5114`.

### `webapp` — le service le plus richement connecté

```
k8s/webapp/
├── webapp-secret.yaml            (EventBus)
├── webapp-configmap.yaml         (IdentityUrl/CallBackUrl externes + services__*__http__0 internes)
├── webapp-deployment.yaml
├── webapp-service.yaml           (ClusterIP)
└── webapp-service-external.yaml  (NodePort 5100)
```

`webapp` orchestre simultanément Catalog, Ordering, Basket et Identity. Séparation interne/externe appliquée **sur un même Deployment** : `IdentityUrl`/`CallBackUrl` en adresses externes (résolues par le navigateur), `services__catalog-api__http__0` etc. en noms de Service K8s internes (résolus côté serveur) — le pattern le plus récurrent de toute la migration, appliqué ici à son point le plus dense.

### Bug fonctionnel — même mismatch Redis, révélé cette fois par un vrai scénario utilisateur

Premier test de bout en bout (ajout au panier) → `Grpc.Core.RpcException: Status(StatusCode="Unknown", Detail="Exception was thrown by handler.")` côté `webapp`, message générique masquant la vraie cause en `Production`.

**Méthode de diagnostic déterminante :** le message côté `webapp` (l'appelant) ne montrait qu'une exception générique. La cause réelle n'est apparue qu'en consultant les logs de `basket-api` (le service **appelé**) :
```
StackExchange.Redis.RedisConnectionException: AuthenticationFailure
   ---> System.Exception: Error: NOAUTH Authentication required.
```
**Principe à généraliser :** face à un appel réseau (HTTP, gRPC) qui échoue avec un message vague côté appelant, toujours consulter en priorité les logs du service **appelé** — c'est lui qui détient l'exception réelle et sa stack trace complète.

Root cause : même mismatch de mot de passe Redis que celui déjà documenté et corrigé à l'Étape 6 ([[k8s-redis-password-mismatch]]) — confirmé ici non pas via un test `redis-cli` isolé, mais via un vrai échec fonctionnel utilisateur. Preuve concrète que la dette technique des secrets dupliqués sans référence croisée (identifiée dès l'Étape 3) produit des incohérences réelles, pas seulement théoriques.

**Solution structurelle à envisager (Phase 2/3) :** un gestionnaire de secrets externe (Vault, AWS Secrets Manager) comme source unique de vérité, éliminant la duplication manuelle entre Secrets Kubernetes.

Validé après re-confirmation : catalogue affiché avec succès (filtres, marques, images), panier fonctionnel — flux complet de bout en bout validé.

### Piliers consolidés durant cette étape

| Concept | Application concrète |
|---|---|
| **Interne vs externe (DNS)** | Confirmé une nouvelle fois sur `webhook-client` et `webapp` — le pattern le plus récurrent de toute la migration, désormais appliqué sans hésitation même sur le service le plus connecté. |
| **Diagnostic au bon niveau (service appelé, pas appelant)** | Un message d'erreur générique côté client (gRPC, HTTP) ne doit jamais être pris pour la cause réelle — toujours remonter aux logs du service qui a effectivement levé l'exception. |
| **Dette technique confirmée par l'usage réel** | Les secrets dupliqués, identifiés en théorie dès l'Étape 3, ont produit un vrai bug fonctionnel ici — une dette tracée tôt permet un diagnostic rapide plutôt qu'une découverte à l'aveugle. |

---

## 🏆 Bilan — stack eShop complète sur K3s

**12 composants opérationnels** (3 infrastructure + 9 applicatifs), validés de bout en bout : authentification OAuth2, catalogue, panier, commandes, paiement, notifications webhooks.

| Catégorie | Composants |
|---|---|
| Infrastructure (StatefulSet) | `postgres`, `rabbitmq`, `redis` |
| Applicatif (Deployment) | `catalog-api`, `identity-api`, `ordering-api`, `basket-api`, `webhooks-api`, `webhook-client`, `webapp` |
| Workers (Deployment, sans Service) | `order-processor`, `payment-processor` |

Restent hors scope de cette Phase 1 K8s : `migrations-job.yaml` (Job EF Core dédié, dette technique tracée depuis l'Étape 1) et `ingress.yaml` (Traefik, alternative future au NodePort pour l'exposition externe).

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
| identity-api Deployment | ✅ |
| ordering-api Deployment | ✅ |
| order-processor Deployment | ✅ |
| basket-api Deployment | ✅ |
| payment-processor Deployment | ✅ |
| webhooks-api Deployment | ✅ |
| webhook-client Deployment | ✅ |
| webapp Deployment | ✅ |
| **Stack eShop complète (12 composants)** | ✅ |

---

## 🔜 Prochaine étape

Stack applicative complète — reste la dette technique accumulée à traiter avant de clore la Phase 1 K8s : `migrations-job.yaml` (Job EF Core dédié, Étape 1) et le script d'init Postgres en `Job` séparé. Ensuite, `ingress.yaml` (Traefik) pourrait remplacer les `NodePort` (`identity-api-external`, `webhook-client-external`, `webapp-external`) par une exposition unifiée sous `eshop.local`. Au-delà, Phase 2 (Terraform, GitLab CI/CD) selon la roadmap de `DEVOPS.md`.
