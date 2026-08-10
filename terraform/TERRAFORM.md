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
aws_secret_access_key = EXAMPLE_SECRET_KEY_DO_NOT_USE_REAL_VALUE_HERE
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

## Module `ec2` & subnets privés — première instance serveur, isolation réseau pour bases de données

Deuxième module Terraform, consommant les outputs du module `networking` — première démonstration concrète de la communication inter-modules. En parallèle, ajout de subnets privés au module `networking`, anticipant le futur module `rds`.

### Amazon EC2 — les fondamentaux

EC2 loue un serveur virtuel dans un datacenter AWS — l'équivalent cloud de la VM Vagrant utilisée depuis le début du parcours, mais hébergé chez AWS plutôt que localement.

| Concept | Définition | Équivalent déjà connu |
|---|---|---|
| **AMI** | Image de base du serveur (OS + logiciels préinstallés) | Une image Docker, mais pour une VM entière |
| **Instance Type** | Taille de la machine (CPU, RAM), ex: `t3.micro` | `resources.requests/limits` d'un Deployment K8s |
| **Security Group** | Pare-feu virtuel attaché à l'instance | Rôle qu'un `NetworkPolicy` jouerait en K8s |
| **Key Pair** | Paire de clés SSH pour authentification, jamais de mot de passe | Le SSH déjà utilisé pour se connecter à la VM Vagrant |

**Principe de sécurité — moindre privilège réseau :** l'accès SSH est restreint à l'IP publique personnelle uniquement (`${var.my_ip}/32`), jamais `0.0.0.0/0`. Cette IP (obtenue via `curl -s ifconfig.me`) peut être dynamique — un `terraform apply -var="my_ip=..."` avec la nouvelle valeur est nécessaire si elle change entre deux sessions. `my_ip` n'a volontairement **aucune valeur par défaut** dans `variables.tf` — force une saisie explicite à chaque déploiement, évitant qu'une valeur ouverte soit laissée par erreur.

### Génération de la clé SSH dédiée

```bash
ssh-keygen -t ed25519 -f ~/.ssh/eshop-aws-key -C "eshop-terraform"
```
Clé dédiée à ce contexte AWS, distincte de toute clé Vagrant existante — séparation des identifiants par contexte.

### `ec2/main.tf` — points techniques clés

```hcl
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
}
```
`data "aws_ami"` (pas une `resource`) : Terraform **interroge** AWS pour trouver une AMI existante plutôt que d'en créer une. `most_recent = true` + `owners` (ID officiel Canonical) évitent de coder un ID d'AMI en dur, qui deviendrait obsolète à chaque nouvelle version d'Ubuntu.

```hcl
resource "aws_security_group" "instance" {
  ingress {
    description = "SSH depuis mon IP uniquement"
    cidr_blocks = ["${var.my_ip}/32"]
    # ...
  }
  ingress {
    description = "HTTP ouvert (pour tester un futur serveur web)"
    cidr_blocks = ["0.0.0.0/0"]
    # ...
  }
  egress {
    description = "Tout le trafic sortant autorise"
    cidr_blocks = ["0.0.0.0/0"]
    # ...
  }
}
```
`cidr_blocks = ["${var.my_ip}/32"]` — le `/32` signifie "exactement cette seule adresse IP".

### Communication inter-modules — intégration racine

```hcl
# terraform/main.tf
module "ec2" {
  source = "./ec2"

  vpc_id        = module.networking.vpc_id
  subnet_id     = module.networking.public_subnet_ids[0]
  my_ip         = var.my_ip
  instance_type = var.instance_type
}
```
Le module `ec2` consomme directement `module.networking.vpc_id` et `module.networking.public_subnet_ids[0]` — aucune duplication de valeur, bénéfice concret de l'architecture modulaire.

### Bug rencontré et corrigé — description de règle Security Group avec accent

**Symptôme :**
```
Error: "egress.0.description" doesn't comply with restrictions
("^[0-9A-Za-z_ .:/()#,@\\[\\]+=&;{}!$*-]*$"): "Tout le trafic sortant autorisé"
```

**Root cause :** le champ `description` **à l'intérieur** de chaque règle `ingress`/`egress` d'un Security Group est soumis par l'API AWS elle-même à une regex stricte n'acceptant aucun caractère accentué. Le "é" de "autorisé" provoquait le rejet.

**Point de nuance observé :** la description **globale** du Security Group (`aws_security_group.description`, ex: `"SSH restreint + HTTP ouvert"`) n'est, elle, soumise à aucune contrainte de ce type — l'apply a réussi malgré l'accent conservé sur ce champ précis. La contrainte ne s'applique qu'aux descriptions de règles individuelles.

**Fix réellement appliqué :** les accents ont été retirés des descriptions de règles (`"autorise"`, sans é) — les descriptions sont restées en **français**, contrairement à une réécriture complète en anglais initialement envisagée. Le seul point bloquant pour l'API AWS était le caractère accentué, pas la langue elle-même.

---

## Subnets privés — deuxième couche de défense réseau, anticipant `rds`

### Root cause de l'ajout

Lacune de conception initiale : le module `networking` n'avait été pensé que pour le besoin immédiat (`ec2`, public), sans anticiper le futur module `rds` qui nécessite une isolation réseau structurelle.

### Pourquoi une base de données exige un subnet privé

| | Subnet public | Subnet privé |
|---|---|---|
| Accessible depuis Internet | Oui (filtré par Security Group) | Jamais, quelle que soit la configuration du Security Group |
| Protection | Une seule couche (pare-feu applicatif) | Deux couches : pare-feu + absence structurelle de route Internet |

Le subnet privé constitue une seconde couche de défense — même en cas d'erreur de configuration du Security Group, l'absence de route vers `0.0.0.0/0` rend la ressource structurellement inatteignable depuis l'extérieur.

**Absence de NAT Gateway, volontaire et sans impact :** un NAT Gateway (payant) serait nécessaire pour un accès Internet *sortant* depuis un subnet privé — non requis ici, car RDS gère ses propres mises à jour de moteur de base de données en interne, sans besoin de sortie Internet.

### Implémentation

```hcl
# networking/variables.tf
variable "private_subnet_cidrs" {
  description = "Private subnet CIDR ranges (for RDS)"
  type        = list(string)
  default     = ["10.0.11.0/24", "10.0.12.0/24"]
}
```

```hcl
# networking/main.tf
resource "aws_subnet" "private" {
  count             = length(var.private_subnet_cidrs)
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]
  tags = { Name = "eshop-private-${count.index + 1}" }
}
```

Différences délibérées avec `aws_subnet.public` : absence de `map_public_ip_on_launch`, et surtout **absence de `aws_route_table_association`** — sans association explicite, ce subnet utilise la route table par défaut du VPC, qui ne contient que la route interne implicite, jamais de route vers Internet.

### Bug de nommage rencontré et corrigé

**Symptôme :** l'output était initialement déclaré `private_subnet_cidrs` alors qu'il exposait `aws_subnet.private[*].id` — des identifiants de subnet, pas des plages CIDR. Le contenu réel (`subnet-05cb072419adf1b4e`, ...) ne correspondait pas au nom donné.

**Fix :** renommage en `private_subnet_ids`, cohérent avec `public_subnet_ids` déjà correctement nommé.

**Principe illustré :** la cohérence de nommage entre ce qu'une variable/output *dit* contenir et ce qu'elle contient *réellement* est aussi critique en Terraform qu'elle l'était pour les noms de Secrets/ConfigMaps Kubernetes tout au long du parcours — une confusion de nommage coûte du temps de diagnostic à quiconque relit le code plus tard.

---

## Déploiement et validation

```bash
terraform plan -var="my_ip=$(curl -s ifconfig.me)"
terraform apply -var="my_ip=$(curl -s ifconfig.me)"
```
Résultat : `3 added` (instance, key pair, security group), confirmation exacte de la règle SSH avec l'IP réelle (`176.169.116.100/32`).

**Validation par connexion SSH réelle :**
```bash
ssh -i ~/.ssh/eshop-aws-key ubuntu@16.16.67.108
```
Connexion réussie, IP privée interne confirmée (`10.0.1.55`, cohérente avec le premier subnet public `10.0.1.0/24`) — preuve fonctionnelle complète, pas seulement une validation de plan.

### Piliers consolidés durant cette étape

| Concept | Application |
|---|---|
| **Communication inter-modules par outputs** | `ec2` consomme `vpc_id` et `public_subnet_ids` de `networking` sans aucune duplication de valeur. |
| **Défense en profondeur réseau** | Security Group (couche applicative) + absence de route Internet en subnet privé (couche structurelle) — deux mécanismes indépendants. |
| **Concevoir pour l'architecture cible complète** | Correction proactive d'une lacune de conception initiale, avant qu'elle ne bloque le futur module `rds`. |
| **Cohérence de nommage variable/output vs contenu réel** | Un output mal nommé (`_cidrs` contenant des `_ids`) reste fonctionnel mais trompeur — corrigé par principe, pas seulement par nécessité technique. |
| **Contraintes de validation spécifiques à certains champs AWS** | La regex restrictive sur les descriptions de règles Security Group (mais pas sur la description globale) illustre que les contraintes AWS peuvent être granulaires et inattendues — toujours lire le message d'erreur complet plutôt que de supposer. |

---

## Module `rds` — base de données managée, isolée en subnet privé

Troisième et dernier module de cette branche Terraform. Consomme les subnets privés (ajoutés proactivement au module `networking`) et le Security Group de l'EC2 (référencé directement, sans passer par une IP) — démonstration complète de la communication inter-modules et de la défense en profondeur réseau.

### Amazon RDS — les fondamentaux

RDS est une base de données **managée** : AWS gère l'installation, les patchs de sécurité, les sauvegardes automatiques et la haute disponibilité — contrairement au `postgres-0` StatefulSet K3s du projet, entièrement auto-géré.

| | StatefulSet Postgres (K3s) | RDS |
|---|---|---|
| Patch de sécurité du moteur | Manuel (rebuild image, redéploiement) | Automatique (fenêtre de maintenance AWS) |
| Sauvegardes | Aucune stratégie en place | Snapshots automatiques quotidiens |
| Scalabilité verticale | Modification manuelle du YAML | Changement de variable Terraform |
| Haute disponibilité | Aucune (1 seul Pod) | Option Multi-AZ disponible (non activée ici, hors Free Tier) |

**Concepts nouveaux :** `DB Subnet Group` (regroupement d'au moins 2 subnets d'AZ différentes où RDS peut placer l'instance — obligatoire même en single-AZ) ; `Multi-AZ` (réplique synchrone + bascule automatique, non activé ici).

**Choix Free Tier strict, validé avant implémentation :** `db.t3.micro`, single-AZ, 20 Go de stockage — Multi-AZ exclu volontairement car non couvert par le Free Tier (750h/mois, 12 premiers mois).

### `rds/variables.tf` — `sensitive = true`

```hcl
variable "db_password" {
  description = "RDS master password"
  type        = string
  sensitive   = true
}
```

Terraform masque automatiquement cette valeur dans tous les affichages (`plan`, `apply`, logs) — apparaît comme `(sensitive value)`. Ne chiffre pas le `.tfstate` (déjà exclu de Git), mais protège contre une exposition accidentelle en terminal partagé ou log CI. Aucune valeur par défaut — force une saisie explicite en ligne de commande, jamais stockée en clair dans un fichier versionné.

### `rds/main.tf` — points techniques clés

```hcl
resource "aws_security_group" "rds" {
  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [var.ec2_security_group_id]   # ← pas cidr_blocks
  }
}

resource "aws_db_instance" "main" {
  # ...
  publicly_accessible = false
  skip_final_snapshot = true
  multi_az             = false
}
```

| Attribut | Explication |
|---|---|
| `ingress.security_groups = [var.ec2_security_group_id]` | Référence **directement** le Security Group de l'EC2, pas une plage d'IP (`cidr_blocks`). Seules les ressources partageant ce Security Group précis peuvent atteindre le port 5432 — pattern standard pour la communication service-à-service intra-VPC, plus robuste qu'une IP qui pourrait changer. |
| `publicly_accessible = false` | Empêche toute IP publique sur l'instance RDS, même si le subnet le permettait — troisième couche de défense après le Security Group et l'isolation réseau du subnet privé lui-même. |
| `skip_final_snapshot = true` | Évite un snapshot final payant en stockage au moment de `terraform destroy` — acceptable en apprentissage, jamais en production. |

### Intégration racine — communication à trois modules

```hcl
module "rds" {
  source = "./rds"
  vpc_id                = module.networking.vpc_id
  private_subnet_ids    = module.networking.private_subnet_ids
  ec2_security_group_id = module.ec2.security_group_id
  db_password            = var.db_password
}
```

Le module `rds` consomme des outputs de **deux modules différents** (`networking` et `ec2`) — premier graphe de dépendances à plusieurs niveaux du projet. Prérequis ajouté à `ec2/outputs.tf` : `output "security_group_id" { value = aws_security_group.instance.id }`.

### Bugs rencontrés et corrigés

**Bug 1 — output mal placé, référence à une ressource hors de portée**
```
Error: Reference to undeclared resource
A managed resource "aws_security_group" "instance" has not been declared in the root module.
```
Root cause : un output `security_group_id` avait été ajouté à `terraform/outputs.tf` (racine), référençant `aws_security_group.instance` — une ressource qui n'existe que **dans** le module `ec2`, jamais directement accessible depuis la racine sans passer par `module.ec2.security_group_id`.
Fix : suppression du bloc erroné à la racine, remplacé par les véritables outputs attendus (`db_endpoint`, `db_name` du module `rds`).
Point méthodologique : la résolution a nécessité plusieurs itérations, une modification via `nano` n'ayant pas été effectivement sauvegardée à la première tentative — écrasement du fichier via un heredoc (`cat > fichier << 'EOF' ... EOF`) utilisé comme méthode plus fiable pour garantir l'écriture complète.
Principe : la portée des ressources en Terraform suit strictement les frontières de module — réaffirme le principe déjà rencontré sur `networking` ([[terraform-module-variable-scope-undeclared]] côté variables, ici côté ressources).

**Bug 2 — faute de frappe sur un nom de paquet**
```
E: Unable to locate package postgresql-clent
```
`postgresql-clent` au lieu de `postgresql-client` (lettres inversées) — correction orthographique simple, sans impact sur l'infrastructure.

### Déploiement et validation

```bash
terraform apply -var="my_ip=$(curl -s ifconfig.me)" -var="db_password=$DB_PASS"
```
`3 added` (DB subnet group, Security Group RDS, instance RDS), création en 4m55s — significativement plus long qu'EC2 ou le VPC, cohérent avec le provisionnement complet d'un moteur de base de données géré.

**Validation croisée — preuve fonctionnelle de l'isolation réseau, à double sens :**

Depuis l'EC2 (autorisé) :
```bash
ssh -i ~/.ssh/eshop-aws-key ubuntu@16.16.67.108
psql -h eshop-db.cjcak6acmxd9.eu-north-1.rds.amazonaws.com -U postgres -d eshopdb
# connexion réussie, \l confirme eshopdb
```

Depuis la VM Vagrant (non autorisée) :
```bash
timeout 5 bash -c "</dev/tcp/eshop-db.cjcak6acmxd9.eu-north-1.rds.amazonaws.com/5432" && echo "OUVERT" || echo "FERMÉ/TIMEOUT"
# FERMÉ/TIMEOUT
```

**Cette double preuve (succès depuis la source autorisée, échec depuis une source non autorisée) constitue la validation la plus rigoureuse possible d'une règle de sécurité réseau** — un test unique de succès n'aurait pas suffi à exclure une configuration trop permissive.

### Piliers consolidés durant cette étape

| Concept | Application |
|---|---|
| **Sécurité par référence de Security Group plutôt que par IP** | `security_groups = [var.ec2_security_group_id]` — approche robuste pour la communication intra-VPC, indépendante de toute IP changeante. |
| **Défense en profondeur, validée en pratique** | Security Group + subnet privé + `publicly_accessible = false` — trois couches indépendantes, dont l'efficacité combinée a été prouvée par un test d'échec délibéré, pas seulement par lecture du code. |
| **Communication inter-modules à plusieurs niveaux** | `rds` consomme simultanément des outputs de `networking` et `ec2` — premier graphe de dépendances à trois modules du projet. |
| **Validation par preuve négative** | Confirmer qu'un accès *refusé* échoue réellement est aussi important que confirmer qu'un accès *autorisé* réussit. |
| **Frontières strictes de portée entre modules** | Réaffirmé une seconde fois — aucune ressource n'est accessible hors de son module sans output explicite. |

---

## 🏆 Bilan de l'ensemble de la branche Terraform

| Module | Ressources | Rôle |
|---|---|---|
| `networking` | VPC, IGW, 4 subnets (2 publics, 2 privés), route table | Fondation réseau de toute l'infrastructure |
| `ec2` | Instance, Key Pair, Security Group | Premier serveur applicatif, accès SSH restreint |
| `rds` | Instance de base de données, DB Subnet Group, Security Group | Base de données managée, isolée en profondeur |

Infrastructure AWS complète provisionnée en Infrastructure as Code, avec architecture modulaire réutilisable, sécurité réseau vérifiée par preuve fonctionnelle (pas seulement déclarative), et documentation exhaustive de chaque bug rencontré.

---

## 🔜 Prochaine étape

Selon la roadmap Phase 2 : stack d'observabilité (métriques, logs, tracing), ou poursuite Terraform vers un backend distant S3 pour le state — dette technique déjà tracée depuis le pilote initial.

---

*Document — Méthode Josue, Mentor DevOps Senior.*
