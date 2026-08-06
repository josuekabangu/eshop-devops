# GitOps — ArgoCD & ApplicationSet

Dernière étape du parcours DevOps engagé depuis la Phase 1 : remplacer les `kubectl apply`/`helm install`/`helm upgrade` manuels par une réconciliation **automatique et continue** entre l'état déclaré dans le repo Git et l'état réel du cluster K3s — le principe fondamental du GitOps.

---

## Installation d'ArgoCD

```bash
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

Exposition de l'interface web via `NodePort` (plage déjà étendue à `5000-32767` depuis la migration `identity-api`) :
```bash
kubectl patch svc argocd-server -n argocd -p '{"spec": {"type": "NodePort", "ports": [{"port": 443, "targetPort": 8080, "nodePort": 8443}]}}'
```

Accès : `https://192.168.56.11:8443`, identifiants initiaux :
```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
```

---

## Pilote — `Application` unique pour `catalog-api`

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: catalog-api
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/josuekabangu/eshop-devops.git
    targetRevision: main
    path: helm/catalog-api
  destination:
    server: https://kubernetes.default.svc
    namespace: default
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

### Validation en deux temps

**Test 1 — synchronisation automatique depuis Git :**
```bash
sed -i 's/replicaCount: 1/replicaCount: 2/' helm/catalog-api/values.yaml
git add helm/catalog-api/values.yaml
git commit -m "test: scale catalog-api to 2 replicas via GitOps"
git push origin main
```
Résultat : un second Pod `catalog-api` créé automatiquement, sans `helm upgrade` manuel.

**Test 2 — correction automatique de dérive (`selfHeal`) :**
```bash
kubectl scale deployment catalog-api --replicas=5
```
Résultat : les 3 Pods excédentaires (créés hors de tout processus Git) supprimés automatiquement en **2 secondes**, retour à 2 réplicas — l'état déclaré dans Git.

**Cette démonstration est la preuve la plus concrète du concept de Configuration Drift** défini dès la Phase 1 (Vagrant) : plutôt que d'être seulement évitée par discipline, la dérive est ici détectée et corrigée automatiquement par le système lui-même.

---

## Bug rencontré et corrigé — CRD `ApplicationSet` manquant

### Symptôme

```
error: resource mapping not found for name: "eshop" namespace: "argocd"
from "argocd/eshop-applicationset.yaml": no matches for kind "ApplicationSet"
in version "argoproj.io/v1alpha1"
ensure CRDs are installed first
```

`kubectl get pods -n argocd` révélait par ailleurs `argocd-applicationset-controller` avec **172 redémarrages** en 20h — crash-loop, le contrôleur tentant en boucle de surveiller un CRD (`applicationsets.argoproj.io`) absent du cluster, malgré une installation initiale d'ArgoCD apparemment complète.

### Root cause

Une réapplication du manifest complet d'installation a révélé la vraie cause :
```
The CustomResourceDefinition "applicationsets.argoproj.io" is invalid:
metadata.annotations: Too long: may not be more than 262144 bytes
```

`kubectl apply` stocke par défaut la configuration complète appliquée dans une annotation (`kubectl.kubernetes.io/last-applied-configuration`), utilisée pour les futurs merges à 3 voies. Le CRD `ApplicationSet` — volumineux du fait de son schéma de validation détaillé — dépasse la limite Kubernetes de 256 Ko pour une annotation, provoquant l'échec silencieux de sa création lors de l'installation initiale.

### Fix

```bash
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml --server-side --force-conflicts
```

`--server-side` délègue le calcul du merge à l'API Kubernetes elle-même plutôt qu'au client `kubectl`, contournant la limite de taille liée à l'annotation `last-applied-configuration` — solution recommandée par la documentation Kubernetes pour ce type de CRD volumineux.

### Principe illustré

Un échec de création partiel lors d'une installation complexe (nombreux objets appliqués en un seul `kubectl apply`) peut passer totalement inaperçu si seule la fin de la sortie est examinée — l'erreur apparaissait ici après des dizaines de lignes `unchanged`/`configured` sans lien apparent. Réappliquer un manifest d'installation complet reste une opération idempotente et sûre pour diagnostiquer ce genre de situation, mais la sortie complète doit être lue, pas seulement sa conclusion apparente.

---

## Généralisation — `ApplicationSet` plutôt que 12 `Application` séparées

**Décision alignée sur le choix déjà fait en CI :** même raisonnement que `strategy: matrix` (GitHub Actions) — une seule source de vérité pour N variations d'un même pattern, plutôt que la duplication de fichiers quasi identiques.

```yaml
# argocd/eshop-applicationset.yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: eshop
  namespace: argocd
spec:
  generators:
    - git:
        repoURL: https://github.com/josuekabangu/eshop-devops.git
        revision: main
        directories:
          - path: helm/*
  template:
    metadata:
      name: "{{path.basename}}"
    spec:
      project: default
      source:
        repoURL: https://github.com/josuekabangu/eshop-devops.git
        targetRevision: main
        path: "{{path}}"
      destination:
        server: https://kubernetes.default.svc
        namespace: default
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
```

**Mécanisme :** le générateur `git.directories` scanne `helm/*` du repo et crée automatiquement une `Application` par sous-dossier trouvé. Ajouter un futur service ne demande qu'un nouveau dossier `helm/<service>/` — aucun fichier `Application` supplémentaire à écrire manuellement.

L'`Application` pilote `catalog-api` (créée manuellement pour valider le concept) a été supprimée avant application de l'`ApplicationSet`, pour éviter tout conflit de nom avec celle générée automatiquement.

---

## Résultat final

```bash
kubectl get applications -n argocd
```
```
NAME                SYNC STATUS   HEALTH STATUS
basket-api          Synced        Healthy
catalog-api         Synced        Healthy
identity-api        Synced        Healthy
order-processor     Synced        Healthy
ordering-api        Synced        Healthy
payment-processor   Synced        Healthy
postgres            Synced        Healthy
rabbitmq            Synced        Healthy
redis               Synced        Healthy
webapp              Synced        Healthy
webhook-client      Synced        Healthy
webhooks-api        Synced        Healthy
```

**12/12 composants**, tous `Synced` et `Healthy`, générés depuis un seul fichier `ApplicationSet` de 25 lignes.

---

## Piliers consolidés

| Concept | Application |
|---|---|
| **GitOps — Git comme unique source de vérité** | Toute modification de la stack passe désormais par un commit/push, plus jamais par un `kubectl`/`helm` manuel sur le cluster de référence. |
| **`selfHeal` = Configuration Drift automatiquement corrigé** | Concept défini en théorie dès la Phase 1 (Vagrant), désormais appliqué de façon opérationnelle et automatique à l'échelle du cluster entier. |
| **Générateur de répertoires comme équivalent GitOps de la `matrix` CI** | Même principe transversal : une définition, N instances générées, maintenance centralisée — appliqué une seconde fois dans ce parcours, cette fois côté déploiement plutôt que build. |
| **Diagnostic d'échec partiel dans une installation complexe** | Un `kubectl apply` sur un manifest volumineux peut échouer partiellement sans que le résultat global semble en erreur — lire la sortie complète, pas uniquement sa conclusion apparente. |
| **`--server-side` comme solution aux limites de `kubectl apply` classique** | Connaissance pratique directement issue d'un vrai bug rencontré — utile pour tout futur CRD volumineux. |

---

## 🏆 Bilan de l'ensemble du parcours DevOps

| Phase | Réalisation |
|---|---|
| **Infrastructure** | VM Vagrant provisionnée, K3s installé et configuré |
| **Conteneurisation** | 9 Dockerfiles multi-stage, `docker-compose.yml` complet, registre Docker local |
| **Migration K8s** | 12 composants traduits de Compose vers Kubernetes (StatefulSet, Deployment, Service, Secret, ConfigMap) |
| **CI** | Pipeline GitHub Actions avec `matrix`, publication automatique vers GHCR |
| **Packaging** | 12 charts Helm, templating complet, résolution structurelle du problème `${VAR}` |
| **GitOps** | ArgoCD + `ApplicationSet`, synchronisation et auto-correction automatiques |

Chaque étape a été traitée avec la même discipline : diagnostic de cause racine avant correction, vérification systématique avant application réelle, documentation de chaque dette technique assumée plutôt que silencieuse.

---

*Document — Méthode Josue, Mentor DevOps Senior.*
