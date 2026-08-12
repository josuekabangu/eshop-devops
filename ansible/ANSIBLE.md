# Ansible — Installation K3s sur EC2

Configuration management, complémentaire à Terraform.

---

## 🎯 Contexte

Introduction d'Ansible (Phase 2 de la roadmap), en remplacement du `user_data` Terraform utilisé initialement pour installer K3s sur l'instance EC2. Objectif : démontrer la différence fondamentale entre une exécution unique au boot et une configuration idempotente rejouable à volonté.

---

## 🎓 Ansible — les fondamentaux

### Répartition standard en entreprise : Terraform + Ansible

```
Terraform  →  crée le SERVEUR (existence, réseau, disque)
Ansible    →  configure ce qui tourne DESSUS (paquets, services, fichiers)
```

Cette séparation est la pratique standard : Terraform ne devrait gérer que l'**existence** des ressources, jamais leur configuration interne détaillée — exactement la même distinction déjà établie entre Terraform et Kubernetes/Helm, appliquée un cran plus bas (le serveur lui-même plutôt que ce qui tourne dans le cluster).

### Pourquoi `user_data` ne suffit pas

Le bloc `user_data` d'une instance EC2 s'exécute **une seule fois**, au tout premier démarrage. Limites concrètes :
- Ajouter une étape de configuration plus tard nécessite de **recréer** l'instance
- Aucune correction de dérive possible
- Pas de garantie de cohérence entre plusieurs serveurs

### Concepts clés

| Concept | Rôle | Équivalent déjà connu |
|---|---|---|
| **Playbook** | Fichier YAML décrivant une suite de tâches | Un chart Helm, mais pour configurer un serveur |
| **Inventory** | Liste des machines cibles | Le `values.yaml` qui dit "où" appliquer la config |
| **Module** | Action réutilisable (`apt`, `shell`, `wait_for`...) | Un `resource` Terraform, pour l'intérieur d'un serveur |
| **Idempotence** | Vérification de l'état avant action, rejouable sans effet de bord si rien n'a changé | Principe déjà rencontré depuis Vagrant, Helm, Terraform |

Ansible se connecte à distance en SSH — aucun agent à installer sur la machine cible, contrairement à des outils comme Puppet ou Chef.

---

## 📦 Structure du projet

```
ansible/
├── ansible.cfg
├── inventory.ini
└── k3s-install.yml
```

### `ansible.cfg`
```ini
[defaults]
host_key_checking = False
inventory = inventory.ini
private_key_file = ~/.ssh/eshop-aws-key
remote_user = ubuntu
```

### `inventory.ini`
```ini
[eshop_ec2]
13.60.68.91
```

### `k3s-install.yml`
```yaml
---
- name: Install and configure K3s on eShop EC2
  hosts: eshop_ec2
  become: true
  tasks:
    - name: Update apt cache
      apt:
        update_cache: yes

    - name: Install K3s
      shell: curl -sfL https://get.k3s.io | sh -
      args:
        creates: /usr/local/bin/k3s

    - name: Wait for K3s config file to exist
      wait_for:
        path: /etc/rancher/k3s/k3s.yaml
        timeout: 60

    - name: Confirm K3s node is ready
      shell: k3s kubectl get nodes
      register: k3s_status
      changed_when: false

    - name: Display K3s status
      debug:
        var: k3s_status.stdout_lines
```

**Point technique clé — `creates: /usr/local/bin/k3s`** : ce paramètre rend la tâche `Install K3s` idempotente. Ansible vérifie l'existence de ce fichier avant d'exécuter le script — s'il existe déjà, la tâche est marquée `ok` sans réexécution, exactement le même esprit que les `if ! command -v docker` du Vagrantfile en tout début de parcours.

---

## 🐛 Bugs rencontrés et corrigés

### Bug 1 — `ansible.cfg` systématiquement ignoré

**Symptôme :**
```
[WARNING]: Ansible is being run in a world writable directory
(/home/vagrant/EshopOnContainer/ansible), ignoring it as an ansible.cfg source.
[WARNING]: No inventory was parsed, only implicit localhost is available
```

**Root cause :** le dossier `~/EshopOnContainer/ansible` réside sur un montage partagé Vagrant (`vboxsf`), avec des permissions `drwxrwxrwx` (world-writable) confirmées par `ls -ld`. Ansible refuse par sécurité de faire confiance à un fichier `ansible.cfg` situé dans un dossier modifiable par n'importe quel utilisateur du système — mesure de protection contre l'injection de configuration malveillante.

**Fix :** passage explicite de tous les paramètres en ligne de commande, contournant le besoin de fiabilité de `ansible.cfg` :
```bash
ANSIBLE_HOST_KEY_CHECKING=False ansible-playbook -i inventory.ini k3s-install.yml \
  --user ubuntu \
  --private-key ~/.ssh/eshop-aws-key
```

**Principe illustré :** Ansible applique un principe de sécurité par conception — même un simple fichier de configuration local peut être un vecteur d'attaque si son dossier de résidence est trop permissif. Comportement volontaire, pas un défaut de l'outil. En vraie production, un projet Ansible ne résiderait jamais sur un tel montage partagé aux permissions larges.

### Bug 2 — mauvais utilisateur de connexion (conséquence du Bug 1)

**Symptôme :**
```
fatal: [13.60.68.91]: UNREACHABLE! =>
{"msg": "... vagrant@13.60.68.91: Permission denied (publickey)."}
```

**Root cause :** `remote_user = ubuntu` défini dans `ansible.cfg` (ignoré) — Ansible retombait sur l'utilisateur système par défaut (`vagrant`), inexistant sur l'instance EC2 cible (utilisateur `ubuntu` pour une AMI Ubuntu).

**Fix :** ajout explicite de `--user ubuntu`, résolu simultanément au Bug 1.

---

## ✅ Validation de l'idempotence — le test décisif

**Premier run**, sur une instance EC2 fraîchement recréée (sans K3s préinstallé) :
```
TASK [Install K3s] ***
changed: [13.60.68.91]
```
Tâche exécutée pour la première fois, résultat attendu.

**Second run**, playbook relancé à l'identique :
```
TASK [Install K3s] ***
ok: [13.60.68.91]
```
Tâche non réexécutée — `/usr/local/bin/k3s` déjà présent, `creates:` a empêché toute action redondante.

**Cette paire de résultats (`changed` puis `ok`) constitue la preuve la plus directe possible de l'idempotence** — contrairement à `user_data`, qui n'aurait jamais pu être "rejoué" de cette façon sans recréer entièrement l'instance.

**Détail secondaire observé :** la tâche `Update apt cache` reste systématiquement `changed` à chaque exécution — comportement normal, `apt update` télécharge de nouvelles métadonnées de paquets à chaque appel, sans mécanisme de détection d'absence de changement équivalent à `creates:`.

---

## ⚠️ Incident de sécurité traité durant cette branche de travail

En parallèle de la mise en place de Terraform, une clé d'accès AWS (`terraform-admin`) a été collée par erreur dans la documentation, puis retrouvée committée dans l'historique Git (fichier `terraform/TERRAFORM.md`). AWS a automatiquement détecté l'exposition et placé la clé en quarantaine (`AWSCompromisedKeyQuarantineV3`), bloquant les opérations `RunInstances` malgré des permissions `AdministratorAccess` — un deny explicite l'emportant toujours sur un allow dans le moteur d'évaluation IAM.

**Actions correctives appliquées :**
1. Suppression complète de la clé compromise sur la console AWS IAM, génération d'une nouvelle paire
2. Nettoyage de l'état actuel du repo (remplacement de la valeur réelle par un exemple factice dans la documentation)
3. Réécriture complète de l'historique Git via `git filter-repo --replace-text`, suivie d'un `git push --force`
4. Nettoyage additionnel d'un dossier de binaires (`aws/dist/...`, l'installeur AWS CLI) committé par erreur dans le même commit

**Conséquence indirecte observée :** après résolution de l'incident, le compte AWS s'est retrouvé temporairement restreint aux types d'instance éligibles au Free Tier strict (`t3.micro`, `t3.small`, `t4g.micro`/`small`, entre autres) — `t3.medium` initialement prévu pour l'instance K3s a dû être ajusté en `t3.small`, mesure de protection probable consécutive à la détection de compromission.

**Principe consolidé :** toute clé/secret exposé dans un canal non éphémère doit être traité comme définitivement compromis, indépendamment de sa visibilité publique effective — la détection automatique par AWS confirme empiriquement ce principe déjà appliqué depuis un incident similaire (token GitHub collé en clair, plusieurs sessions plus tôt dans ce parcours).

---

## 🧠 Piliers consolidés

| Concept | Application |
|---|---|
| **Ansible complète Terraform, ne le remplace pas** | Séparation nette : Terraform pour l'existence des ressources, Ansible pour leur configuration interne — deux responsabilités distinctes. |
| **Sécurité par conception dans les dossiers partagés** | Ansible refuse un `ansible.cfg` dans un dossier world-writable — comportement volontaire à respecter, pas un obstacle à contourner sans réflexion. |
| **Preuve d'idempotence par comparaison de deux exécutions** | `changed` puis `ok` sur deux runs successifs constitue la démonstration la plus rigoureuse — un seul run ne suffit jamais à prouver l'idempotence. |
| **Traitement systématique de toute exposition de secret** | Révocation immédiate, nettoyage de l'état courant, réécriture de l'historique Git — les trois étapes appliquées intégralement, cohérentes avec la doctrine de sécurité déjà établie dans ce projet. |

---

## 🔜 Prochaine étape

Reprise du déploiement applicatif sur ce cluster AWS : installation d'ArgoCD, `ApplicationSet` limité à `postgres` + `catalog-api` (sous-ensemble adapté à la RAM disponible sur `t3.small`, ~2 Go).

---

*Document — Méthode Josue, Mentor DevOps Senior.*
