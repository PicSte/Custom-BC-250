# Quand ça ne marche pas

## D'abord

```sh
sudo bc250ctl doctor        # ce que l'outil voit
sudo bc250ctl status        # ce qui est censé être appliqué
sudo bc250ctl verify all    # ce qui l'est vraiment
```

`verify` est la commande qui compte : `status` dit ce qui *devrait* être en place,
`verify` va regarder.

## La carte ne démarre plus / est instable

**Coupez l'alimentation.** Pas un redémarrage : débranchez. Les déblocages CU et cœurs
vivent en RAM et disparaissent à la coupure. Vous redémarrez sur une carte d'origine.

Ensuite, retirez ce qui a causé le problème avant de réarmer quoi que ce soit :

```sh
sudo bc250ctl revert cpu-oc
sudo bc250ctl revert cpu-cores
```

## Les fréquences GPU ne bougent pas

Le governor tourne mais ne fait rien : vérifiez d'abord qu'il est vraiment actif, puis
regardez la bonne carte. La BC-250 n'est pas forcément `card0`.

```sh
systemctl status cyan-skillfish-governor-smu
sudo bc250ctl verify governor      # résout la bonne carte tout seul
```

## `num_cu` reste à 24

Dans l'ordre :

1. `umr` est-il installé ? `bc250ctl doctor` le dit. S'il vient d'être superposé par
   `rpm-ostree`, il faut redémarrer puis relancer `sudo bc250ctl install gpu-cu`.
2. Le service de rejeu est-il là ? `systemctl status bc250-cu-live-manager.service`
3. La table de démarrage a-t-elle été enregistrée ?
   `cat /etc/bc250-cu-live-manager.conf`

## Plantages GPU après le déblocage 40 CU

Votre carte a probablement un WGP défectueux. Voir la section « Tester la santé des CU »
de [`validation.md`](validation.md) : isolez-le, puis passez sa référence dans
`BC250_GPU_WGP_LAYOUT` pour tourner en 38 ou 36 CU.

## Les CPU 12-15 n'ont pas de C-state

C'est le symptôme du déblocage des cœurs sans les tables ACPI reconstruites : quatre
threads qui ne peuvent jamais descendre en veille et consomment à vide.

```sh
cpupower -c all idle-info | grep -c 'Number of idle states: 0'   # doit valoir 0
sudo bc250ctl verify acpi
```

Si le compte n'est pas nul :

```sh
sudo bc250ctl install acpi
sudo systemctl reboot
```

Si ça persiste après redémarrage, GRUB ne charge pas l'archive :

```sh
grep GRUB_EARLY_INITRD /etc/default/grub     # la ligne doit être là
ls -l /boot/SSDT_ACPI.cpio                   # l'archive aussi
ujust regenerate-grub
```

## Les ventilateurs ne réagissent pas

`nct6683` ne sait que lire. Pour piloter le PWM il faut `nct6687`, et les deux ne peuvent
pas cohabiter :

```sh
sudo bc250ctl revert sensors
sudo bc250ctl install fan-control
sudo systemctl reboot
```

Si la consigne retombe à chaque redémarrage, c'est normal : le pilote ne la garde pas.
Soit CoolerControl gère la courbe (`BC250_FAN_PWM=auto`), soit vous fixez une valeur dans
`/etc/bc250ctl/config.env` et `bc250ctl` installe l'unité qui la repose au boot.

## « cannot be installed while ... is active »

Deux modules visent le même matériel. Le message donne la bascule à faire — c'est presque
toujours « bascule », pas « abandonne » :

```sh
sudo bc250ctl revert sensors && sudo bc250ctl install fan-control
```

## Erreurs SMN dans le journal du governor

Le governor et les écritures SMU partagent la fenêtre PCI `0xB8`/`0xBC`. `bc250ctl` met
le governor en pause autour de chaque écriture ; si vous lancez un outil amont
directement, faites-le vous-même :

```sh
sudo systemctl stop cyan-skillfish-governor-smu
# ... l'écriture SMU ...
sudo systemctl start cyan-skillfish-governor-smu
```

## `nproc` affiche encore 12

Normal juste après un démarrage à froid. Le masque de cœurs ne prend effet qu'au
redémarrage *suivant* celui où il a été armé :

```sh
systemctl status bc250ctl-cpu-cores.service   # doit être actif
sudo systemctl reboot
```

## Le bootstrap ne reprend pas après redémarrage

```sh
systemctl status bc250ctl-resume.service
journalctl -u bc250ctl-resume.service
```

Vous pouvez toujours continuer à la main : `sudo bc250ctl bootstrap` reprend là où il en
était. Après quatre passes sans aboutir, l'outil s'arrête volontairement plutôt que de
boucler ; c'est le signe qu'un module demande un redémarrage à chaque fois, et
`bc250ctl status` dira lequel.

## `checksum mismatch` au téléchargement

Un fichier amont a changé sous une URL épinglée. **Ne le lancez pas.** Regardez ce qui a
bougé :

```sh
bc250ctl sources --check
```

Puis mettez `sources.env` à jour délibérément, après avoir relu le diff amont.

## Les fréquences GPU affichées sont absurdes

Après le déblocage des huit cœurs, `pp_dpm_sclk` remonte des valeurs fausses. C'est un
défaut de remontée connu, pas une panne du governor : `bc250ctl verify governor` le
signale et ne le compte pas comme un échec. Lisez les fréquences avec `amdgpu_top` ou
`nvtop`.

## Erreur `this needs root`

Toutes les commandes qui modifient quelque chose demandent `sudo`. `status`, `modules`,
`doctor` et `sources` n'en ont pas besoin.

## L'outil dit qu'il ne trouve pas de BC-250

```sh
sudo bc250ctl doctor      # cherche le PCI 1002:13fe
```

Si la carte est bien une BC-250 et que la détection se trompe, `--force` passe outre —
mais vérifiez d'abord, parce que ces écritures de registres ne sont valides que sur ce
matériel.
