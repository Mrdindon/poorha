# PoorHA — la haute dispo du pauvre pour VM et conteneurs Proxmox

Redondance **manuelle** de VM et de **conteneurs LXC** entre deux hôtes Proxmox **non clusterisés**, sans Ceph ni stockage partagé. C'est la généralisation d'[opnha](https://github.com/Mrdindon/opnha) : le même principe, appliqué à toutes les VM et à tous les conteneurs qu'on veut, et plus seulement au routeur OPNsense.

Tout tient dans **un seul script**, `poorha.sh`. On le copie sur un hôte, et il se déploie lui-même sur les deux. Il fournit :

- un **menu whiptail** pour l'usage courant, et des **commandes CLI** équivalentes ;
- le **choix des VM protégées** dans une liste à cocher qui couvre les deux nœuds ;
- la **réplication** de chaque VM vers son jumeau, **dans les deux sens**, une par une ou toutes d'un coup ;
- la **bascule d'urgence**, la **bascule planifiée** et la **mise en veille**, VM par VM ;
- le **garde-fou** : le même fichier sert de hookscript Proxmox à toutes les VM protégées ;
- le **déploiement** sur les deux hôtes : clés SSH, paquets, fichiers, config du pair, hookscript.

## Principe

Dans ce document, « VM » désigne aussi bien une VM QEMU qu'un conteneur LXC : PoorHA les traite de la même façon. Il utilise `qm` ou `pct` selon le cas.

Chaque VM protégée a un **jumeau** sur l'autre nœud. C'est une copie exacte, avec **les mêmes adresses MAC**. Pour chaque paire, un seul des deux est en service. Les rôles ne sont pas figés : PoorHA les déduit de l'état réel de chaque VM, et une paire peut être active d'un côté pendant qu'une autre l'est de l'autre.

| État affiché | VM | Cartes réseau |
|---|---|---|
| **ACTIVE** | démarrée | branchées |
| **STANDBY** | arrêtée | toutes coupées (`link_down=1`), sauf celles listées dans `keep` |
| **STANDBY (hot)** | démarrée | idem |
| stopped (links up) | arrêtée | branchées ; le garde-fou surveille son démarrage |
| missing | absente | sera créée par la première réplication |

Le fonctionnement repose sur quatre mécanismes, les mêmes qu'opnha :

- **Réplication.** `vzdump` à chaud de la VM source, transmis en flux direct (`zstd` → SSH → `qmrestore`) par-dessus le jumeau. La copie est remise en veille ensuite. La note de la VM indique la source et la date.
- **Veille.** Le jumeau est « débranché ». Il est **arrêté** (`standby=cold`, le défaut) ou **démarré** (`standby=hot`, pour un routeur).
- **Bascule.** On rebranche les cartes du jumeau et on le démarre. Comme les MAC sont identiques, rien ne change pour le reste du réseau.
- **Garde-fou.** Un hookscript `pre-start` refuse de démarrer une copie dont les cartes sont branchées si son jumeau est actif sur l'autre nœud, ou si son IP répond déjà sur le LAN.

## La config : un fichier par nœud

Chaque hôte a son propre `/etc/poorha/poorha.conf`. Le fichier décrit qui est l'hôte, qui est son pair, et quelles VM sont protégées :

```bash
NODE_NAME=pve1      NODE_IP=10.0.0.1      # cet hôte
PEER_NAME=pve2      PEER_IP=10.0.0.2      # l'autre
STORAGE=local-lvm                           # où arrivent les réplications reçues ICI
REF_IP=192.168.1.2                          # un switch toujours présent (garde-fou)
HEALTH_PING=                                # optionnel : test avant réplication

#  vmid ici   vmid sur le pair   options
vm 108 peer=208 standby=hot keep=net1 guard=192.168.1.1 note="Move the ONU / fiber to the WAN port of %NODE%."
vm 110 peer=110 guard=192.168.1.20
```

**Tu n'as pas à éditer les deux fichiers.** Toute modification faite par PoorHA, que ce soit l'ajout, le retrait ou un réglage, est recopiée chez le pair avec les vmid inversés : sur pve2, la première ligne devient `vm 208 peer=108 …`. Si tu édites un fichier à la main, lance `poorha deploy`, qui resynchronise les deux. En cas de conflit, c'est le nœud où tu lances la commande qui gagne.

### Les options d'une VM

| Option | Sens | Défaut |
|---|---|---|
| `peer` | vmid du jumeau sur l'autre nœud (modifiable, voir plus bas) | même vmid s'il est libre là-bas, sinon le prochain libre |
| `type` | `lxc` pour un conteneur ; absent pour une VM | détecté à l'ajout |
| `standby` | `cold` : jumeau arrêté ; `hot` : jumeau démarré | `cold` |
| `keep` | cartes qui **restent branchées** en veille (`net1`, `net0,net2`…) | aucune |
| `guard` | IP de la VM sur le LAN ; si elle répond, une copie est active | VM : détectée par l'agent invité ; conteneur : `ip=` de sa config, sinon `lxc-info` |
| `ref` | IP de référence propre à cette VM | `REF_IP` |
| `note` | rappel affiché après une activation (`%NODE%` = nom de l'hôte) | vide |

### Changer le vmid d'un jumeau

```bash
poorha set 130 peer=230      # ou menu › VM settings › twin vmid
```

La config des deux nœuds est mise à jour. L'ancien jumeau (130 sur le pair) n'est plus protégé, et il **n'est pas supprimé** : efface-le toi-même si tu n'en veux plus. La réplication suivante vers le pair crée la VM 230, ou l'écrase si elle existe déjà. Le changement est refusé si l'ancien jumeau est la copie active : bascule d'abord.

### Et OPNsense ?

PoorHA ne contient **aucun code propre à OPNsense**. Un routeur est simplement une VM avec ces réglages, regroupés dans le **profil routeur** :

- `standby=hot` : le routeur de secours tourne déjà ;
- `keep=<carte WAN>` : son WAN reste branché pour que le PPPoE monte dès que la fibre arrive ;
- `note="Move the ONU / fiber to the WAN port of %NODE%."`.

Dans le menu, choisis *VM settings*, puis *router profile*, puis la carte WAN. En CLI : `poorha set 108 profile=router keep=net1`.

## Contenu

| Fichier | Rôle |
|---|---|
| `poorha.sh` | le script unique (outil, menu, CLI et hookscript) |
| `poorha.conf.example` | exemple commenté de `/etc/poorha/poorha.conf` (l'assistant le génère) |
| `install.sh` | installation ou mise à jour depuis GitHub |

Une fois déployé, chaque hôte contient :

```
/usr/local/sbin/poorha                    l'outil
/var/lib/vz/snippets/poorha-guard.sh      le même fichier, appelé par Proxmox comme hookscript
/etc/poorha/poorha.conf                   la config de CE nœud
/etc/poorha/guard.disable                 présent seulement si le garde-fou est désactivé
/var/log/poorha/vzdump-<vmid>.log         journal du dernier vzdump de chaque VM source
/var/tmp/poorha-*.tar.zst                 conteneurs : archive reçue, le temps du « pct restore »
```

## Prérequis

- Deux hôtes Proxmox VE, joignables entre eux en **root par SSH** sur le lien MGMT. La clé est mise en place par le déploiement.
- **Mêmes noms de bridges** sur les deux hôtes. La réplication recopie la config de la VM telle quelle.
- **Une IP sur chaque bridge surveillé** par le garde-fou (`ip -br a`). `arping` en a besoin pour interroger le LAN.
- Assez d'espace sur le `STORAGE` de chaque hôte pour **toutes** les VM protégées, puisque la réplication peut aller dans les deux sens.
- Hotplug réseau actif sur les VM. C'est le défaut, et c'est ce qui permet de couper ou rebrancher une carte sans redémarrer la VM.
- Recommandé : l'**agent invité QEMU** dans les VM. La sauvegarde à chaud est alors cohérente, et PoorHA peut détecter l'IP de garde.
- `arping`, `whiptail` et `zstd` sont installés automatiquement par le déploiement s'ils manquent.

**Conteneurs.**
- Couper une carte réseau d'un conteneur demande l'option `link_down` sur ses cartes. Elle existe dans les versions récentes de PVE : vérifie qu'un `pct set <ct> --net0 …,link_down=1` est accepté sur ta version, conteneur démarré.
- `pct restore` ne sait pas lire directement le flux reçu par SSH. L'archive est donc d'abord écrite dans `TMP_DIR` (`/var/tmp` par défaut) sur l'hôte de destination, ce qui demande assez de place pour l'archive compressée du plus gros conteneur.
- Si le stockage du conteneur ne permet pas les snapshots, `vzdump` passe de lui-même en mode `suspend` : le conteneur est gelé quelques instants pendant la sauvegarde.

**Points de montage des conteneurs** : `vzdump` n'emporte que le `rootfs` et les volumes marqués `backup=1`. PoorHA avertit à l'ajout, dans le statut et avant chaque réplication :
- un **bind mount** (`mp0: /mnt/data,…`) n'est pas copié ; le chemin doit exister sur l'autre hôte, sinon le conteneur refusera de démarrer ;
- un **volume sans `backup=1`** n'est pas copié non plus : ses données ne suivent **pas**. Coche *Backup* sur ce point de montage dans l'interface Proxmox si tu veux qu'il soit répliqué.

**Matériel passé à la VM** (`hostpci`, `usb`, `dev0` d'un conteneur) : la config est copiée telle quelle. Si le périphérique n'existe pas sur l'autre hôte, ou n'a pas la même adresse, la VM refusera de démarrer avec une erreur explicite dans *Tasks*. C'est le rappel qu'il faut déplacer le matériel (une clé Zigbee, par exemple) ou adapter la config.

## Installation

Tout se fait **depuis un seul hôte**.

```bash
scp poorha.sh root@pve1:/root/
ssh root@pve1
chmod +x /root/poorha.sh && /root/poorha.sh     # → assistant de configuration au premier lancement
```

1. **L'assistant** configure ce nœud : nom, IP MGMT, pair, stockage cible, IP de référence.
2. **Deploy** installe tout sur les deux hôtes et **crée la config du pair**. Il demande quel stockage de l'autre hôte recevra les réplications.
3. **Select VMs** affiche toutes les VM et tous les conteneurs (marqués `[CT]`) des deux nœuds. Au premier passage, **tout est coché**. Décoche ce que tu ne veux pas protéger. Un écran *Twin vmids* récapitule ensuite le vmid proposé pour chaque jumeau : choisis une ligne pour le changer.
4. **VM settings** sert à appliquer le profil routeur à OPNsense et à vérifier les IP de garde.
5. **Replicate**, puis *all* : la première réplication crée tous les jumeaux.

### Depuis une installation opnha

```bash
poorha import-opnha     # sur l'un des deux hôtes : reprend /etc/opnsense-ha/ha.conf
poorha deploy           # crée la config du pair, remplace le hookscript opnha
```

La paire 108 ↔ 208 est reprise avec le profil routeur : carte du `WAN_BRIDGE` gardée, `GW_IP` comme IP de garde. opnha peut ensuite être supprimé des deux hôtes. La commande à lancer est affichée à la fin de l'import.

## Utilisation

```
┌──────────────────────────────── poorha 0.3 ────────────────────────────────┐
│ On pve1, peer pve2                                                         │
│                                                                            │
│                  SOURCE (active)              DESTINATION (standby)        │
│   VM             HOST    VMID    STATUS       HOST    VMID    STATUS       │
│   opnsense       pve1    vm108   ACTIVE       pve2    vm208   STANDBY hot  │
│   homeassistant  pve2    vm110   ACTIVE       pve1    vm110   STANDBY      │
│   pihole         pve1    ct130   ACTIVE       pve2    ct130   missing      │
│                                                                            │
│      status      Detailed status                                           │
│      replicate   Replicate a VM (or all) onto its twin                     │
│      …                                                                     │
└────────────────────────────────────────────────────────────────────────────┘
```

La colonne de gauche est toujours la **copie active**, donc la source d'une réplication, quel que soit le nœud où elle tourne. Si aucune copie n'est active, ou si les deux le sont, la copie locale est à gauche. Les deux statuts permettent alors de voir le problème.

**Répliquer** copie une VM sur son jumeau, dans le sens *actif → veille* par défaut. *all* fait de même pour toutes les paires dont le sens est clair. PoorHA :
- **refuse** d'écraser une copie ACTIVE ;
- avertit si la source est arrêtée, si elle n'est pas la copie active, ou si `HEALTH_PING` ne répond pas ;
- arrête la destination, transfère, pose `onboot` (1 en `hot`, 0 en `cold`) et le hookscript, puis remet la copie en veille. En `hot`, il la redémarre.

**Bascule planifiée** s'utilise quand les deux nœuds sont vivants. L'ordre dépend du mode et de la réplication :
- **`cold` avec réplication** : l'actif est **arrêté d'abord**, puis répliqué, puis le jumeau démarre. Rien de ce qui a été écrit n'est perdu, ce qui est important pour une base de données ou Home Assistant. Le service est coupé pendant le transfert.
- **`cold` sans réplication** : les cartes de l'actif sont coupées, le jumeau est branché et démarré, et l'ancien actif n'est éteint qu'**ensuite**. La coupure se limite au démarrage du jumeau.
- **`hot`** (routeur, ou toute VM dont le jumeau tourne en permanence) : réplication à chaud si demandée, puis l'actif passe en veille et le jumeau est activé. La coupure ne dure que quelques secondes.

Si une étape échoue (copie interrompue, démarrage refusé…), PoorHA **remet l'ancienne copie en service** avant de s'arrêter.

**Activation d'urgence** s'utilise quand le nœud de la copie active est mort. Elle est refusée si l'IP de garde répond encore ou si l'autre copie est vue active, sauf avec `-f`.

**Mise en veille** coupe les cartes (sauf `keep`). En `cold`, elle éteint aussi la VM et pose `onboot=0`.

### CLI

```bash
poorha status [VM]
poorha list                                 # VM protégées et leurs options
poorha add 130                              # protège une VM ou un conteneur (cherché sur les deux nœuds)
poorha add all                              # protège toutes les VM non protégées
poorha set 108 profile=router keep=net1
poorha set homeassistant guard=192.168.1.20
poorha remove 130                           # n'efface aucune VM
poorha replicate                            # toutes : actif → veille
poorha replicate 110 --to pve1            # sens explicite
poorha switch homeassistant pve1          # bascule planifiée
poorha activate 108 pve2 [-f]             # urgence
poorha standby 108 pve1
poorha guard test 108 pve2 | guard off pve1 | guard on pve1
poorha deploy
```

`VM` est le vmid local, le vmid du pair ou le nom de la VM. `NODE` est le nom d'un des deux hôtes. Options communes : `-y` (sans confirmation), `-f` (forcer), `--no-start`, `--replicate` / `--no-replicate`.

## Le garde-fou en détail

Proxmox exécute `poorha-guard.sh <vmid> pre-start` avant chaque démarrage d'une VM protégée. Une sortie non nulle **annule le démarrage**, et le message apparaît dans *Tasks*.

1. Si la VM n'est pas protégée, ou si `guard.disable` existe, le démarrage est autorisé.
2. Si toutes ses cartes surveillées sont en `link_down=1`, c'est une veille : le démarrage est autorisé.
3. **Vérification par le pair** (SSH, 3 s max) : si le jumeau tourne avec ses cartes branchées, le démarrage est **bloqué**. Si le pair est injoignable, on passe à l'étape suivante.
4. **Vérification par l'IP** (si `guard` est renseigné) : jusqu'à `GUARD_TRIES` fois, si l'IP de garde répond en ARP, le démarrage est **bloqué**. Si l'IP de référence répond mais pas l'IP de garde, il est autorisé. Sans IP de référence, on essaie 3 fois.
5. Sinon, le démarrage est autorisé.

| Situation | Résultat |
|---|---|
| Boot normal, le jumeau en veille | autorisé |
| L'ancien actif redémarre après une bascule d'urgence | **bloqué** par le pair, ou par l'IP si le pair est down |
| Démarrage d'une copie en veille | autorisé (cartes coupées) |
| VM sans IP de garde, pair injoignable | autorisé : **renseigne `guard`** pour ce cas |
| IP de garde renseignée, `arping` absent | **bloqué** |

## Limites

- **Copie à l'instant T.** Le jumeau reflète la source au moment de la dernière réplication.
- **Copie complète à chaque fois.** `vzdump` transfère tout le disque. Pour de grosses VM, cela prend du temps et de la bande passante sur le lien MGMT.
- **Échec en cours de transfert.** La destination peut se retrouver absente ou incomplète : il faut relancer. La source n'est jamais touchée.
- **MAC identiques.** C'est voulu, et sûr **uniquement** parce qu'une seule copie est branchée à la fois.
- **Ne modifie jamais une copie en veille.** Elle serait écrasée à la prochaine réplication.
- **Points de montage de conteneur** : seuls le `rootfs` et les volumes `backup=1` sont répliqués (voir *Prérequis*).
- **Un seul stockage cible par nœud.** Tous les disques d'une VM restaurée vont dans `STORAGE`.
- Une VM qui a déjà **son propre hookscript** n'est pas ajoutée sans `-f`, car PoorHA le remplacerait.
