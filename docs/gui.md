# L'interface graphique

`bc250-gui` est une application GTK4 / libadwaita qui regroupe ce que fait
`bc250ctl` : voir ce qui est appliqué, l'installer, régler les paramètres,
surveiller la carte, et dérouler une première installation.

```sh
bc250-gui          # ou « BC-250 » dans le menu des applications
```

## Ce qu'elle ne contient pas

Aucun savoir métier. Ni la liste des modules, ni l'ordre d'application, ni les
dépendances, ni les plages de tension. Tout ça vient de `bc250ctl catalog --json`
et `bc250ctl config --json`. Un module ajouté à `modules/` apparaît dans
l'interface sans qu'une ligne de l'app change, et un garde-fou ajouté au moteur
s'applique aussi à l'interface.

Une seule exception assumée : les titres de section de la page Réglages, qui
traduisent un identifiant de module en intitulé lisible.

## Privilèges

`bc250ctl` a besoin de root ; l'application ne tourne jamais en root.

Le modèle habituel sous Fedora serait une action polkit dédiée, mais les
fichiers `.policy` doivent vivre dans `/usr/share/polkit-1/actions`, en lecture
seule sur une image ostree. En installer une supposerait de superposer un RPM
maison, donc un redémarrage pour installer une application.

L'app utilise donc `pkexec` sans policy : l'action par défaut
`org.freedesktop.policykit.exec` demande le mot de passe administrateur à
chaque appel élevé.

Ça dicte l'ergonomie : **le travail privilégié est regroupé**. Les réglages
s'éditent librement, se relisent sous forme de diff, et partent en **un seul**
appel — pas une invite par curseur déplacé. Installer un module dont les
dépendances manquent installe toute la chaîne en une fois.

La seule exception est la bascule entre `sensors` et `fan-control` : le moteur
refuse d'installer l'un tant que l'autre est en place, et c'est ce refus qui
protège la puce. L'app fait donc deux appels, et le dit avant.

## Les quatre pages

**Modules** — une ligne par module, avec son état (appliqué, désactivé, à
appliquer, bloqué, caduc, conflit) et, pour ceux qui comptent, une pastille de
risque. Une ligne bloquée dit ce qui lui manque ; une ligne en conflit dit avec
quoi. Le bouton d'installation compte la chaîne complète quand il y en a une.

**Réglages** — généré depuis le schéma du moteur : interrupteur, liste ou
compteur selon le type déclaré, groupé par module, avec l'aide de chaque
réglage. Le curseur de tension CPU s'arrête à 1275 mV ; aller au-delà demande
de lever explicitement le verrou, parce que le moteur refuserait de toute façon
et qu'une interface ne doit pas proposer une valeur qui sera rejetée.

**Supervision** — températures, fréquences, puissance, ventilation, avec une
minute d'historique. Ce qui ne peut pas être mesuré est dit comme tel : cette
carte n'a pas de sonde VRAM, et la fréquence GPU remontée devient fausse une
fois les 8 cœurs débloqués — l'app affiche l'avertissement plutôt qu'un chiffre
faux. Le sondage ne tourne que quand la page est visible.

**Installation** — l'assistant : diagnostic matériel, choix du profil avec ce
qu'il change, exécution avec la sortie visible. Il survit aux redémarrages :
si une installation est en cours, l'app propose de reprendre.

## Dépendances

`python3-gobject`, `gtk4` et `libadwaita`. Présents sur une image Bazzite GNOME,
pas garantis ailleurs. `install.sh` le vérifie et, au besoin, donne la commande :

```sh
rpm-ostree install python3-gobject gtk4 libadwaita
systemctl reboot
```

L'application refait ce contrôle au lancement et affiche la même chose plutôt
qu'une trace Python.

Rien d'autre n'est requis : les graphiques sont dessinés avec `snapshot` et non
avec cairo, précisément pour ne pas dépendre d'un paquet de plus.

## Développement

```sh
xvfb-run -a python3 -m pytest gui/tests/ -q      # 55 tests
```

Les tests pilotent le **vrai** `bc250ctl` dans un préfixe bac à sable, avec les
mêmes commandes système simulées que la suite bats : ni BC-250, ni root, ni
réseau. Les tests qui ont besoin de GTK se désactivent proprement là où il
n'est pas disponible.

Deux d'entre eux méritent d'être connus, parce qu'ils empêchent l'interface de
prendre du retard sur le moteur :

- le formulaire généré est comparé à la liste des réglages publiés par
  `config --json` — un réglage ajouté au moteur et absent de l'UI fait échouer
  la suite ;
- les plafonds proposés par les curseurs de tension sont comparés à ceux que le
  moteur applique, et un test vérifie que chaque réglage plafonné de l'interface
  existe encore dans le schéma.

`BC250CTL=/chemin/vers/bc250ctl` force le moteur utilisé ; sinon l'app prend
celui du dépôt s'il est à côté, puis celui du `PATH`.
