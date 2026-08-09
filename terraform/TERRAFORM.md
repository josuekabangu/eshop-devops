# Terraform — Premier pilote (S3)

Introduction à l'Infrastructure as Code — Phase 2.

---

## 🎯 Contexte

Première étape de la Phase 2 de la roadmap (Infra & Observabilité). Objectif : valider le cycle complet Terraform (`init`/`plan`/`apply`/`destroy`) sur une ressource simple et gratuite avant d'aborder des ressources réseau/serveur plus engageantes.

---

## 🎓 Terraform — les fondamentaux

### Définition

Terraform est un outil d'**Infrastructure as Code (IaC)** : l'infrastructure (serveurs, réseaux, bases de données...) est décrite dans des fichiers texte déclaratifs, et Terraform crée/modifie/détruit les ressources cloud réelles pour faire correspondre la réalité à cette description.

### Le problème résolu

Sans IaC, le provisionnement se fait à la main (console web — lent, non reproductible, non versionnable) ou via des scripts impératifs (CLI — décrit des étapes, pas un état final, aucune détection de dérive).

**Parallèle direct avec l'expérience déjà acquise sur ce projet :** le même écart qu'entre `kubectl apply` (impératif) et Helm + `values.yaml` (déclaratif) — Terraform applique cette philosophie à l'échelle du cloud lui-même, pas seulement à Kubernetes.

### Les 4 concepts fondamentaux

| Concept | Définition | Équivalent déjà connu |
|---|---|---|
| **Provider** | Plugin qui dialogue avec un cloud précis (`aws`, `azurerm`, `google`) | Un chart Helm parle à l'API K8s ; un provider Terraform parle à l'API AWS |
| **Resource** | Objet d'infrastructure déclaré (`aws_s3_bucket`, `aws_instance`) | Un objet K8s (`Deployment`, `Service`) |
| **State** (`terraform.tfstate`) | Trace de ce que Terraform a réellement créé | Le suivi qu'ArgoCD fait entre Git et le cluster, sauf que Terraform tient ce registre lui-même |
| **Plan / Apply** | `plan` prévisualise sans agir, `apply` exécute | `helm template` (plan) vs `helm install` (apply) |

### Cycle de vie

```
terraform init     → télécharge le provider
terraform plan      → calcule le diff entre état désiré (.tf) et état réel (state)
terraform apply     → exécute ce diff
terraform destroy   → supprime toutes les ressources gérées
```

### Séparation des responsabilités Terraform / Kubernetes

| Terraform | Kubernetes / Helm |
|---|---|
| Infra **autour** du cluster (VPC, sous-réseaux, cluster managé) | Ce qui tourne **dans** le cluster (Pods, Services) |

---

## 📦 Structure du premier pilote

```
terraform/
├── main.tf
├── variables.tf
├── outputs.tf
└── .gitignore
```

### `main.tf`
```hcl
terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

resource "aws_s3_bucket" "pilot" {
  bucket = var.bucket_name

  tags = {
    Project     = "eshop-devops"
    ManagedBy   = "terraform"
    Environment = "learning"
  }
}
```

### `variables.tf`
```hcl
variable "aws_region" {
  description = "Région AWS cible"
  type        = string
  default     = "eu-north-1"
}

variable "bucket_name" {
  description = "Nom du bucket S3 pilote (doit être globalement unique)"
  type        = string
  default     = "eshop-devops-terraform-pilot-josuekabangu"
}
```

### `outputs.tf`
```hcl
output "bucket_name" {
  value = aws_s3_bucket.pilot.bucket
}

output "bucket_arn" {
  value = aws_s3_bucket.pilot.arn
}
```

### `.gitignore`
```gitignore
.terraform/
*.tfstate
*.tfstate.backup
.terraform.lock.hcl
```

⚠️ Le `.tfstate` peut contenir des données sensibles selon les ressources décrites — jamais commité dans Git, même en apprentissage local. Solution structurelle pour la suite : backend distant (S3 + verrouillage DynamoDB).

---

## 🏗️ Sécurisation du compte AWS — préalable

Avant tout travail Terraform :
- Compte AWS créé, MFA activé sur le compte **root**
- Alerte de budget configurée
- Utilisateur IAM dédié `terraform-admin` créé (permissions `AdministratorAccess`, sans accès console — usage API/CLI uniquement)
- Clés d'accès CLI générées pour cet utilisateur, jamais pour le root

**Principe non négociable :** le compte root n'est jamais utilisé pour le travail quotidien ni pour Terraform — un utilisateur IAM dédié, aux permissions adaptées à l'usage, est systématique.

---

## 🐛 Bugs rencontrés et corrigés — configuration des credentials

### Bug 1 — saisie corrompue via `aws configure` interactif

**Symptôme :**
```
eu-north-1gion name [None]: e
```
La saisie de la Secret Access Key (chaîne longue de 40 caractères) a été corrompue lors du copier-coller dans le terminal SSH, provoquant un mélange avec le champ suivant (région).

**Fix appliqué :** édition directe des fichiers `~/.aws/credentials` et `~/.aws/config` via `nano`, plus fiable que la saisie interactive pour de longues valeurs.

### Bug 2 — collage de la ligne CSV complète comme secret

**Symptôme :**
```
aws: [ERROR]: An error occurred (SignatureDoesNotMatch) when calling the GetCallerIdentity operation
```
Le fichier `~/.aws/credentials` contenait :
```
aws_secret_access_key = EXAMPLE_SECRET_KEY_REDACTED
```

**Root cause :** le fichier `.csv` téléchargé depuis AWS contient une ligne `Access key ID,Secret access key` — la ligne entière (les deux valeurs séparées par une virgule) a été copiée dans le champ censé ne contenir que la seconde valeur.

**Fix :** extraction de la seule valeur après la virgule comme véritable Secret Access Key.

**Principe illustré :** pour tout fichier de credentials structuré en colonnes (CSV ou équivalent), toujours copier la cellule/colonne précise voulue, jamais une ligne entière par réflexe — un bug similaire en nature (mauvaise portion de données copiée) à celui déjà rencontré avec un token GitHub collé en clair plusieurs sessions plus tôt, ici sans exposition de sécurité mais avec le même type d'erreur de manipulation.

---

## ✅ Validation du cycle complet

Séquence exécutée intégralement, de façon autonome :

```bash
terraform init      # téléchargement du provider AWS
terraform apply     # création du bucket
terraform output    # récupération des valeurs générées
aws s3 ls            # vérification côté AWS réel, pas seulement confiance au state Terraform
terraform state list # confirmation de ce que Terraform gère
terraform plan       # "No changes" — idempotence confirmée
terraform plan -destroy  # prévisualisation de la suppression avant action réelle
terraform destroy    # suppression confirmée (saisie "yes"), nettoyage complet
```

**Résultat :** cycle complet validé, bucket créé puis proprement détruit, aucune ressource résiduelle facturable.

**Bonne pratique appliquée spontanément :** `terraform plan -destroy` avant `terraform destroy` — reproduction du réflexe "prévisualiser avant d'agir" déjà acquis avec `helm template`/`helm lint` avant tout déploiement réel, appliqué ici sans consigne explicite.

---

## 🧠 Piliers consolidés

| Concept | Application |
|---|---|
| **Idempotence** | `terraform plan` répété sans modification retourne `No changes` — même principe que `kubectl apply` répété sans effet observé depuis la Phase 1. |
| **Rafraîchissement systématique de l'état** | `Refreshing state...` avant chaque commande — Terraform vérifie la réalité AWS avant de calculer un diff, esprit proche du `selfHeal` ArgoCD (détection de dérive), version "vérifier avant d'agir" plutôt que "corriger en continu". |
| **Vérification côté provider réel, pas seulement le state local** | `aws s3 ls` en complément de `terraform output` — ne jamais faire confiance uniquement à l'outil, vérifier la source de vérité externe, principe transversal à tout ce projet (Kubernetes, Helm, ArgoCD, maintenant Terraform). |
| **Erreur de manipulation de credentials structurés** | Toujours extraire la valeur précise d'un fichier CSV/structuré, jamais copier une ligne entière par réflexe. |

---

## Module `networking` — VPC, subnets publics, routage Internet

Premier module Terraform structuré du projet, suite au pilote S3. Adoption de l'organisation en **modules** dès cette étape — chaque brique d'infrastructure (réseau, serveurs, base de données) vit dans son propre dossier autonome et réutilisable.

### Modules Terraform — le concept

Un module est un ensemble de fichiers `.tf` regroupés dans un dossier, formant une unité **réutilisable et autonome** — équivalent direct d'un chart Helm : un dossier avec sa propre logique interne (`main.tf` ≈ `templates/`, `variables.tf` ≈ `values.yaml`, `outputs.tf` ≈ les valeurs exposées vers l'extérieur).

### Isolation de portée — piège rencontré et corrigé

Chaque module (y compris la **racine**, elle-même considérée comme le "module racine") a son propre espace de variables, totalement isolé. Une variable déclarée dans `networking/variables.tf` n'est **pas** automatiquement visible à la racine — elle doit être redéclarée à la racine et passée explicitement via le bloc `module { }`, exactement comme des paramètres de fonction dans n'importe quel langage.

**Bug rencontré :** `terraform/variables.tf` (racine) laissé vide après la création du module, provoquant :
```
Error: Reference to undeclared input variable
An input variable with the name "aws_region" has not been declared.
```
**Fix :** redéclaration des 4 variables nécessaires au niveau racine, en plus de leur déclaration dans `networking/variables.tf`.

### Structure

```
terraform/
├── main.tf              # racine — appelle le module networking
├── variables.tf          # racine — variables globales
├── outputs.tf            # racine — relaie les outputs du module
└── networking/
    ├── main.tf
    ├── variables.tf
    └── outputs.tf
```

### `networking/main.tf` — ressource par ressource

**`aws_vpc.main`** — le réseau global :
```hcl
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = { Name = "eshop-vpc", Project = "eshop-devops", ManagedBy = "terraform" }
}
```
`cidr_block` = plage totale d'adresses IP privées du VPC (`10.0.0.0/16` = 65 536 adresses — le "budget" réparti ensuite entre les subnets). `enable_dns_support`/`enable_dns_hostnames` : résolution DNS interne et noms d'hôte automatiques, nécessaires pour qu'une future instance EC2 soit joignable par nom.

**`aws_internet_gateway.main`** — la porte vers Internet :
```hcl
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "eshop-igw" }
}
```
`vpc_id = aws_vpc.main.id` fait comprendre à Terraform la dépendance (VPC créé en premier). ⚠️ Un Internet Gateway seul ne fait rien tant qu'il n'est pas référencé explicitement dans une route table — c'est la porte physique, pas encore le panneau indicateur.

**`aws_subnet.public`** — les sous-réseaux, générés en boucle :
```hcl
resource "aws_subnet" "public" {
  count                   = length(var.public_subnet_cidrs)
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = var.availability_zones[count.index]
  map_public_ip_on_launch = true
  tags = { Name = "eshop-public-${count.index + 1}" }
}
```
`count = length(...)` : Terraform crée autant d'instances que d'éléments dans la liste (2 CIDR → 2 subnets) — mécanisme de boucle équivalent au `{{ range }}` Helm rencontré sur le ConfigMap Postgres. `count.index` vaut `0` puis `1` à chaque itération, piochant respectivement `10.0.1.0/24` puis `10.0.2.0/24`, et `eu-north-1a` puis `eu-north-1b` — répartition sur 2 datacenters physiquement distincts. `map_public_ip_on_launch` : toute instance EC2 lancée ici reçoit automatiquement une IP publique.

**`aws_route_table.public`** — le plan de circulation :
```hcl
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
  tags = { Name = "eshop-public-rt" }
}
```
`0.0.0.0/0` = toutes les destinations possibles sur Internet. La règle se lit : *"pour atteindre n'importe quelle adresse, passe par cette Internet Gateway"* — c'est cette ligne précise qui rend un subnet "public" au sens fonctionnel, **pas une propriété intrinsèque du subnet lui-même**. (AWS ajoute automatiquement et implicitement la route pour le trafic interne au VPC, jamais déclarée explicitement.)

**`aws_route_table_association.public`** — le lien entre subnet et règles :
```hcl
resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}
```
Une association par subnet créé ; `aws_subnet.public[count.index].id` accède à l'instance précise générée par la boucle précédente ; la même route table pour les deux subnets. ⚠️ Un Subnet et une Route Table sont deux objets AWS indépendants par défaut — sans association explicite, un nouveau subnet utiliserait la route table par défaut du VPC (souvent restrictive) plutôt que celle définie ici.

### Variables

| Variable | Type | Défaut | Explication |
|---|---|---|---|
| `vpc_cidr` | `string` | `"10.0.0.0/16"` | Plage totale du VPC |
| `public_subnet_cidrs` | `list(string)` | `["10.0.1.0/24", "10.0.2.0/24"]` | Deux sous-plages disjointes, contenues dans le VPC parent sans se chevaucher |
| `availability_zones` | `list(string)` | `["eu-north-1a", "eu-north-1b"]` | Deux datacenters physiques distincts de la région Stockholm |
| `aws_region` (racine uniquement) | `string` | `"eu-north-1"` | Utilisée par `provider "aws"`, jamais consommée par le module `networking` |

### Outputs et appel du module

```hcl
# networking/outputs.tf
output "vpc_id" { value = aws_vpc.main.id }
output "public_subnet_ids" { value = aws_subnet.public[*].id }
```
⚠️ La notation `[*]` signifie "prends l'attribut `id` de **toutes** les instances de cette ressource bouclée, sous forme de liste" — différent de `[count.index]`, qui cible une instance précise en cours de création.

```hcl
# terraform/main.tf (racine) — appel du module
module "networking" {
  source = "./networking"
  vpc_cidr            = var.vpc_cidr
  public_subnet_cidrs = var.public_subnet_cidrs
  availability_zones  = var.availability_zones
}
```
Le bloc `module { source = "./networking" ... }` est la syntaxe qui rend le dossier `networking/` réellement exécutable — sans lui, ce ne serait qu'un dossier de fichiers `.tf` orphelins. Accès à un output de module via `module.<nom_du_module>.<nom_de_l_output>` (dans `terraform/outputs.tf` racine).

### Déploiement et validation

```bash
terraform plan   # 7 ressources prévues : VPC, IGW, 2 subnets, 1 route table, 2 associations
terraform apply  # confirmation "yes"
```
`Apply complete! Resources: 7 added, 0 changed, 0 destroyed` en une vingtaine de secondes.

**Validation croisée côté AWS réel :**
```bash
aws ec2 describe-vpcs --filters "Name=tag:Name,Values=eshop-vpc"
```
Confirme le VPC (`vpc-067f4d50456b055b6`), CIDR `10.0.0.0/16`, tags corrects — réflexe de vérification déjà appliqué spontanément sur le pilote S3.

### Piliers consolidés durant cette étape

| Concept | Application |
|---|---|
| **Modules = réutilisabilité et isolation** | Équivalent direct d'un chart Helm — structure, portée de variables, communication via outputs explicites. |
| **Boucle Terraform (`count` + indexation)** | Même principe transversal que `{{ range }}` Helm et la `matrix` GitHub Actions — une définition, N instances. |
| **La route table définit le caractère "public" d'un subnet, pas le subnet lui-même** | Distinction conceptuelle clé pour toute architecture réseau AWS future. |
| **Communication inter-modules via outputs** | Un module ne peut consommer ce qu'un autre expose que via des `outputs.tf` explicites — jamais d'accès implicite entre modules. |

---

## 🔜 Prochaine étape

Module `ec2` — première instance serveur, déployée dans le subnet public créé ici, consommant `vpc_id` et `public_subnet_ids` comme entrées. Module `rds` déjà scaffoldé (dossier vide) pour la base de données managée à suivre.

---

*Document — Méthode Josue, Mentor DevOps Senior.*
