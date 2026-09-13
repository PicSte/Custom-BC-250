# bc250ctl

Un seul outil pour installer, configurer et vérifier les tweaks BC-250 sur Bazzite.

Faire tourner correctement une carte ASRock BC-250 sous Bazzite demande d'aller
chercher plusieurs projets indépendants, chacun avec son installeur, son format de
configuration et ses pièges — et de tout refaire à la main sur chaque install fraîche,
dans le bon ordre, avec des reboots au milieu. `bc250ctl` fait ça en une commande, et
reprend tout seul après chaque redémarrage.

Il ne remplace aucun de ces projets : il les télécharge à une version épinglée, les
installe et les configure ensemble de façon cohérente. Tout le mérite technique revient
à leurs auteurs — voir [Sources](#sources).

## L'interface graphique

```sh
bc250-gui          # ou « BC-250 » dans le menu des applications
```

Une application GTK4 qui regroupe tout : l'état de chaque module et son
installation, les réglages avec leurs garde-fous, la supervision en direct, et
un assistant de première installation qui reprend après chaque redémarrage.

Elle ne contient aucun savoir métier : elle lit `bc250ctl catalog --json` et
`bc250ctl config --json`, donc un module ajouté au moteur y apparaît tout seul.
Elle ne tourne jamais en root — le travail privilégié passe par `pkexec`, et
il est regroupé pour qu'une action ne demande qu'une autorisation.

Détails dans [`docs/gui.md`](docs/gui.md).

## Démarrage rapide

```sh
git clone https://github.com/PicSte/Custom-BC-250
cd Custom-BC-250
sudo ./install.sh

sudo bc250ctl doctor                        # que voit l'outil ?
sudo bc250ctl bootstrap --profile safe      # commencer prudemment
bc250-gui                                   # ou tout faire depuis l'interface
```

`bootstrap` s'arrête quand un redémarrage est nécessaire, arme un service systemd, et
reprend là où il s'était arrêté au boot suivant. Répétez `systemctl reboot` tant qu'il
le demande.

Quand tout est vert, vous pouvez monter en puissance :

```sh
sudo bc250ctl bootstrap --profile balanced
```

## Profils

| Profil | GPU | CPU | Pour qui |
|---|---|---|---|
| `safe` | routage d'origine (24 CU) | 6 cœurs, aucun OC | Première install. Capteurs, governor, limites TTM. Rien qui change l'enveloppe thermique. |
| `balanced` | 40 CU, 1500 MHz / 900 mV | 8 cœurs, aucun OC | Usage quotidien recommandé. ~83 °C et 125 W, contre 96 °C et 181 W à 2 GHz sans limite. |
| `max` | 40 CU, jusqu'à 1600 MHz | 8 cœurs + OC calibré | À condition de lire `docs/modules.md`. L'OC se calibre sur *votre* carte. |

Le profil choisi est copié dans `/etc/bc250ctl/config.env`. C'est ce fichier que
l'outil lit ensuite : éditez-le librement, il ne sera pas écrasé (sauf si vous
repassez `--profile`).

## Modules

| Module | Risque | Ce qu'il fait |
|---|---|---|
| `kargs` | faible | Limites mémoire TTM, `mitigations=off`, `video=DP-1:e` selon le profil |
| `acpi` | faible | Tables ACPI reconstruites : C-states pour 16 threads, P-states |
| `sensors` | aucun | Pilote `nct6683 force=true`, températures en lecture seule |
| `fan-control` | moyen | Pilote `nct6687` avec PWM. **Exclusif avec `sensors`** |
| `governor` | faible | `cyan-skillfish-governor-smu` + sa courbe fréquence/tension |
| `gpu-cu` | moyen | Déblocage 40 CU et routage des WGP, à chaud via `umr` |
| `cpu-cores` | élevé | Déblocage des 2 cœurs masqués (6c/12t → 8c/16t). **Exige `acpi`** |
| `cpu-oc` | élevé | Overclock / undervolt CPU, avec calibration sous charge |
| `fixes` | faible | `hhd`, veille cassée, ZRAM |

Trois relations sont modélisées et vérifiées par l'outil :

- **Dépendance** — `cpu-cores` exige `acpi` (sans les tables reconstruites, les CPU 12-15
  n'ont aucun C-state et consomment à vide) ; `cpu-oc` exige `cpu-cores` et `gpu-cu`.
- **Conflit** — `sensors` et `fan-control` visent la même puce Nuvoton. L'un ou l'autre.
- **Verrou SMU** — le governor et les écritures SMU partagent la même fenêtre PCI
  `0xB8`/`0xBC`. `bc250ctl` arrête le governor autour de chaque écriture et le relance.

```sh
sudo bc250ctl status                # ce qui est appliqué maintenant
sudo bc250ctl install gpu-cu        # un module à la fois
sudo bc250ctl verify all            # est-ce que ça a vraiment pris ?
sudo bc250ctl revert cpu-oc         # retour à l'état d'origine
sudo bc250ctl menu                  # menu interactif
bc250ctl catalog --json             # le graphe complet, pour l'outillage
bc250ctl config --json              # réglages effectifs et leur schéma
bc250ctl telemetry --json           # températures, fréquences, ventilation
```

Ajoutez `--dry-run` à n'importe quelle commande pour voir ce qui se passerait sans rien
changer.

## Sécurité

Ce que l'outil refuse, sans discussion possible :

- Une tension cœur CPU au-dessus de **1275 mV** sans `BC250_ALLOW_EXTREME_VID=1`.
- Une tension au-dessus de **1325 mV**, jamais, quelle que soit l'option. Au-delà, le
  SoC est détruit.
- Une montée en fréquence CPU sans plafond de tension : le Vid scale alors sans limite,
  c'est la façon documentée de tuer la carte.
- Toute écriture de registre si aucune BC-250 n'est détectée (contournable par
  `--force`, à vos risques).

Et la porte de sortie matérielle, qui marche quoi qu'il arrive : **le déblocage des CU
et des cœurs vit en RAM**. Une coupure d'alimentation franche — pas un simple reboot —
remet la carte d'origine. Si une configuration ne démarre plus, débranchez.

## Sources

Tout est épinglé par commit et par somme de contrôle dans `sources.env` ; rien n'est
tiré d'une branche mouvante, parce que tout ça s'exécute en root.

- [WinnieLV/bc250-cu-live-manager](https://github.com/WinnieLV/bc250-cu-live-manager) —
  40 CU et routage WGP à chaud, déblocage des cœurs CPU
- [mendesrr/bc250-acpi-fix-updated-8c](https://github.com/mendesrr/bc250-acpi-fix-updated-8c)
  — tables SSDT reconstruites (C-states 16 threads, P-states)
- [Fred78290/nct6687d](https://github.com/Fred78290/nct6687d) — pilote Nuvoton avec PWM
- [bc250-collective/bc250_smu_oc](https://github.com/bc250-collective/bc250_smu_oc) —
  overclock / undervolt CPU
- [filippor/cyan-skillfish-governor](https://github.com/filippor/cyan-skillfish-governor)
  (COPR `filippor/bazzite`) — governor GPU
- [duggasco/bc250-40cu-unlock](https://github.com/duggasco/bc250-40cu-unlock) — la
  recherche d'origine sur les registres 40 CU
- [elektricM/amd-bc250-docs](https://elektricm.github.io/amd-bc250-docs/) et
  [mothenjoyer69/bc250-documentation](https://github.com/mothenjoyer69/bc250-documentation)
  — la documentation de référence

```sh
bc250ctl sources --check    # un upstream a-t-il bougé ?
```

Mettre à jour une source est une modification délibérée de `sources.env`, relue comme
n'importe quel autre changement.

### Projets voisins

Si `bc250ctl` ne vous convient pas, deux projets couvrent un terrain proche :
[NeOdYmS/bazzite-bc250-toolkit](https://github.com/NeOdYmS/bazzite-bc250-toolkit) (menu
de post-installation) et
[62fixolab/Latest-Bazzite-AMD-BC-250-Patched-Images](https://github.com/62fixolab/Latest-Bazzite-AMD-BC-250-Patched-Images)
(images Bazzite pré-patchées, via `rpm-ostree rebase`).

## Développement

```sh
./tests/lint.sh                          # shellcheck + parse des sources Python
bats tests/                              # 118 tests, le moteur
xvfb-run -a python3 -m pytest gui/tests/ # 47 tests, l'interface
```

Les deux suites tournent contre un préfixe bac à sable avec les commandes système
simulées : ni BC-250 ni root nécessaires, et aucun accès réseau. Voir
`docs/validation.md` pour la recette de validation sur matériel réel.

## Documentation

- [`docs/modules.md`](docs/modules.md) — ce que fait chaque module, en détail
- [`docs/validation.md`](docs/validation.md) — comment valider sur une vraie carte
- [`docs/troubleshooting.md`](docs/troubleshooting.md) — quand ça ne marche pas
- [`docs/gui.md`](docs/gui.md) — l'interface graphique : ce qu'elle fait, et pourquoi
  elle ne décide rien
- [`docs/inventory.md`](docs/inventory.md) — l'écosystème BC-250 : ce qu'on gère, ce
  qu'on ne gère pas, et pourquoi
