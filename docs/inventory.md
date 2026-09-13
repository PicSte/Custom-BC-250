# L'écosystème BC-250 : ce qu'on gère, et pourquoi

Inventaire des outils, correctifs et contournements qui existent pour la carte, avec la
décision prise pour chacun. Il sert de base à l'interface graphique : ce qui est géré ici
est ce que la GUI pourra piloter.

## Géré

| Outil / correctif | Amont | Module |
|---|---|---|
| Governor GPU | [`filippor/cyan-skillfish-governor`](https://github.com/filippor/cyan-skillfish-governor) (COPR `filippor/bazzite`) | `governor` |
| 40 CU + routage WGP | [`WinnieLV/bc250-cu-live-manager`](https://github.com/WinnieLV/bc250-cu-live-manager) | `gpu-cu` |
| Déblocage 8 cœurs | idem, sous-commande `cpu-unlock` | `cpu-cores` |
| Tables ACPI reconstruites | [`mendesrr/bc250-acpi-fix-updated-8c`](https://github.com/mendesrr/bc250-acpi-fix-updated-8c) | `acpi` |
| OC / UV CPU | [`bc250-collective/bc250_smu_oc`](https://github.com/bc250-collective/bc250_smu_oc) | `cpu-oc` |
| Températures | `nct6683` (dans le noyau) | `sensors` |
| Ventilation PWM | [`Fred78290/nct6687d`](https://github.com/Fred78290/nct6687d) (akmod Bazzite) | `fan-control` |
| Limites mémoire TTM | documentation amont | `kargs` |
| `mitigations=off` | — | `kargs` |
| Forçage DisplayPort | — | `kargs` (`video=DP-1:e`) |
| Micro-saccades `hhd` | — | `fixes` |
| Veille cassée | — | `fixes` |
| ZRAM et plantages de jeux | — | `fixes` |
| Configuration RADV | `/etc/drirc` | `radv` |
| Governor CPU | — | `acpi` |
| zswap et swappiness | — | `kargs`, `fixes` |
| Versions noyau / Mesa / IOMMU / audio DP | — | `doctor` (diagnostic seul) |

## Non géré, et la raison

**[`fanoush/bc250_memcfg`](https://github.com/fanoush/bc250_memcfg)** — écrit la CMOS
sauvegardée par pile : taille de la VRAM (`UMA_SIZE`) et timings mémoire. `UMA_SIZE` est
réellement utile et éviterait un passage par le BIOS. Les timings, d'après l'amont
lui-même, n'ont « aucun gain confirmé » et peuvent déstabiliser la machine. Candidat
sérieux pour une v2, en lecture d'abord.

**`skillfish-dp-hotswap`** — démon qui force la détection DisplayPort au démarrage et
surveille les changements à chaud, le HPD étant cassé sur cette carte. Il vient de
SkillFishOS et n'a pas été vérifié ailleurs. En attendant, `kargs` propose le karg
`video=DP-1:e`, qui traite le cas du démarrage sans écran détecté.

**BIOS moddé** ([`Forbidden-Darkness/...UEFI-v2.2...`](https://github.com/Forbidden-Darkness/AMD-BC-250-UEFI-v2.2-Firmware-Menu-Script),
`MeiMeiDXE-T-v2` avec `Bc250CoreUnlockDxe`) — rend le déblocage des cœurs permanent, mais
flashe le bootblock, suppose un firmware P3.00, et demande un programmateur matériel avec
une sauvegarde vérifiée. Un outil qui automatise ça transforme une erreur de manipulation
en carte morte. Documenté, jamais automatisé.

**[`rw-r-r-0644/bc250-core-unlock`](https://github.com/rw-r-r-0644/bc250-core-unlock)** et
**[`GabriWar/bc250-core-cu-unlock`](https://github.com/GabriWar/bc250-core-cu-unlock)** —
font la même chose que `bc250-cu-live-manager cpu-unlock`. Une seule source de vérité vaut
mieux que trois chemins qui divergent.

**[`duggasco/bc250-40cu-unlock`](https://github.com/duggasco/bc250-40cu-unlock)** — la
recherche d'origine sur les registres 40 CU, et tout part de là. Mais la méthode
recompile le module `amdgpu`, donc elle casse à chaque mise à jour de noyau. Bazzite se
met à jour souvent. On garde la voie runtime.

**SkillFishOS** — une distribution complète pour la BC-250. C'est une alternative à
Bazzite, pas un outil à intégrer.

**[`simpmix/bc250-encoding-decoding-fix`](https://github.com/simpmix/bc250-encoding-decoding-fix)**
— pilote VA-API qui fait l'encodage H.264 en shaders de calcul Vulkan. La carte n'a pas
de firmware VCN, donc ce n'est pas un correctif mais une **capacité nouvelle** : de
l'encodage matériel là où il n'y en avait aucun. Sérieux candidat si tu streames
(Sunshine, OBS). Pas encore géré parce qu'il remplace un pilote graphique et mérite
d'être évalué sur matériel avant d'être proposé.

**`rpf16rj/bc250-steamos-real-toolkit`** — équivalent pour SteamOS. Même terrain,
autre distribution.

**Le correctif d'horloge audio DisplayPort** — le firmware programme le DTO audio pour
une référence à 728,631 MHz alors que la carte tourne à 600 MHz : le son sort à 82,3 %
de sa vitesse, ou pas du tout à travers un adaptateur actif. **Corrigé en amont dans
Linux 6.19.10+.** En dessous, il faudrait un service qui réécrit le registre après
chaque modeset. `doctor` signale le cas ; on ne gère pas le contournement parce que la
vraie réponse est un noyau à jour, un adaptateur passif ou un DAC USB.

**`nvtop`, `amdgpu_top`, `radeontop`** — de la supervision. C'est précisément ce que
l'interface graphique fera elle-même ; en faire des modules reviendrait à installer des
outils pour afficher ce que la GUI affiche déjà.

**`RADV_DEBUG=nohiz`** — option de lancement Steam, par jeu. Ce n'est pas de la
configuration système.

**Adaptateur DP→HDMI passif, DAC USB, WiFi USB** — du matériel. La documentation les
mentionne, l'outil ne peut rien en faire.

## Ce que l'inventaire a corrigé

### Deuxième passe, sur la documentation complète

Une relecture des 39 pages de [`amd-bc250-docs`](https://elektricm.github.io/amd-bc250-docs/)
a mis au jour un défaut de sécurité chez nous et trois manques :

1. **Le plafond de tension GPU était trop haut.** Notre schéma autorisait 1200 mV alors
   que la documentation fixe l'usage courant à 1100 mV et le maximum absolu à 1150 mV.
   On avait soigné les garde-fous CPU et laissé passer le GPU.
2. **Aucun governor CPU** n'était posé après le correctif ACPI : on installait la
   capacité `cpufreq` sans jamais s'en servir.
3. **Le correctif ZRAM était incomplet** : on coupait le swap compressé sans rien mettre
   à la place, ce qui laisse la carte sans swap du tout.
4. **`/etc/drirc` et `amdgpu.gttsize`** manquaient, tous deux pour la mémoire partagée.

### Première passe, sur le graphe de dépendances

Deux défauts dans la première version, trouvés en établissant le graphe :

1. **Contention SMU.** Le governor et les écritures SMU (déblocage des cœurs, overclock)
   passent par la même fenêtre PCI index/data, registres `0xB8`/`0xBC` du device
   `00:00.0`. Sans arbitrage, un accès concurrent lit et écrit à de mauvaises adresses
   SMN. `lib/smu.sh` arrête désormais le governor autour de chaque écriture.
2. **Dépendance ACPI manquante.** Le déblocage des cœurs était livré sans les tables
   SSDT reconstruites : les CPU 12-15 démarraient sans aucun C-state. `cpu-cores` exige
   maintenant `acpi`.
