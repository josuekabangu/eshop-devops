# Registre Docker Local — eShop

---

## 🎯 Objectif

Mettre en place un registre d'images Docker **local** sur la VM Vagrant, pour permettre à K3s de récupérer les images buildées manuellement (`docker build`), puisque K3s (containerd) et Docker (dockerd) ne partagent **aucun cache d'images** par défaut, même sur la même machine.

---

## 🏗️ Pourquoi un registre local plutôt qu'un import direct

| Option | Retenue ? | Raison |
|---|---|---|
| `k3s ctr images import` (import direct depuis Docker) | ❌ | Contourne le vrai flux de production, mauvaise habitude à long terme |
| Registre distant (Docker Hub, ECR) dès maintenant | ❌ | Prématuré pour du dev local sur une seule VM |
| **Registre local (`registry:2`)** | ✅ | Reproduit le vrai flux `build → tag → push → pull`, transposable tel quel vers un vrai registre cloud plus tard (seul le nom d'hôte change) |

---

## 📦 Structure du projet

```
~/EshopOnContainer/
├── docker/
│   └── docker-compose.yml       # application eShop
└── registry/
    ├── REGISTRY.md               # ce fichier
    └── docker-compose.yml        # registre local + interface web
```

Séparation volontaire : le registre est une brique d'infrastructure transverse, indépendante du cycle de vie applicatif d'eShop — elle mérite son propre fichier versionné.

---

## `registry/docker-compose.yml` — version finale

```yaml
services:
  registry:
    image: registry:2
    container_name: local-registry
    restart: always
    ports:
      - "5000:5000"
    environment:
      REGISTRY_STORAGE_DELETE_ENABLED: "true"
      REGISTRY_HTTP_HEADERS_Access-Control-Allow-Origin: "[http://192.168.56.11:8081]"
      REGISTRY_HTTP_HEADERS_Access-Control-Allow-Methods: "[HEAD,GET,OPTIONS,DELETE]"
      REGISTRY_HTTP_HEADERS_Access-Control-Allow-Credentials: "[true]"
      REGISTRY_HTTP_HEADERS_Access-Control-Allow-Headers: "[Authorization,Accept,Cache-Control]"
    volumes:
      - registry_data:/var/lib/registry
    networks:
      - registry-network

  registry-ui:
    image: joxit/docker-registry-ui:latest
    container_name: registry-ui
    restart: always
    ports:
      - "8081:80"
    environment:
      REGISTRY_TITLE: "eShop Local Registry"
      REGISTRY_URL: "http://192.168.56.11:5000"
      DELETE_IMAGES: "true"
    depends_on:
      - registry
    networks:
      - registry-network

volumes:
  registry_data:

networks:
  registry-network:
    driver: bridge
```

**Rôle de chaque service :**
- `registry` : implémente la Docker Registry HTTP API v2 (stockage + distribution d'images), répond en JSON brut.
- `registry-ui` : interface web qui interroge cette API pour afficher une liste navigable d'images/tags.
- `registry_data` (volume nommé, pas bind mount) : persistance des images à travers les redémarrages — stocké dans la zone gérée par Docker, pas dans un dossier de projet visible.

---

## 🐛 Bugs rencontrés et corrigés

### Bug 1 — Page racine `/` blanche (faux positif, pas un bug)

**Symptôme :** `curl http://localhost:5000/` retourne une page vide.
**Root cause :** un registre Docker n'est pas un site web — il implémente une API JSON. La route racine `/` n'a simplement rien à afficher.
**Vérification correcte :**
```bash
curl http://localhost:5000/v2/_catalog          # liste des repositories
curl http://localhost:5000/v2/catalog-api/tags/list   # tags d'une image donnée
```

### Bug 2 — `REGISTRY_URL` pointant vers le nom de service Docker interne

**Symptôme :** l'UI se charge (le HTML est bien servi), mais n'affiche aucune image.
**Root cause :** `registry-ui` est une application **JavaScript exécutée dans le navigateur** de la machine hôte, pas dans un conteneur. La configuration initiale (`REGISTRY_URL: "http://registry:5000"`) référence un nom DNS qui n'existe que **dans le réseau Docker interne** — le navigateur ne peut pas le résoudre.

**C'est la même classe de bug que le "double issuer" d'Identity-API (Phase 1)** : confondre l'adresse valable en interne (service-à-service) avec l'adresse valable pour un client externe (navigateur).

| Contexte | Bonne adresse |
|---|---|
| Service → Service (interne au réseau Docker/K8s) | Nom du service (`http://registry:5000`) |
| Navigateur → Service (config exposée au client) | IP/hostname externe (`http://192.168.56.11:5000`) |

**Fix :** `REGISTRY_URL: "http://192.168.56.11:5000"`.

### Bug 3 — CORS bloquant les requêtes de l'UI vers l'API du registre

**Symptôme (attendu suite au fix ci-dessus) :** même avec la bonne IP, le navigateur bloque les appels car `registry-ui` (port 8081) et `registry` (port 5000) sont deux **origines différentes** du point de vue du navigateur (ports différents = origine différente).

**Fix :** ajout des en-têtes CORS côté `registry` :
```yaml
environment:
  REGISTRY_HTTP_HEADERS_Access-Control-Allow-Origin: "[http://192.168.56.11:8081]"
  REGISTRY_HTTP_HEADERS_Access-Control-Allow-Methods: "[HEAD,GET,OPTIONS,DELETE]"
  REGISTRY_HTTP_HEADERS_Access-Control-Allow-Credentials: "[true]"
  REGISTRY_HTTP_HEADERS_Access-Control-Allow-Headers: "[Authorization,Accept,Cache-Control]"
```

---

## 🔄 Flux de travail complet — build, push, vérification

```bash
# 1. Build de l'image, taguée directement pour le registre local
cd ~/EshopOnContainer/docker
docker build -f ../src/Catalog.API/Dockerfile -t localhost:5000/catalog-api:latest ..

# 2. Push vers le registre local
docker push localhost:5000/catalog-api:latest

# 3. Vérification via l'API
curl http://192.168.56.11:5000/v2/_catalog

# 4. Vérification visuelle
# http://192.168.56.11:8081
```

---

## ⚠️ Configuration requise côté K3s (à venir)

K3s (containerd) refuse par défaut de parler à un registre HTTP non chiffré. Configuration nécessaire avant de pouvoir déployer une image depuis ce registre sur K3s :

```bash
sudo mkdir -p /etc/rancher/k3s
sudo tee /etc/rancher/k3s/registries.yaml <<EOF
mirrors:
  "localhost:5000":
    endpoint:
      - "http://localhost:5000"
EOF

sudo systemctl restart k3s
```

Vérification :
```bash
sudo k3s crictl pull localhost:5000/catalog-api:latest
```

⚠️ **[PROD BEST PRACTICE]** Ce registre HTTP non sécurisé, sans authentification, n'est acceptable qu'en dev isolé sur une VM privée. Un vrai registre de production (ECR, GCR, Docker Hub privé) exige systématiquement HTTPS + authentification — jamais de push anonyme en prod.

⚠️ **[PROD BEST PRACTICE]** Le tag `latest` est **mutable** et dangereux dès qu'on introduira un vrai pipeline CI/CD — il peut changer sous les pieds d'un déploiement. Dès la mise en place de GitHub Actions, les images seront taguées avec le SHA du commit Git plutôt que `latest`, pour garantir qu'une référence d'image pointe toujours vers exactement le même contenu.

---

## 🧠 Piliers consolidés durant cette étape

| Concept | Application ici |
|---|---|
| **Immuabilité / build once, deploy many** | Le registre est le point de passage obligé entre "image construite" et "image déployée" — sans lui, chaque environnement devrait rebuilder, cassant la garantie d'identité entre ce qui a été testé et ce qui tourne réellement. |
| **Interne vs externe (DNS)** | Troisième occurrence de ce principe depuis le début du parcours (Identity-API, puis ce registre) — un nom de service Docker/K8s n'a de sens qu'entre composants du même réseau, jamais côté client humain. |
| **GitOps** | Le fichier `registry/docker-compose.yml`, versionné et séparé du compose applicatif, rend la configuration du registre reproductible sur n'importe quelle nouvelle VM. |

---

## 🔜 Prochaine étape

Configuration de `registries.yaml` pour K3s, vérification du `pull` depuis le cluster, puis écriture du `Deployment` complet de `catalog-api` référençant `localhost:5000/catalog-api:latest`.
