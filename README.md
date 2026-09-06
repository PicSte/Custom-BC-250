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

## Démarrage rapide

```sh
git clone https://github.com/PicSte/Custom-BC-250
cd Custom-BC-250
sudo ./install.sh

sudo bc250ctl doctor                        # que voit l'outil ?
sudo bc250ctl bootstrap --profile safe      # commencer prudemment
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

| Module | Ce qu'il fait |
|---|---|
| `kargs` | Limites mémoire TTM (`ttm.pages_limit`), `mitigations=off` selon le profil |
| `sensors` | Pilote `nct6683 force=true` pour les températures |
| `governor` | `cyan-skillfish-governor-smu` + sa courbe fréquence/tension |
| `gpu-cu` | Déblocage 40 CU et routage des WGP, à chaud via `umr` |
| `cpu-cores` | Déblocage des 2 cœurs masqués (6c/12t → 8c/16t) |
| `cpu-oc` | Overclock / undervolt CPU, avec calibration sous charge |
| `fixes` | Masquage de `hhd` (micro-saccades de l'interface Deck) |

```sh
sudo bc250ctl status                # ce qui est appliqué maintenant
sudo bc250ctl install gpu-cu        # un module à la fois
sudo bc250ctl verify all            # est-ce que ça a vraiment pris ?
sudo bc250ctl revert cpu-oc         # retour à l'état d'origine
sudo bc250ctl menu                  # menu interactif
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
./tests/lint.sh     # shellcheck
bats tests/         # 55 tests
```

La suite tourne contre un préfixe bac à sable avec les commandes système simulées :
ni BC-250 ni root nécessaires, et aucun accès réseau. Voir `docs/validation.md` pour la
recette de validation sur matériel réel.

## Documentation

- [`docs/modules.md`](docs/modules.md) — ce que fait chaque module, en détail
- [`docs/validation.md`](docs/validation.md) — comment valider sur une vraie carte
- [`docs/troubleshooting.md`](docs/troubleshooting.md) — quand ça ne marche pas
