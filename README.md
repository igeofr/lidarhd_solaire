# Cadastre solaire à partir de données LiDAR HD

Chaîne de traitement en Bash pour générer un **cadastre solaire** (potentiel
photovoltaïque des toitures) à partir de dalles LiDAR, en s'appuyant sur
**PDAL**, **GDAL** et **GRASS GIS** (`r.sun`).

Le calcul reconstitue le relief (bâtiments, végétation, terrain), simule le
rayonnement solaire reçu par chaque toiture sur l'année en tenant compte de
l'orientation, de l'inclinaison et des ombres portées, puis classe les toitures
par niveau de potentiel et produit une couche vecteur attribuée par bâtiment.

Paramètres calés par défaut sur **Lunel (Hérault, zone climatique H3)**.

---

## Sommaire

- [Fonctionnalités](#fonctionnalités)
- [Dépendances](#dépendances)
- [Installation](#installation)
- [Utilisation rapide](#utilisation-rapide)
- [Options](#options)
- [Modes de fonctionnement](#modes-de-fonctionnement)
- [Sorties](#sorties)
- [Classes de potentiel](#classes-de-potentiel)
- [Attributs par bâtiment (GeoPackage)](#attributs-par-bâtiment-geopackage)
- [Calibration](#calibration)
- [Reprise et parallélisme](#reprise-et-parallélisme)
- [Import PostGIS et vue de pourcentages](#import-postgis-et-vue-de-pourcentages)
- [Notes et limites](#notes-et-limites)

---

## Fonctionnalités

- Traitement **tuile par tuile** avec zone tampon (buffer) inter-tuiles pour un
  ombrage correct en bordure, à mémoire quasi constante (calcul en flux).
- Reconstruction automatique de l'emprise de chaque dalle depuis son **nom IGN**
  (`LHD_FXX_XXXX_YYYY_...`).
- Rayonnement solaire annuel via `r.sun` avec **trouble de Linke mensuel** et
  ombrage porté (`r.horizon`), recadrage exact des tuiles (raccords nets).
- Masquage du résultat sur les **toitures** : depuis la classification LiDAR
  (classe 6) et/ou un vecteur d'emprises bâties.
- **Statistiques zonales par bâtiment** (irradiation, surface, énergie, surface
  par classe) exportées en GeoPackage.
- **Téléchargement automatique** des dalles depuis geopf.fr à partir d'un
  vecteur de sélection, avec purge à la demande pour les vastes territoires.
- **Reprise sur incident** (les tuiles déjà calculées sont ignorées).

---

## Dépendances

- `pdal`
- `grass` (>= 7.8, avec `r.sun`, `r.horizon`, `v.rast.stats`)
- `gdal` : `gdalinfo`, `gdalbuildvrt`, `gdal_translate`, `gdal_rasterize`,
  `gdaldem`, `gdalwarp`, `gdal_fillnodata`, `gdal_calc`, `ogr2ogr`, `ogrinfo`
- `wget` ou `curl` (uniquement pour le mode téléchargement `-S`)
- `awk`, `find`, Bash >= 4

Les dalles d'entrée sont supposées en **Lambert-93 (EPSG:2154)**, format des
LiDAR HD de l'IGN.

---

## Installation

```bash
chmod +x cadastre_solaire.sh
```

Vérifier que les dépendances sont accessibles dans le `PATH` (le script s'arrête
avec un message clair si l'une manque).

---

## Utilisation rapide

À partir d'un dossier local de dalles :

```bash
./cadastre_solaire.sh -i ./dalles_ign -o ./data_out -c -j 4
```

À partir d'un vecteur listant les dalles à télécharger (champ `url` = URL
complète de chaque dalle) et d'une couche de bâtiments pour le croisement :

```bash
./cadastre_solaire.sh \
  -S dalle_lidarhd.shp -F url \
  -b batiment_lidar.shp \
  -o ./data_out \
  -j 4
```

Vaste territoire à disque limité (téléchargement à la demande + purge) :

```bash
./cadastre_solaire.sh -S dalle_lidarhd.shp -F url -b batiment_lidar.shp -o ./data_out -x
```

---

## Options

| Option | Description | Défaut |
|--------|-------------|--------|
| `-i` | Dossier de dalles LiDAR (`.laz`/`.las`/`.copc.laz`) | *(requis sauf `-S`)* |
| `-o` | Dossier de sortie | `./cadastre_solaire_out` |
| `-e` | Code EPSG cible (garder 2154 pour l'IGN) | `2154` |
| `-r` | Résolution des rasters (m) | `1.0` |
| `-s` | Pas d'échantillonnage annuel de `r.sun` (jours) | `15` |
| `-H` | Pas angulaire du calcul d'horizon (degrés) | `30` |
| `-l` | Trouble de Linke **constant** (désactive le mensuel) | — |
| `-L` | Trouble de Linke **mensuel** `"j f m a m j j a s o n d"` | valeurs méditerranéennes |
| `-a` | Albédo | `0.2` |
| `-K` | Coefficient ciel réel (1.0 = ciel clair `r.sun`) | `1.0` |
| `-C` | Seuils de classe `"T1 T2 T3"` (kWh/m²/an) | `1450 1700 1950` |
| `-B` | Buffer inter-tuiles (m) | `250` |
| `-T` | Taille de dalle (m) | `1000` |
| `-b` | Vecteur d'emprises bâties (masque + croisement) | — |
| `-c` | Masque bâti depuis la classification LiDAR (classe 6) | désactivé |
| `-j` | Tuiles traitées en parallèle | `1` |
| `-S` | Vecteur des dalles à télécharger depuis geopf.fr | — |
| `-F` | Champ contenant le nom de fichier ou l'URL de la dalle | `nom_pkk` |
| `-U` | URL de base (dossier de livraison IGN) si `-F` = nom de fichier | — |
| `-D` | Dossier cache des dalles téléchargées | `OUTDIR/dalles_cache` |
| `-P` | Téléchargements en parallèle | `4` |
| `-g` | Classer le sol (SMRF) si le nuage n'est pas classé | désactivé |
| `-O` | Filtre outlier statistique (coûteux en RAM) | désactivé |
| `-m` | `r.sun` en mode faible mémoire | désactivé |
| `-x` | Purger chaque dalle après usage (mode `-S`, disque limité) | désactivé |
| `-k` | Conserver les fichiers temporaires | désactivé |
| `-R` | Tout recalculer (ignorer la reprise) | désactivé |
| `-h` | Aide | — |

---

## Modes de fonctionnement

### Entrée locale (`-i`)
Traite les dalles présentes dans un dossier. Les dalles voisines doivent être
présentes pour un ombrage de bordure correct.

### Téléchargement depuis un vecteur (`-S`)
Lit le champ `-F` d'un vecteur de dalles et télécharge depuis geopf.fr :

- si les valeurs sont des **URLs** (`http…`), elles sont utilisées telles quelles
  (idéal pour un territoire couvrant plusieurs blocs d'acquisition) ;
- si ce sont des **noms de fichiers**, fournir `-U` (dossier de livraison IGN
  d'un même bloc).

Les dalles arrivent avec le nom IGN standard : le reste de la chaîne est
inchangé. Prévoir une **couronne d'une dalle** autour de la zone utile pour que
l'ombrage de bordure dispose des voisines.

### Purge (`-x`, avec `-S`)
Télécharge à la demande, traite séquentiellement et supprime chaque dalle dès
qu'aucune tuile restante n'en a besoin (comptage de références). L'occupation
disque reste limitée à la fenêtre de voisinage. Le traitement est séquentiel
(`-j` sans effet) ; les dalles sont balayées en ordre géographique serpentin.

---

## Sorties

Dans le dossier `-o` :

| Fichier | Contenu | Unité |
|---------|---------|-------|
| `mns.tif` | Modèle Numérique de Surface | m |
| `mnt.tif` | Modèle Numérique de Terrain | m |
| `irradiation_annuelle.tif` | Rayonnement global annuel | kWh/m²/an |
| `cadastre_solaire_toitures.tif` | Irradiation limitée aux toitures *(si masque)* | kWh/m²/an |
| `masque_bati_lidar.tif` | Masque bâti classe 6 *(si `-c`)* | 1 = bâti |
| `cadastre_solaire_classe.tif` | Potentiel classé | 1–4 |
| `cadastre_solaire_classe_couleur.tif` | Classes colorisées (RGBA) | — |
| `cadastre_solaire_couleur.tif` | Irradiation colorisée (RGBA) | — |
| `cadastre_solaire_batiments.gpkg` | Bâtiments attribués *(si `-b`)* | — |

Dossiers intermédiaires : `tuiles_irr/`, `tuiles_mns/`, `tuiles_mnt/`,
`tuiles_bati/`, `tuiles_done/` (marqueurs de reprise), `dalles_cache/` (mode `-S`).

---

## Classes de potentiel

Seuils par défaut (option `-C`), en kWh/m²/an :

| Classe | Niveau | Plage | Couleur |
|--------|--------|-------|---------|
| 1 | Faible | < 1450 | jaune |
| 2 | Moyen | 1450 – 1700 | orange clair |
| 3 | Bon | 1700 – 1950 | rouge |
| 4 | Excellent | ≥ 1950 | violet |

Ces seuils ont été calés sur l'histogramme de Lunel (moyenne ≈ 1709,
écart-type ≈ 393). À recaler sur la distribution locale via `-C`.

---

## Attributs par bâtiment (GeoPackage)

En plus des attributs d'origine du vecteur bâti et de la géométrie :

| Colonne | Description | Unité |
|---------|-------------|-------|
| `irr_number` | Nombre de pixels de toiture | — |
| `irr_minimum` / `irr_maximum` | Irradiation min / max | kWh/m²/an |
| `irr_average` | Irradiation moyenne (indicateur principal) | kWh/m²/an |
| `irr_stddev` | Écart-type (hétérogénéité du toit) | kWh/m²/an |
| `irr_sum` | Somme brute des pixels (intermédiaire) | — |
| `cls1_number` … `cls4_number` | Nombre de pixels par classe | — |
| `surf_toit_m2` | Surface de toiture utile | m² |
| `nrj_kwh_an` | Énergie solaire **incidente** annuelle | kWh/an |
| `surf_cl1_m2` … `surf_cl4_m2` | Surface par classe | m² |

Contrôle de cohérence : `surf_cl1_m2 + … + surf_cl4_m2 = surf_toit_m2`.

> `nrj_kwh_an` est l'énergie **incidente**, pas la production photovoltaïque
> (compter ~12–15 % pour un productible). Les surfaces dépendent de la
> résolution `-r` (aire d'un pixel = `r²`).

---

## Calibration

- **Latitude** : gérée automatiquement par `r.sun` via le géoréférencement.
- **Trouble de Linke** : mensuel par défaut (climat méditerranéen). À affiner
  sur soda-pro.com pour les coordonnées exactes, via `-L`.
- **Ciel clair vs ciel réel** : `r.sun` ne modélise pas les nuages, ses valeurs
  sont ~15–20 % au-dessus des mesures. Pour se rapprocher du réel, appliquer un
  coefficient `-K` (~0.83 à Lunel) **plutôt que** de fausser le Linke. Si `-K`
  est activé, rescaler les seuils `-C` d'autant (ou relancer l'histogramme).
- **Seuils de classe** : vérifier la distribution réelle après un premier
  passage — `gdalinfo -hist cadastre_solaire_toitures.tif` — et ajuster `-C`.

Tout changement affectant le calcul solaire (`-K`, `-s`, `-B`, Linke) impose de
recalculer avec `-R` ; les paramètres d'aval (`-C`, masque, stats zonales)
peuvent être rejoués sans recalcul.

---

## Reprise et parallélisme

- **Reprise** : chaque tuile terminée dépose un marqueur dans `tuiles_done/`.
  Une relance ignore les tuiles déjà calculées et vérifie l'intégrité GDAL du
  raster (détecte un fichier tronqué). Forcer le recalcul avec `-R`.
- **Parallélisme** : les tuiles (`-j`) et les téléchargements (`-P`) sont
  parallélisés, chaque tuile ayant sa propre location GRASS isolée. Le mode
  purge (`-x`) est séquentiel.
- **Mémoire** : garder `-j` raisonnable ; `r.sun` en mode `-m` et un buffer `-B`
  plus faible réduisent la consommation en cas de saturation.

---

## Import PostGIS et vue de pourcentages

Import du GeoPackage dans PostGIS :

```bash
ogr2ogr -f PostgreSQL "PG:dbname=... user=..." cadastre_solaire_batiments.gpkg \
    -nln energie.cadastre_solaire_batiments -lco GEOMETRY_NAME=geom -nlt POLYGON
```

Vue ajoutant le pourcentage de surface par classe et la classe dominante :

```sql
CREATE OR REPLACE VIEW energie.v_cadastre_solaire_batiments AS
SELECT
    b.*,
    ROUND((100.0 * COALESCE(b.surf_cl1_m2,0) / d.tot)::numeric, 1) AS pct_cl1,
    ROUND((100.0 * COALESCE(b.surf_cl2_m2,0) / d.tot)::numeric, 1) AS pct_cl2,
    ROUND((100.0 * COALESCE(b.surf_cl3_m2,0) / d.tot)::numeric, 1) AS pct_cl3,
    ROUND((100.0 * COALESCE(b.surf_cl4_m2,0) / d.tot)::numeric, 1) AS pct_cl4
FROM energie.cadastre_solaire_batiments b
CROSS JOIN LATERAL (
    SELECT NULLIF(COALESCE(b.surf_cl1_m2,0) + COALESCE(b.surf_cl2_m2,0)
               + COALESCE(b.surf_cl3_m2,0) + COALESCE(b.surf_cl4_m2,0), 0) AS tot
) d;
```

---

## Notes et limites

- **Estimation indicative**, pas un diagnostic : mesure l'énergie solaire reçue,
  pas la production réelle d'une installation (matériel, surface équipable,
  raccordement, réglementation).
- Le MNS inclut **toute** la surface (végétation comprise) pour un ombrage
  correct ; le masque ne restreint que le **résultat** aux toitures.
- Le tuilage suppose des dalles **IGN en Lambert-93** nommées selon la
  convention standard.
- Sur données non classées, utiliser `-g` (sol par SMRF), `-O` (bruit) et un
  masque vecteur `-b` (la classe 6 étant absente).
- Vérifier la classification d'une dalle :
  `pdal info --stats <dalle>.copc.laz | grep -A3 Classification`
  (le maximum de `Classification` doit atteindre 6).
