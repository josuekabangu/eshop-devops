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

## Chart 3 — `rabbitmq` (`StatefulSet`, plus simple que `postgres`)

**Pourquoi ce service ensuite :** structurellement plus simple que `postgres` — pas de `ConfigMap` (aucun script d'init nécessaire), pas de boucle. Seule particularité : un `Service` exposant deux ports nommés (`amqp`, `management`).

```
helm/rabbitmq/
├── Chart.yaml
├── values.yaml
└── templates/
    ├── secret.yaml
    ├── service.yaml
    └── statefulset.yaml
```

~~Point de cohérence noté~~ (corrigé depuis) : `secret.yaml`/`service.yaml` utilisaient `name: rabbitmq`/`app: rabbitmq` en dur — templaté en `{{ .Release.Name }}` partout, cohérent avec `catalog-api`/`postgres`. `storage: 1Gi` également templaté en `{{ .Values.storage.size }}`.

### Bugs rencontrés et corrigés

**Bug 1 — Secret déclaré en `data` sans encodage réel**
Rendu `helm template` révélant `RABBITMQ_DEFAULT_USER: eshop_rabbit` en texte brut sous `data:`, malgré un commentaire suggérant un encodage base64 (`| base64`) jamais réalisé. Root cause : le champ `data:` d'un `Secret` Kubernetes **exige** des valeurs déjà encodées en base64 — contrainte de l'API K8s, pas de Helm. `{{ .Values.x }}` seul ne réalise aucun encodage automatique ; il fallait `stringData` (texte brut, encodage délégué à Kubernetes) ou le filtre Helm `| b64enc` explicite.
Fix retenu : bascule vers `stringData`, pour rester cohérent avec les charts `postgres`/`catalog-api` déjà écrits plutôt que mélanger deux styles dans le même projet.
Principe : un commentaire de code documentant une intention non réalisée est un TODO oublié à traiter comme un signal d'alarme — seule la relecture du rendu `helm template` est une vérité vérifiable.

**Bug 2 — `periodSeconds` référençant la mauvaise clé (le plus insidieux)**
`values.yaml` définissait `periodSeconds: 10` et `timeoutSeconds: 5`, mais le rendu affichait `periodSeconds: 5` — `timeoutSeconds` dupliqué par erreur de copier-coller à la place de `periodSeconds` dans le template.
Fix : correction de la référence vers `.periodSeconds`.
Principe : aucune erreur de `helm lint`/`helm template` — une référence à une clé **existante mais incorrecte** est syntaxiquement valide. Plus insidieux que le bug `{{ range }}` vide de `postgres` (zéro itération, absence totale de sortie) : ici la sortie est plausible mais fausse, seule une comparaison ligne à ligne avec `values.yaml` le révèle.

### Validation

```bash
kubectl delete -f k8s/rabbitmq/
helm install rabbitmq helm/rabbitmq/
```
`STATUS: deployed`, `rabbitmq-0` passe de `0/1` à `1/1 Running` en 18s (cohérent avec `initialDelaySeconds: 10` de la readiness probe).

**Persistance :** `kubectl get pvc` → `data-rabbitmq-0 Bound ... AGE: 7d1h` — volume original conservé.

**Validation applicative — la preuve la plus solide de cette étape :** dans les logs de démarrage, `user 'eshop_rabbit' authenticated and granted access to vhost '/'` répété **8 fois** — chacun des services applicatifs consommateurs (`catalog-api`, `ordering-api`, `basket-api`, etc.) s'est reconnecté avec succès via les identifiants du nouveau Secret généré par Helm. Une authentification échouée sur l'un de ces 8 services aurait immédiatement révélé un problème d'encodage persistant — c'est la confirmation la plus directe possible que le Bug 1 est réellement résolu.

---

## Chart 4 — `redis` (`StatefulSet`, dernier de la stack)

**Particularité propre à Redis :** le mot de passe s'injecte en **argument de ligne de commande** (`--requirepass`), pas seulement en variable d'environnement passive — deux mécanismes de substitution distincts coexistent dans le même fichier :

| Endroit | Syntaxe | Résolu par | Quand |
|---|---|---|---|
| `command:`/`args:` | `$(REDIS_PASSWORD)` | Kubernetes, nativement | Au démarrage du conteneur, à partir des `env:` |
| Probes (`exec.command`) | `sh -c "redis-cli -a \"$REDIS_PASSWORD\" ping"` | Le shell du conteneur | À chaque exécution de la probe |
| Tout le reste du template | `{{ .Values.x }}` | Helm | Au rendu, avant tout envoi à l'API |

Helm résout ses `{{ }}` en premier, produisant un YAML final qui contient encore `$(REDIS_PASSWORD)` **littéral** — cette syntaxe n'est volontairement pas touchée par Helm, elle attend sa résolution par Kubernetes au runtime.

```
helm/redis/
├── Chart.yaml
├── values.yaml
└── templates/
    ├── secret.yaml
    ├── service.yaml
    └── statefulset.yaml
```

### Point de vigilance 1 — risque de récidive du mismatch mot de passe Redis, évité avant déploiement

Première version de `values.yaml` : `redis.password: Changeme` (majuscule) — aurait divergé de `basket-api-secrets` (`password=changeme`, minuscule), reproduction quasi exacte du bug `NOAUTH` déjà diagnostiqué et corrigé lors de la migration K8s (Étape 6/8). Détecté **avant** déploiement par vérification proactive :
```bash
kubectl get secret basket-api-secrets -o jsonpath='{.data.ConnectionStrings__redis}' | base64 -d
```
Fix : alignement sur `changeme`.

**Principe le plus important de toute la conversion Helm :** convertir des composants vers des charts **séparés** ne supprime jamais la duplication de secrets entre eux — elle peut même en **introduire de nouvelles** au moment de la conversion, si la valeur n'est pas vérifiée contre ce que les consommateurs existants attendent réellement. Seul un chart unique ou un gestionnaire de secrets externe éliminerait structurellement ce risque.

### Point de vigilance 2 — champs de probe vides (3ᵉ variante d'échec de valeur manquante)

Rendu affichant `timeoutSeconds:` et `failureThreshold:` sans valeur — clés présentes dans `values.yaml` mais laissées vides, plutôt qu'absentes. Fix : valeurs complétées.

Trois variantes distinctes de valeur manquante rencontrées sur ce parcours Helm, chacune avec un comportement différent :

| Type d'absence | Comportement | Exemple |
|---|---|---|
| Clé totalement absente, accès direct | Erreur bruyante immédiate | `postgres` — `nil pointer` |
| Liste absente, utilisée dans `{{ range }}` | Échec silencieux, zéro itération | `postgres` — ConfigMap vide |
| Clé présente mais valeur vide | Rendu incomplet, invalide seulement à l'application réelle | `redis` — probe avec champs vides |

### Validation

```bash
kubectl delete -f k8s/redis/
helm install redis helm/redis/
```
`STATUS: deployed`, `redis-0` `1/1 Running`.

**Persistance :** `kubectl get pvc` → `data-redis-0` conservé, `AGE: 7d`.
```bash
kubectl logs redis-0
# RDB age 607992 seconds   (~7 jours — confirme le chargement des données préexistantes, pas un état neuf)
# Ready to accept connections tcp
```

**Vérification croisée — absence de régression d'authentification :**
```bash
kubectl logs -l app=basket-api --tail=20 | grep -i "noauth\|authenticationfailure"
# (vide)
```
Confirmation qu'aucun service consommateur n'a rencontré d'échec d'authentification suite à la bascule — la vigilance sur le mot de passe a porté ses fruits.

---

## Bilan — les 3 StatefulSets de la stack convertis en Helm

| Chart | Bugs rencontrés | Validation |
|---|---|---|
| `postgres` | `nil pointer` (accès direct), `range` silencieux (liste absente), `POSTGRES_USER` non templaté | Données préservées, 4 bases confirmées |
| `rabbitmq` | Secret non encodé (`data` sans `b64enc`), probe mal référencée (`periodSeconds`/`timeoutSeconds`) | 8 authentifications applicatives réussies |
| `redis` | Risque de mot de passe divergent (évité), probe avec champs vides | Données AOF/RDB préservées, aucune régression |

---

## Chart 5 — `identity-api` (`Deployment` + double Service)

Premier service applicatif converti après les 3 StatefulSets d'infrastructure — le chart le plus riche produit jusqu'ici : double exposition Service (interne + NodePort externe), un `ConfigMap` avec 5 URLs clients distinctes, et une dépendance de cohérence critique entre l'`IssuerUri` et le port NodePort (le bug historique du "double issuer", Phase 1 Docker Compose, dépendait justement de garder ces deux valeurs synchronisées).

```
helm/identity-api/
├── Chart.yaml
├── values.yaml
└── templates/
    ├── secret.yaml
    ├── configmap.yaml
    ├── deployment.yaml
    ├── service.yaml
    └── service-external.yaml
```

**Point structurel important :** `IdentityServer__IssuerUri` référence `{{ .Values.service.externalPort }}` — la **même** valeur utilisée pour générer le `Service` NodePort. Toute modification future de ce port se propage automatiquement aux deux endroits, éliminant par construction le risque de désynchronisation manuelle qui avait causé le bug du double issuer en Phase 1.

### Bugs rencontrés et corrigés

**Bug 1 — image doublement préfixée (`ghcr.io/ghcr.io/...`)**
Même classe que le bug repéré sur `catalog-api` ([[helm-repository-double-registry-prefix]]). Repéré avant application définitive par relecture systématique du rendu `helm template`. Point de vigilance additionnel : le champ `Image ID` affichait encore une trace du doublon (`...@sha256:...`) même après correction du champ `Image` — probablement une particularité de normalisation de containerd liée aux mirrors du registre local, sans impact fonctionnel tant que le champ `Image` (celui qui reflète la référence réellement demandée) est correct.

**Bug 2 — URL client avec port manquant, silencieux**
`clients.webhooksApi` vide au premier rendu → `WebhooksApiClient: "http://192.168.56.11:"` (port manquant). Même famille que le bug de probe vide sur `redis` : valeur présente en apparence, non renseignée — pas une clé totalement absente.
**Impact s'il n'avait pas été corrigé :** seul le flux OAuth impliquant `webhooks-api` aurait échoué silencieusement ; les 4 autres clients corrects n'auraient montré aucun symptôme — un test global sur l'issuer n'aurait pas révélé ce bug spécifique, seule une vérification explicite de **chaque** clé du ConfigMap le pouvait.
Vérification de la résolution, sur l'objet réellement déployé plutôt que sur le seul rendu `helm template` :
```bash
kubectl get configmap identity-api-config -o yaml | grep -A6 "WebhooksApiClient\|WebAppClient"
```

⚠️ Point mineur noté, non corrigé : `deployment.yaml` a `replicas: 1` en dur plutôt que `{{ .Values.replicaCount }}` — sans impact aujourd'hui (`values.yaml` vaut aussi `1`), mais un futur `helm upgrade` changeant `replicaCount` n'aurait aucun effet. Même classe que le `POSTGRES_USER` non templaté sur `postgres`.

### Validation

```bash
kubectl delete -f k8s/identity-api/
helm install identity-api helm/identity-api/
```
`STATUS: deployed`, `1/1 Running`.

**Validation externe — le vrai test de bout en bout :**
```bash
curl http://192.168.56.11:5223/.well-known/openid-configuration | grep issuer
# {"issuer":"http://192.168.56.11:5223", ...}
```
Issuer unique et cohérent, endpoints OAuth/OIDC complets — la conversion Helm préserve intégralement le comportement validé en Phase K8s.

---

## Charts 6 à 9 — `ordering-api`, `basket-api`, `webhooks-api`, `webhook-client`

Quatre services convertis consécutivement, **tous sans bug de configuration** — confirmation que la méthode de conversion K8s → Helm (établie sur `catalog-api`, affinée sur les StatefulSets et `identity-api`) est désormais pleinement maîtrisée.

### `ordering-api`

Dépendances : Postgres (`orderingdb`) + RabbitMQ + Identity (interne, `http://identity-api:8080`). `identity.url` en valeur en dur, pas construite depuis un `externalHost` — cohérent avec la distinction interne/externe déjà établie : ce service ne parle qu'en interne au cluster. Deployment/Service identiques au pattern `catalog-api`.

Résultat : `1/1 Running` en moins de 2 min, **aucun bug**, migrations EF + connexion RabbitMQ confirmées.

### `basket-api` — la vigilance proactive paie

Dépendances : Redis + RabbitMQ + Identity (interne). Communication gRPC, transparente pour la structure du chart (déjà établi en migration K8s brute).

**Avant toute création de fichier**, vérification proactive de la valeur réelle du mot de passe Redis :
```bash
kubectl get secret redis-secret -o jsonpath='{.data.REDIS_PASSWORD}' | base64 -d
# changeme
```
`values.yaml` aligné immédiatement sur cette valeur exacte — réflexe directement issu du bug `NOAUTH` déjà payé lors de la migration K8s brute et re-payé lors de la conversion du chart `redis`.

Résultat : `1/1 Running` en 13s, **zéro `NOAUTH`** confirmé par grep explicite post-déploiement.

### `webhooks-api`

Pattern strictement analogue à `ordering-api` (Postgres `webhooksdb` + RabbitMQ + Identity interne) — seule la base de données et le nom du service changent, aucune nouveauté structurelle.

Résultat : `1/1 Running` en 15s, **aucun bug**, rendu propre du premier coup.

### `webhook-client`

Aucune donnée sensible (uniquement des URLs) → `ConfigMap` seul, pas de `Secret`. Un seul `Service` NodePort — pas de Service interne, rien d'autre dans le cluster n'appelle ce composant browser-facing.

**Point structurel** : `CallBackUrl` référence `{{ .Values.service.externalPort }}`, la même valeur que le `Service` NodePort — même principe de synchronisation par valeur unique déjà appliqué sur `identity-api` (`IssuerUri` ↔ NodePort), désormais un motif réutilisable établi.

Résultat : `1/1 Running` en 14s. Validation externe :
```bash
curl -s -o /dev/null -w "%{http_code}\n" http://192.168.56.11:5114
# 200
```

### Bilan de ces quatre conversions

| Service | Dépendances | Bugs | Temps de stabilisation |
|---|---|---|---|
| `ordering-api` | Postgres, RabbitMQ, Identity | 0 | < 2 min |
| `basket-api` | Redis, RabbitMQ, Identity | 0 (vigilance proactive) | 13s |
| `webhooks-api` | Postgres, RabbitMQ, Identity | 0 | 15s |
| `webhook-client` | Identity, aucune donnée sensible | 0 | 14s |

**Comportement transitoire observé sur les quatre :** chaque ancien Pod (géré par `kubectl` brut) est passé par un état `Completed` transitoire lors de la bascule vers Helm — fin de vie normale d'un `Deployment` supprimé, sans conséquence.

---

## Charts 10 à 12 — `order-processor`, `payment-processor` & `webapp` (achèvement complet)

Trois derniers composants convertis, complétant l'intégralité de la stack eShop (12 composants) en charts Helm indépendants.

### `order-processor` & `payment-processor` — choix de conception assumé : Secret dédié plutôt que partagé

Contrairement au manifest K8s brut (où `order-processor` réutilisait littéralement `ordering-api-secrets`), chaque chart Helm possède **son propre Secret**. Décision cohérente avec le choix initial "un chart par service" : chaque chart doit rester **installable de façon autonome**, sans dépendre qu'un autre chart ait préalablement créé un objet partagé.

Templates Secret et Deployment identiques dans leur structure aux workers précédents — pas de `ports:`, pas de `Service`, pas de probes, cohérent avec l'absence de trafic entrant à recevoir. Incohérence de casse conservée par fidélité : `ConnectionStrings__EventBus` (majuscules) sur `payment-processor`, différent de `ConnectionStrings__eventbus` ailleurs — sans impact fonctionnel, documenté depuis l'étape K8s brute, non "corrigé" arbitrairement.

Résultat : les deux workers passent en `1/1 Running` en 2-3 secondes, connexions RabbitMQ/Postgres confirmées dans les logs. **Aucun bug.**

### `webapp` — dernier composant, le plus richement connecté

Dépendances : RabbitMQ (Secret) + Identity (externe, navigateur) + Catalog/Ordering/Basket (internes, ConfigMap) — le service orchestrant le plus de connexions simultanées de toute la stack.

Séparation interne/externe appliquée cohéremment une nouvelle fois : `IdentityUrl`/`CallBackUrl` résolues côté navigateur, `services__*__http__0` résolues côté serveur — pattern confirmé sur cinq services distincts au cours de cette migration Helm complète. Deux `Service` (interne + NodePort externe), structure identique à `identity-api`.

Résultat : `1/1 Running` en 15 secondes. Validation externe :
```bash
curl -s -o /dev/null -w "%{http_code}\n" http://192.168.56.11:5100
# 200
```
**Aucun bug.**

---

## 🏆 Bilan complet — les 12 composants d'eShop convertis en Helm

| Composant | Type Helm | Bugs rencontrés | Étape doc |
|---|---|---|---|
| `postgres` | StatefulSet | 2 (accès direct nil, boucle silencieuse) | 1 |
| `rabbitmq` | StatefulSet | 2 (Secret non encodé, probe mal référencée) | 2 |
| `redis` | StatefulSet | 1 vigilance + 1 bug (probe vide) | 3 |
| `catalog-api` | Deployment | 0 | Pilote |
| `identity-api` | Deployment + 2 Services | 2 (image doublée, port manquant) | 4 |
| `ordering-api` | Deployment | 0 | 5 |
| `basket-api` | Deployment | 0 (vigilance proactive) | 5 |
| `webhooks-api` | Deployment | 0 | 5 |
| `webhook-client` | Deployment + Service | 0 | 5 |
| `order-processor` | Deployment sans Service | 0 | 6 |
| `payment-processor` | Deployment sans Service | 0 | 6 |
| `webapp` | Deployment + 2 Services | 0 | 6 |

**12/12 composants**, `kubectl apply -f k8s/*` intégralement remplacé par `helm install`/`helm upgrade` pour chacun.

**Progression de la maîtrise méthodologique visible dans les chiffres :** les deux premiers services convertis (`postgres`, `identity-api`, hors le pilote `catalog-api`) ont chacun révélé 2 bugs distincts ; les sept services suivants ont tous été déployés sans aucun bug — confirmation directe que la discipline de vérification systématique (`helm lint` → `helm template` → relecture ligne par ligne → déploiement) s'est intégrée comme réflexe plutôt que comme contrainte externe.

---

## Progression

| Chart | Statut |
|-------|--------|
| **Les 12 composants d'eShop** | ✅ Tous convertis en charts Helm indépendants |

---

## Suite

Avec la CI (GitHub Actions + GHCR) et Helm désormais tous deux en place, la suite logique est **ArgoCD** — synchronisation GitOps automatique entre ce dépôt Git (contenant maintenant les 12 charts) et l'état réel du cluster K3s, remplaçant les `helm install`/`upgrade` manuels par une réconciliation continue.
