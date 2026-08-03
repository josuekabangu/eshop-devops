# Kubernetes → Helm

Conversion progressive des manifests K8s bruts en charts Helm, un service à la fois — pour résoudre structurellement deux dettes tracées durant la migration K8s : l'absence de templating natif (`${VAR}` jamais substitué par `kubectl apply`) et la duplication de secrets entre objets (cause du bug Redis diagnostiqué sur `basket-api`).

---

## Décision d'architecture — un chart par service

Un chart Helm par service, plutôt qu'un chart unique pour toute la stack — choisi pour explorer la mécanique Helm service par service avant de généraliser. Trade-off assumé : cette approche ne supprime pas la duplication de valeurs *entre* charts (le mot de passe Postgres existe dans `helm/postgres/values.yaml` **et** dans `helm/catalog-api/values.yaml`) — seul un chart unique ou un gestionnaire de secrets externe l'éliminerait totalement.

Contrairement à la migration Compose → K8s (ordre contraint par des dépendances runtime réelles), la conversion en chart Helm est un exercice de **packaging** : chaque chart est indépendant, un service continue de tourner via ses manifests bruts pendant qu'un autre est converti, sans interruption.

---

## Correspondance manifest brut → chart Helm

| Manifest K8s brut | Devient en Helm | Rôle |
|---|---|---|
| Valeurs en dur (`postgres`, `Changeme`, `8080`) | Entrées `values.yaml` | Source unique de configuration |
| `metadata.name: catalog-api` répété | `{{ .Release.Name }}` | Nom dynamique, lié à la release |
| Fichiers `.yaml` statiques | Fichiers `templates/*.yaml` avec `{{ }}` | Templating réellement exécuté par Helm avant envoi à l'API |
| `kubectl apply -f` | `helm install` / `helm upgrade` | Gestion de version, historique, rollback natif |

## Méthode générale de conversion K8s → Helm

1. **`helm create <service>`** — squelette de base, à nettoyer des exemples non utilisés (Ingress, HPA, ServiceAccount)
2. **Inventorier chaque valeur** des manifests existants, classer entre "va dans `values.yaml`" et "reste en dur car invariant"
3. **Transformer un manifest à la fois** en template, en remplaçant une valeur à la fois par `{{ .Values.xxx }}` — jamais tout d'un coup
4. **Vérifier à chaque étape** avec `helm lint` puis `helm template`, comparer visuellement au manifest d'origine avant de continuer
5. **Bascule contrôlée** : `kubectl delete -f k8s/<service>/` puis `helm install <service> ./helm/<service>` — ne jamais laisser cohabiter un objet géré par `kubectl apply` brut et un objet du même nom repris par Helm
6. **Généraliser au service suivant**, un par un, jamais tous en même temps

---

## Chart 1 — `catalog-api` (`Deployment` simple)

**Pourquoi ce service en premier :** structurellement plus simple qu'un `StatefulSet` avec `volumeClaimTemplates` — le cas simple avant le cas complexe.

```
helm/catalog-api/
├── Chart.yaml
├── values.yaml
└── templates/
    ├── secret.yaml
    ├── deployment.yaml
    └── service.yaml
```

### Bug — `image.repository` avec `ghcr.io` en double

`values.yaml` déclarait `repository: ghcr.io/ghcr.io/josuekabangu/catalog-api`. `deployment.yaml` construit `image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"` — Docker traite le premier segment (`ghcr.io`) comme le registre, ce qui donne un chemin d'image `ghcr.io/josuekabangu/catalog-api` **à l'intérieur** du registre `ghcr.io`, ne correspondant à aucun package réellement publié (le vrai chemin est `josuekabangu/catalog-api`). Corrigé en `repository: ghcr.io/josuekabangu/catalog-api`.

### Validation

```bash
kubectl delete -f k8s/catalog-api/
helm install catalog-api helm/catalog-api/
```

**Résolution du problème `${VAR}` confirmée :**
```bash
kubectl get secret catalog-api-secrets -o jsonpath='{.data.ConnectionStrings__catalogdb}' | base64 -d
# Host=postgres;Port=5432;Database=catalogdb;Username=postgres;Password=Changeme
```
Comparé à l'ancien comportement des manifests bruts (`Username=${POSTGRES_USER}` jamais résolu) — Helm a réellement exécuté `{{ .Values.postgres.username }}` avant d'envoyer le Secret à l'API.

**Bénéfice `helm upgrade` :** changement de `replicaCount: 1 → 2` dans `values.yaml` seul, suivi de `helm upgrade catalog-api helm/catalog-api/` → `REVISION: 2`, second Pod créé automatiquement, aucune modification de `deployment.yaml`.

Après correction du bug `ghcr.io` : `helm upgrade` → `REVISION: 3`, 2 Pods `catalog-api` `1/1 Running`, pull d'image réussi, migration EF confirmée déjà à jour sur `catalogdb` (même base que via les manifests bruts).

---

## Chart 2 — `postgres` (`StatefulSet`, première boucle Helm)

**Pourquoi ce service ensuite :** premier chart couvrant un `StatefulSet` avec `volumeClaimTemplates`, et premier usage d'une vraie boucle de templating (`{{ range }}`).

### Subtilité StatefulSet + Helm à connaître avant conversion

Les `PersistentVolumeClaim` créés via `volumeClaimTemplates` ne sont **jamais gérés directement par Helm** — créés dynamiquement par le contrôleur `StatefulSet` de Kubernetes lui-même. Conséquence :
- `helm uninstall` supprime le `StatefulSet`, le `Service`, le `Secret`, mais **jamais** le PVC ni son volume — protection volontaire de Kubernetes contre la perte accidentelle de données.
- Une réinstallation via `helm install` récupère automatiquement l'ancien volume (même nom de PVC généré), avec toutes les données déjà présentes.

```
helm/postgres/
├── Chart.yaml
├── values.yaml
└── templates/
    ├── secret.yaml
    ├── configmap.yaml
    ├── service.yaml
    └── statefulset.yaml
```

`values.yaml` introduit `databases:` comme **liste**, pas une valeur scalaire — nécessaire pour la boucle du ConfigMap :
```yaml
{{- range .Values.databases }}
create_db_if_not_exists {{ . }}
{{- end }}
```
Le `-` avant `}}` supprime les retours à la ligne parasites générés sans lui.

### Bugs rencontrés et corrigés

**Bug 1 — `nil pointer evaluating interface {}.user`**
```
[ERROR] templates/: template: postgres/templates/statefulset.yaml:40:55:
executing ... at <.Values.postgres.user>: nil pointer evaluating interface {}.user
```
Root cause : absence de la clé `postgres.user` dans `values.yaml` au premier `helm lint`. Fix : ajout de la structure `postgres: { user, password }`.
Principe : un accès direct `{{ .Values.x.y }}` sur une valeur manquante échoue **bruyamment** — `helm lint`/`helm template` refusent de produire un rendu invalide, contrairement à `kubectl apply` qui aurait pu laisser passer une variable non résolue silencieusement.

**Bug 2 — boucle `{{ range }}` silencieusement vide (le plus important de cette étape)**
`helm lint` et `helm template` réussissaient tous les deux **sans erreur**, mais le ConfigMap généré ne contenait aucune ligne `create_db_if_not_exists` — zéro itération. Root cause : la clé `values.yaml` s'appelait `database:` (singulier), le template référençait `.Values.databases` (pluriel) — un `s` manquant. Fix : renommage en `databases:`.
**Principe à généraliser :** contrairement à l'accès direct qui plante sur une valeur absente, un `{{ range }}` sur une clé manquante ou vide échoue **silencieusement**, sans erreur ni avertissement. `helm lint`/`helm template` sans erreur ne garantit donc pas un rendu fonctionnellement correct — seule une relecture du YAML généré permet de le détecter.

**Bug 3 — `POSTGRES_USER` non templaté (divergence silencieuse en puissance)**
`env: POSTGRES_USER: value: postgres` restait en dur, alors que les probes juste en dessous utilisaient déjà `{{ .Values.postgres.user }}`. Aucun impact aujourd'hui (les deux valent `postgres`), mais si `postgres.user` changeait un jour dans `values.yaml`, le conteneur et les probes divergeraient silencieusement — même classe de bug que le mismatch mot de passe Redis (Étape 6 K8s). Fix : templaté partout.

### Validation

```bash
kubectl delete -f k8s/postgres/
helm install postgres helm/postgres/
```
`STATUS: deployed`, `postgres-0` `1/1 Running`.

**Persistance des données à travers la bascule `kubectl` → `Helm` :**
```bash
kubectl get pvc
# data-postgres-0   Bound   pvc-c80593ee-...   10d
```
Le PVC affiche un âge de 10 jours — le volume original n'a jamais été recréé, malgré la suppression et réinstallation complète du `StatefulSet` via Helm.
```bash
kubectl logs postgres-0
# PostgreSQL Database directory appears to contain a database; Skipping initialization
```
Les 9 autres services applicatifs sont restés `Running` sans interruption pendant toute l'opération — le `Service` `postgres` gardant le même nom, la bascule a été transparente pour eux.

Après correction du Bug 3 : `helm upgrade postgres helm/postgres/` → `REVISION: 2`, `postgres-0` toujours `Running`, `Skipping initialization` confirmé à nouveau.

---

## Piliers consolidés

| Concept | Application |
|---|---|
| **Templating réel vs substitution absente** | `{{ .Values.x }}` est exécuté par le moteur Helm avant tout envoi à l'API — contrairement à `${VAR}` qui restait une chaîne morte avec `kubectl apply` brut. |
| **Changement incrémental et vérifiable** | `helm lint`/`helm template` avant tout `helm install` réel — même discipline de vérification qu'à chaque étape précédente du parcours K8s. |
| **Un seul gestionnaire d'orchestration par objet** | Ne jamais laisser `kubectl apply` et Helm gérer le même objet nommé — Helm garde un état interne (Secret de release) qui se désynchronise sinon. |
| **`helm upgrade`/`rollback` comme filet de sécurité** | Historique de révisions consultable et réversible, absent avec des `kubectl apply` bruts successifs. |
| **Persistance des PVC indépendante du cycle de vie Helm** | `volumeClaimTemplates` échappe à la gestion directe de Helm — comportement à connaître pour ne pas le confondre avec un bug. |
| **Deux modes d'échec différents en Helm** | Accès direct sur valeur manquante = erreur bruyante immédiate. Boucle `{{ range }}` sur valeur manquante = échec silencieux, zéro itération sans avertissement. |
| **Vérification du contenu généré, pas seulement de l'absence d'erreur** | La relecture du YAML produit par `helm template` reste indispensable, en particulier autour de toute logique conditionnelle ou de boucle. |
| **Transparence d'une bascule bien menée** | Les services consommateurs (via le `Service` DNS) n'ont subi aucune interruption — la migration d'un composant vers Helm n'affecte pas ses consommateurs tant que le contrat d'interface (nom du Service, port) reste stable. |

---

## Progression

| Chart | Statut |
|-------|--------|
| `catalog-api` (Deployment) | ✅ Validé |
| `postgres` (StatefulSet) | ✅ Validé |
| `rabbitmq`, `redis` (StatefulSet) | ❌ |
| Autres services applicatifs | ❌ |

---

## 🔜 Prochaine étape

Choix à faire entre poursuivre avec `rabbitmq`/`redis` (même famille StatefulSet, pattern déjà maîtrisé) ou passer à un service applicatif supplémentaire (`identity-api`, `ordering-api`...) pour diversifier la pratique sur des `Deployment` avec plus de dépendances (Secret + ConfigMap combinés).

---

*Document — Méthode Josue, Mentor DevOps Senior.*
