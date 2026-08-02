# CI/CD — Pipeline de build automatique et bascule vers GHCR

---

## 🎯 Objectif

Automatiser la construction et la publication des 9 images Docker applicatives, jusque-là buildées et poussées manuellement vers un registre local. Deuxième étape naturelle après un déploiement Kubernetes manuel réussi, avant Helm/Kustomize et ArgoCD.

**Pourquoi cet ordre (CI avant GitOps/Helm) :** automatiser un déploiement (ArgoCD) n'a de sens que si l'artefact déployé (l'image) est lui-même produit de façon fiable et versionnée. Automatiser la synchronisation d'un processus de build encore manuel reviendrait à automatiser le hasard.

**Pourquoi l'infrastructure (Postgres, RabbitMQ, Redis) n'entre pas dans ce périmètre :** ces trois services utilisent des images officielles tierces, jamais construites depuis du code source à nous — rien qu'un pipeline CI puisse reconstruire. Le CI ne concerne que les composants avec un Dockerfile et du code applicatif propre.

---

## 🏗️ Choix du registre : GitHub Container Registry (ghcr.io)

| Option | Retenue ? | Raison |
|---|---|---|
| Registre local (`localhost:5000`) | ❌ pour le CI | Inaccessible depuis les runners GitHub Actions (cloud), pas de réseau partagé avec la VM |
| Self-hosted runner sur la VM | ❌ | Complexité supplémentaire non nécessaire à ce stade |
| **GitHub Container Registry (ghcr.io)** | ✅ | Authentification automatique via `GITHUB_TOKEN` (généré par GitHub Actions à chaque run), aucun credential à gérer manuellement, intégration native au repo |

**Visibilité des packages : publique**, choisie pour avancer sans configuration supplémentaire d'`imagePullSecret`. Dette technique tracée : un package public est accessible par n'importe qui — acceptable ici car aucune donnée sensible n'est embarquée dans les images (les secrets restent exclusivement en Kubernetes), mais ce n'est pas le réflexe de production standard.

---

## 🐛 Bug 1 — contexte de build différent entre local et CI

### Symptôme

Premier run du pipeline en échec :
```
COPY eShop/src ./src
ERROR: failed to calculate checksum: "/eShop/src": not found
```

### Root cause réelle (après une première hypothèse erronée)

Hypothèse initiale incorrecte : confusion entre le dossier `src/` contenant les Dockerfiles et le dossier `eShop/src/` contenant le code source — en réalité les deux coexistent normalement dans l'arborescence locale (`src/Catalog.API/Dockerfile` pour le Dockerfile, `eShop/src/Catalog.API/...` pour le code C#), structure confirmée correcte après inspection complète (`tree -L 2`).

La vraie cause : le dossier `eShop/` contenait son propre `.git` interne (clone du repo tiers `dotnet/eShop` réalisé sans intention de sous-module). Git le traitait comme un **gitlink** (référence de sous-module), pas comme des fichiers réels suivis — `git ls-files eShop` ne retournait qu'une seule ligne (`eShop/`) au lieu de centaines de fichiers.

**Complication supplémentaire :** après suppression du `.git` interne (`rm -rf eShop/.git`), `git status` restait improbablement "clean" — signe d'un second problème : une ligne `eShop/` présente dans `.gitignore`, excluant silencieusement tout le dossier, sans jamais générer d'erreur ou d'avertissement visible.

### Fix

```bash
rm -rf eShop/.git                    # supprime le repo Git imbriqué
sed -i '/^eShop\/$/d' .gitignore     # retire l'exclusion silencieuse
git add eShop/ .gitignore
git commit -m "fix: include eShop source as regular tracked files"
git push origin main
```

### Principe illustré

**"Ça marche localement" ne garantit jamais que Git suit réellement les fichiers concernés.** Deux mécanismes distincts peuvent masquer silencieusement un contenu à Git : un gitlink (sous-module implicite non résolu) et une règle `.gitignore` — ni l'un ni l'autre ne produisent d'erreur visible en usage local normal. `git ls-files <dossier>` reste le réflexe de vérification fiable avant de faire confiance à un `git status` propre sur un dossier critique.

---

## 🐛 Bug 2 — structure YAML invalide après retrait de l'option imagePullSecret

### Symptôme

```
Error from server (BadRequest): error when creating "catalog-deployment.yaml":
Deployment in version "v1" cannot be handled as a Deployment:
strict decoding error: unknown field "spec.template.spec.template"
```

### Root cause

Reste d'un bloc `template:`/`imagePullSecrets:` mal imbriqué (probablement un résidu de copier-coller de l'option "package privé" finalement non retenue), créant un second niveau `template:` invalide sous `spec.template.spec`. `imagePullSecrets` doit être un frère direct de `containers:`, jamais emboîté dans un `template:` supplémentaire.

Bug secondaire associé : le placeholder `<ton-username>` dans `image: ghcr.io/<ton-username>/...` jamais remplacé par la valeur réelle.

### Fix

Suppression complète du bloc `imagePullSecrets` (inutile avec un package public) et remplacement du placeholder par le nom d'utilisateur réel (`josuekabangu`).

### Principe illustré

Un placeholder oublié dans un manifest appliqué ne produit pas toujours une erreur explicite immédiate — ici la structure YAML invalide l'a révélé avant l'application, mais un placeholder resté dans un champ valide syntaxiquement (comme un nom d'image) aurait produit une erreur `ImagePullBackOff` bien plus tardive et moins directement diagnostiquable.

---

## 🏗️ Architecture du pipeline final

### Premier essai — un workflow par service

Fonctionnel pour `catalog-api`, mais reconnu comme anti-pattern dès la validation de ce premier service : dupliquer ce workflow 9 fois créerait une dette de maintenance (toute évolution — changement de version d'action, ajout d'un scan de sécurité — nécessiterait 9 modifications manuelles identiques, avec risque de divergence).

### Solution retenue — un seul workflow avec `strategy: matrix`

```yaml
# .github/workflows/build-push-all.yml
name: Build and Push all services

on:
  push:
    branches: [main]

env:
  REGISTRY: ghcr.io

jobs:
  build-and-push:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write

    strategy:
      fail-fast: false
      matrix:
        service:
          - name: catalog-api
            dockerfile: src/Catalog.API/Dockerfile
          - name: identity-api
            dockerfile: src/Identity.API/Dockerfile
          - name: ordering-api
            dockerfile: src/Ordering.API/Dockerfile
          - name: order-processor
            dockerfile: src/OrderProcessor/Dockerfile
          - name: basket-api
            dockerfile: src/Basket.API/Dockerfile
          - name: payment-processor
            dockerfile: src/PaymentProcessor/Dockerfile
          - name: webhooks-api
            dockerfile: src/Webhooks.API/Dockerfile
          - name: webhook-client
            dockerfile: src/WebhookClient/Dockerfile
          - name: webapp
            dockerfile: src/WebApp/Dockerfile

    steps:
      - name: Checkout repository
        uses: actions/checkout@v4

      - name: Log in to GitHub Container Registry
        uses: docker/login-action@v3
        with:
          registry: ${{ env.REGISTRY }}
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Build and push ${{ matrix.service.name }}
        uses: docker/build-push-action@v6
        with:
          context: .
          file: ${{ matrix.service.dockerfile }}
          push: true
          tags: |
            ${{ env.REGISTRY }}/${{ github.repository_owner }}/${{ matrix.service.name }}:${{ github.sha }}
            ${{ env.REGISTRY }}/${{ github.repository_owner }}/${{ matrix.service.name }}:latest
```

**Pourquoi la matrix, choix confirmé "comme en entreprise" :**
- **Maintenance** : une modification du pipeline (version d'action, étape de scan) se fait une fois, pas neuf fois avec risque de divergence.
- **Lisibilité d'historique Git** : un commit modifiant le workflow raconte une histoire claire, contre neuf fichiers modifiés simultanément.
- **Usage canonique** : c'est le cas d'usage documenté pour lequel la fonctionnalité `matrix` existe, pas un détournement.

`fail-fast: false` : un service qui échoue à builder n'annule pas les 8 autres jobs en cours — visibilité indépendante par service, essentielle en prod.

### Résultat

9 jobs exécutés en parallèle, tous réussis (de 39s à 1m45s selon le service), durée totale du run : 1m55s.

---

## 🔄 Flux complet mis en place

```
git push origin main
        ↓
GitHub Actions déclenché (matrix, 9 jobs parallèles)
        ↓
Pour chaque service : checkout → build → push vers ghcr.io (tag SHA + latest)
        ↓
Packages rendus publics manuellement (une fois, par service)
        ↓
Manifests K8s mis à jour (image: ghcr.io/josuekabangu/<service>:latest)
        ↓
kubectl apply + kubectl rollout restart
        ↓
Pods redémarrés avec la nouvelle image, sans interruption (RollingUpdate)
```

---

## 🧠 Piliers consolidés

| Concept | Application |
|---|---|
| **CI avant GitOps** | Ordre naturel en entreprise : fiabiliser la production d'artefacts avant d'automatiser leur déploiement. |
| **`.gitignore` et gitlinks silencieux** | Deux mécanismes Git distincts peuvent masquer un contenu sans jamais produire d'erreur visible — `git ls-files` reste le réflexe de vérification fiable. |
| **`strategy: matrix` comme standard professionnel** | Une seule source de vérité pour N variations d'un même pipeline, plutôt que N fichiers dupliqués — choix confirmé "comme en entreprise", pas une simplification de convenance. |
| **`fail-fast: false`** | Visibilité indépendante par service dans un pipeline parallélisé — un échec isolé ne doit jamais masquer l'état des autres composants. |
| **Tag SHA vs `latest`** | Chaque image poussée porte aussi le SHA du commit (`${{ github.sha }}`) — traçabilité complète entre code et artefact, `latest` conservé en parallèle uniquement pour compatibilité de transition. |

---

## ⚠️ Dette technique à retenir

- **Packages publics** plutôt que privés + `imagePullSecret` — acceptable en apprentissage, à revoir pour un scénario plus proche de la prod.
- **Registre Docker local (`localhost:5000`)** devenu obsolète pour l'application — à arrêter proprement (`docker compose down` dans `registry/`) une fois confirmé que plus aucun service n'y fait référence.
- **Tag `latest` toujours utilisé dans les manifests K8s** — la vraie pratique de production référencerait le SHA ou le digest exact, jamais un tag mutable, pour garantir qu'un déploiement pointe toujours vers une image figée et identifiée.

---

## 🔜 Prochaine étape naturelle

Helm ou Kustomize — pour résoudre structurellement deux dettes déjà tracées depuis les premières étapes de migration : l'absence de templating natif Kubernetes (`${VAR}` jamais substitué) et la duplication de secrets entre objets (`ConnectionStrings__redis` divergent, cause du bug diagnostiqué sur `basket-api`).

---

*Document — Méthode Josue, Mentor DevOps Senior.*
