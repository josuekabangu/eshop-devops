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

```bash
docker run -d --name registry --restart=always -p 5000:5000 registry:2
```

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
| `redis-deployment.yaml` | ❌ | Redis — Deployment |
| `rabbitmq-deployment.yaml` | ❌ | RabbitMQ — Deployment |
| `identity-api.yaml` | ❌ | Duende IdentityServer |
| `catalog-api.yaml` | ❌ | Catalog API |
| `basket-api.yaml` | ❌ | Basket API |
| `ordering-api.yaml` | ❌ | Ordering API |
| `webapp.yaml` | ❌ | Blazor WebApp (BFF) |
| `migrations-job.yaml` | ❌ | Job EF Core (Bug 5) |
| `ingress.yaml` | ❌ | Traefik — `eshop.local` |

---

## Choix d'architecture K8s

### Postgres → StatefulSet (pas Deployment)

| | Deployment | StatefulSet |
|-|------------|-------------|
| Nom du Pod | `postgres-abc123` (aléatoire) | `postgres-0` (stable) |
| Volume lié au Pod | Non — PVC peut aller sur n'importe quel Pod | Oui — `data-postgres-0` lié à `postgres-0` |
| Redémarrage | Nouveau Pod, nouveau nom | Même nom, retrouve son volume |

**Règle :** tout service avec état persistant → `StatefulSet`.

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

### Ingress → solution Bug 9 (double issuer)

Avec un `Ingress` Traefik exposant `eshop.local`, identity-api reçoit toutes les requêtes via le même hostname → un seul issuer par construction → Bug 9 disparaît.

```
Browser → eshop.local/identity → identity-api  (issuer = eshop.local)
basket-api → eshop.local/identity → identity-api (même issuer)
```

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
| Autres services | ❌ |

---

## Validation Postgres StatefulSet

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
