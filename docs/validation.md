# Valider sur une vraie carte

La suite de tests couvre la logique — ordre des modules, invalidation croisée, reprise
après redémarrage, refus des tensions hors bornes — mais elle simule chaque commande
système. Rien ne remplace un passage sur la carte.

Faites-le **un module à la fois**, avec un redémarrage et une vérification entre chaque.
Si quelque chose tourne mal, vous saurez quoi.

## Avant de commencer

- Alimentation 300 W minimum, ventilation 120 mm à forte pression statique.
- Un moyen de couper l'alimentation physiquement. C'est la porte de sortie de tous les
  déblocages.
- IOMMU désactivé dans le BIOS, VRAM en `UMA_SPECIFIED` à 512 Mo.

## Recette

```sh
# 1. Ce que l'outil voit avant toute modification
sudo bc250ctl doctor

# 2. Répétition générale : rien n'est écrit
sudo bc250ctl bootstrap --profile safe --dry-run

# 3. Le socle : capteurs, governor, limites TTM
sudo bc250ctl bootstrap --profile safe
#    redémarrer autant de fois que demandé
sensors                                     # les températures remontent
systemctl status cyan-skillfish-governor-smu
sudo bc250ctl verify all

# 4. Les tables ACPI, avant tout déblocage de cœurs
sudo bc250ctl install acpi
sudo systemctl reboot
cpupower -c all idle-info | grep -c 'Number of idle states: 0'   # attendu : 0
cpupower frequency-info                                          # P-states 800-3200 MHz

# 5. Les 40 CU
sudo bc250ctl install gpu-cu
sudo bc250ctl verify gpu-cu
RADV_DEBUG=info vulkaninfo --summary 2>&1 | grep num_cu
#    attendu : num_cu = 40 et num_cu_per_sh = 10

# 6. Les 8 cœurs
sudo bc250ctl install cpu-cores
sudo systemctl reboot
nproc                                       # attendu : 16 threads
cpupower -c all idle-info | grep -c 'Number of idle states: 0'   # toujours 0
journalctl -u cyan-skillfish-governor-smu   # aucune erreur SMN autour du déblocage

# 7. L'overclock CPU, une fois le reste stable
sudo bc250ctl install cpu-oc                # calibration sous charge, plusieurs minutes

# 8. Le retour arrière fonctionne-t-il ?
sudo bc250ctl revert all
sudo bc250ctl status
```

## Vérifier la reprise après redémarrage

C'est le mécanisme le plus facile à casser sans s'en rendre compte :

```sh
sudo bc250ctl bootstrap --profile balanced
# → l'outil s'arrête et demande un redémarrage
systemctl reboot
# → ne rien lancer, attendre
sudo bc250ctl status
```

`status` doit montrer le bootstrap terminé et les modules appliqués, sans intervention.
Si le service de reprise n'a pas tourné :

```sh
systemctl status bc250ctl-resume.service
journalctl -u bc250ctl-resume.service
```

## Tester la santé des CU

Toutes les cartes ne tiennent pas les 40 CU. Si vous constatez des plantages GPU après
le déblocage, isolez le WGP fautif avec l'outil amont, puis figez le résultat :

```sh
sudo bc250-cu-live-manager table            # activer/désactiver WGP par WGP, à chaud
```

Une fois le coupable identifié, mettez sa référence dans `/etc/bc250ctl/config.env` :

```sh
BC250_GPU_WGP_LAYOUT=1.0.3                  # 38 CU au lieu de 40
```

puis `sudo bc250ctl configure gpu-cu`.

## Vérifier le verrou SMU

Le governor et les écritures SMU partagent la même fenêtre PCI. `bc250ctl` arrête le
governor autour de chaque écriture ; ça doit se voir :

```sh
sudo systemctl start cyan-skillfish-governor-smu
sudo bc250ctl install cpu-cores               # doit annoncer la mise en pause du governor
systemctl is-active cyan-skillfish-governor-smu   # actif à nouveau après coup
```

## Basculer vers la ventilation pilotée

`sensors` et `fan-control` sont exclusifs. La bascule doit être explicite :

```sh
sudo bc250ctl revert sensors
sudo bc250ctl install fan-control
sudo systemctl reboot
sensors                                      # nct6687 remonte températures ET ventilateurs
```

Avec `BC250_FAN_PWM=auto`, la courbe appartient à CoolerControl. Avec une valeur
numérique, vérifier qu'elle tient après redémarrage :

```sh
systemctl status bc250ctl-fan.service
cat /sys/class/hwmon/hwmon*/pwm1
```

## Ce qui reste à confirmer sur matériel

Ces points sont écrits d'après la documentation amont et n'ont pas pu être testés sur
une carte :

- **Disponibilité de `umr` sur Bazzite.** L'outil délègue son installation à
  `bc250-cu-live-manager install-umr`, qui gère `rpm-ostree`. Si le paquet est superposé,
  il faut un redémarrage de plus — `bc250ctl` le détecte et diffère le déblocage, mais
  l'enchaînement exact mérite d'être vérifié.
- **Le COPR sur image atomique.** Le fichier `.repo` est écrit directement plutôt que par
  `dnf copr enable`. À confirmer que `rpm-ostree install` le voit bien.
- **Le nom exact du paquet `stress`** dans les dépôts Fedora utilisés par Bazzite.
- **`ujust regenerate-grub`** — la recette existe sur Bazzite, mais le repli
  `grub2-mkconfig` et le chemin exact de `grub.cfg` méritent confirmation.
- **Le nom du paquet akmod `nct6687d`** si le module n'est pas déjà présent dans l'image.
- **`bc250-detect` charge le CPU avec `stress --cpu 12`**, soit douze threads en dur. Sur
  une carte débloquée à seize threads, la charge est donc plus légère qu'elle ne devrait ;
  un résultat « stable » est à prendre avec cette réserve.
