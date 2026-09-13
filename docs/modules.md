# Les modules en détail

Chaque module est un fichier de `modules/`, avec le même contrat : `describe`,
`requires`, `conflicts`, `invalidates`, `stage`, `unattended`, `risk`, `needs_smu`,
`upstream`, `active`, `detect`, `status`, `install`, `configure`, `verify`,
`uninstall`. Le préfixe numérique fixe l'ordre d'application.

Deux notions à ne pas confondre :

- **`detect`** — « l'état correspond-il à ce que la configuration demande ? » Vrai, donc,
  pour un module à qui on n'a rien demandé.
- **`active`** — « y a-t-il quelque chose d'appliqué au matériel ? » C'est cette
  question-là qui décide si un changement ailleurs rend ce module caduc, et si un
  conflit doit être signalé.

`bc250ctl catalog --json` publie tout ça sous forme lisible par une machine. C'est ce que
consommera l'interface graphique : elle n'aura aucune métadonnée en propre, et un module
ajouté ici apparaîtra dans l'UI sans y toucher.

---

## Le verrou SMU

Trois modules parlent au SMU, et deux d'entre eux ne peuvent pas le faire en même temps
que le troisième.

Le governor, le déblocage des cœurs et l'overclock CPU passent tous par la même fenêtre
index/data en configuration PCI : registres `0xB8`/`0xBC` du device `00:00.0`. Il n'y a
aucun arbitrage matériel. Si le governor écrit un index pendant qu'un autre outil est au
milieu d'une transaction, les deux finissent par lire et écrire à de mauvaises adresses
SMN.

`lib/smu.sh` en fait une section critique : `smu_critical` arrête
`cyan-skillfish-governor-smu` s'il tourne, exécute l'écriture, et le relance — y compris
si la commande échoue ou est interrompue. Les modules concernés le déclarent avec
`mod_needs_smu`.

---

## `10-kargs` — arguments noyau

`ttm.pages_limit=3959290` et `ttm.page_pool_size=3959290` relèvent le plafond
d'allocation TTM. Sans eux, les grosses allocations GPU échouent bien en dessous des
16 Go installés.

`mitigations=off` échange les protections contre les canaux auxiliaires du CPU contre
des performances. C'est un choix, pas un réglage évident : il reste optionnel par profil
(`BC250_KARGS_MITIGATIONS_OFF`).

Étape *pre-reboot* : `rpm-ostree kargs` ne prend effet qu'au redémarrage.

## `15-acpi` — tables ACPI

Le SSDT d'origine de la carte déclare des objets processeur jusqu'à `C00B`, soit douze
threads. C'est correct sur une BC-250 à six cœurs, et faux dès que les deux cœurs masqués
arrivent : les CPU 12-15 se retrouvent sans aucun état cpuidle et consomment à vide.

Les tables reconstruites étendent les déclarations jusqu'à `C00F` et apportent aussi la
table de P-states (800-3200 MHz). C'est pour cette seconde raison que le module est dans
le profil `safe` et pas seulement traité comme une dépendance du déblocage : il améliore
une carte restée à six cœurs.

Le chargement se fait avant les tables du firmware, depuis une archive cpio que GRUB
passe au noyau comme initrd précoce :

```
/boot/SSDT_ACPI.cpio                          kernel/firmware/acpi/SSDT-{CST,PST}.aml
/etc/default/grub                             GRUB_EARLY_INITRD_LINUX_CUSTOM=...
ujust regenerate-grub                         (grub2-mkconfig en repli)
```

`verify` lit `cpupower -c all idle-info` : le moindre CPU annonçant zéro état d'inactivité
signifie que les tables ne sont pas chargées.

## `20-sensors` — températures

La puce Nuvoton de la BC-250 annonce un identifiant que le pilote `nct6683` ne
reconnaît pas ; il faut donc forcer l'attachement. `force=true` est de la lecture seule,
ça n'autorise personne à écrire dans les registres de ventilation ou de tension.

Écrit `/etc/modules-load.d/99-bc250-sensors.conf` et
`/etc/modprobe.d/99-bc250-sensors.conf`, puis tente un `modprobe` immédiat — si ça
passe, pas besoin de redémarrer.

## `25-fan-control` — ventilation

Deux pilotes revendiquent la puce Nuvoton de la carte, et un seul peut l'avoir :

- `nct6683`, dans le noyau, **lecture seule**. Températures, rien d'autre.
- `nct6687` ([`Fred78290/nct6687d`](https://github.com/Fred78290/nct6687d)), hors arbre,
  **lecture/écriture**. Le seul chemin vers le PWM.

D'où un conflit déclaré avec `20-sensors`, et non une extension. Bazzite livre `nct6687d`
sous forme d'akmod, donc dans le cas courant il n'y a rien à installer : le travail
consiste à choisir le bon pilote et à faire tenir la consigne de ventilation.

Car le pilote **oublie ses valeurs PWM à chaque redémarrage**. `BC250_FAN_PWM` tranche :

- `auto` — la courbe appartient à CoolerControl, qui gère son propre service.
- un entier `0`-`255` — `bc250ctl` installe une unité qui repose cette consigne au
  démarrage, après avoir basculé chaque canal en mode manuel.

Le module retire lui-même les fichiers de `20-sensors` au passage : laisser les deux
configurations en place ne donne pas deux pilotes, ça n'en donne aucun qui fonctionne.

## `30-governor` — governor GPU

Le SMU de la BC-250 ne fait aucune gestion d'énergie utile tout seul : sans governor, le
GPU reste à une fréquence fixe. `cyan-skillfish-governor-smu` pilote fréquence et
tension d'après la charge et la température.

Le paquet vient du COPR `filippor/bazzite`. Le dépôt est écrit directement dans
`/etc/yum.repos.d/` plutôt que par `dnf copr enable`, qui n'est pas fiable sur une image
atomique — avec `gpgcheck=1` contre la clé du projet.

**La courbe.** `bc250ctl` n'invente jamais de couple fréquence/tension. Il reprend la
courbe par défaut de l'amont et la coupe aux plafonds du profil :

| MHz | mV |
|---|---|
| 500 | 700 |
| 1000 | 800 |
| 1175 | 850 |
| 1500 | 900 |
| 1600 | 910 |
| 1700 | 920 |
| 1850 | 930 |
| 2000 | 960 |

Avec `balanced` (1500 MHz / 900 mV) les quatre premiers points sont retenus. Si aucun
point ne rentre dans les plafonds, c'est une erreur — pas une courbe vide.

Le governor trouve le GPU tout seul : il n'y a pas de réglage de périphérique dans sa
configuration. La détection `card0` / `card1` de `bc250ctl` sert donc à la
*vérification*, pas à la configuration — c'est là qu'on regarde si les fréquences
bougent vraiment.

## `40-gpu-cu` — déblocage 40 CU

La carte n'expose que 24 de ses 40 CU. Trois registres décident de ça :
`CC_GC_SHADER_ARRAY_CONFIG`, `SPI_PG_ENABLE_STATIC_WGP_MASK` et
`RLC_PG_ALWAYS_ON_WGP_MASK`.

`bc250ctl` utilise la méthode **runtime** : `bc250-cu-live-manager` écrit ces registres
depuis l'espace utilisateur via `umr`, une fois le pilote démarré. Rien n'est recompilé,
donc une mise à jour de noyau Bazzite ne peut pas casser le déblocage. Les écritures
sont rejouées à chaque démarrage par le service systemd de l'amont.

La granularité est le **WGP**, soit une paire de CU : un CU seul ne se route pas.
`BC250_GPU_WGP_LAYOUT` accepte :

- `all` — les 20 WGP, soit 40 CU
- `stock` — le routage d'origine
- une liste `SE.SH.WGP` séparée par des virgules, pour laisser désactivés les WGP
  défectueux d'une carte donnée. Exemple : `1.0.3` laisse les CU 6 et 7 de côté, soit
  38 CU actifs.

Toutes les cartes ne supportent pas les 40 CU. Si vous avez des plantages GPU après
déblocage, c'est la piste : `bc250-cu-live-manager table` permet d'isoler le WGP fautif,
et sa référence se met ensuite dans `BC250_GPU_WGP_LAYOUT`.

## `50-cpu-cores` — 6 → 8 cœurs

Deux des huit cœurs Zen 2 sont masqués, pas grillés. Le masque est dans un registre SMU
(`0x77` → `0xFF`) accessible depuis l'hôte : aucun flash de BIOS.

Deux conséquences, et elles comptent :

- **Une coupure d'alimentation remet le masque à zéro.** C'est la porte de sortie : si
  8 cœurs se révèlent instables, débranchez, vous repartez à 6.
- **L'écriture ne prend effet qu'au redémarrage suivant.** L'unité systemd installée
  réarme le masque à chaque boot, donc un reboot à chaud démarre toujours à 8 cœurs ;
  le premier démarrage après une coupure est encore à 6.

## `60-cpu-oc` — overclock / undervolt CPU

`bc250_smu_oc` relève le plafond de boost et fixe un plafond de Vid, en laissant le
scaling dynamique en place. C'est un paquet Python : il va dans un venv sous
`/var/lib/bc250ctl/venv`, jamais dans le Python système — `/usr` est en lecture seule
sur Bazzite de toute façon.

**Les chiffres d'un profil sont un point de départ, pas un réglage validé.** Le silicium
varie : un overclock stable sur une carte ne démarre pas sur une autre. `install` lance
donc `bc250-detect`, qui teste sous charge sur *votre* carte et écrit ce qui a
réellement tenu.

Ce module a des dépendances déclarées sur `50-cpu-cores` et `40-gpu-cu` : calibrer avant
que le nombre de cœurs et le routage GPU soient fixés produit une courbe caduque à
l'instant où elle est écrite, puisque les deux changent le budget thermique et
électrique mesuré. Inversement, changer l'un des deux ensuite marque cet overclock
*stale*, visible dans `status` et signalé par `verify`.

C'est aussi le seul module qui refuse de tourner sans surveillance : la reprise
automatique après redémarrage le met de côté et vous dit de le lancer à la main.

À savoir : `bc250-detect` charge le CPU avec `stress --cpu 12`, soit 12 threads en dur.
Sur une carte débloquée à 8 cœurs (16 threads), la charge est donc un peu plus légère
qu'elle ne devrait — gardez-le en tête en interprétant un résultat « stable ».

## `70-fixes` — quirks de la carte

Trois correctifs indépendants, chacun derrière son propre indicateur parce qu'aucun n'est
souhaité universellement.

**`hhd`** — le démon pour consoles portables de Bazzite interroge du matériel que la
BC-250 n'a pas, et ça se voit sous forme de micro-saccades dans l'interface Deck. Le
masquer est le correctif documenté.

**Veille** — s2idle est cassé : la carte s'endort et ne se réveille pas. Laisser la mise
en veille active n'est pas une fonctionnalité, c'est un piège. Le module masque
`sleep.target` et ses trois voisins.

**ZRAM** — le swap compressé est mis en cause dans des plantages de jeux (RDR2, Company
of Heroes 3). Le nom de l'unité dépend du générateur que l'image embarque, donc le module
essaie les variantes connues plutôt que d'en supposer une.

L'autre agacement connu — MangoHud et radeontop qui annoncent une utilisation GPU à
plusieurs centaines de pour cent — n'est pas traité ici : il est corrigé par
`fix-metrics = true` dans la configuration du governor, que `30-governor` écrit déjà.
