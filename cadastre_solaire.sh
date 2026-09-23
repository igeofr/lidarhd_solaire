#!/usr/bin/env bash
###############################################################################
# cadastre_solaire.sh  —  version TUILES
#
# Génération d'un CADASTRE SOLAIRE à partir de dalles LiDAR HD IGN (LAS/LAZ/COPC),
# traitées TUILE PAR TUILE avec zone tampon (buffer) inter-tuiles pour un calcul
# d'ombrage correct en bordure.
#
# Paramètres solaires calés par défaut sur LUNEL (Hérault, zone climatique H3) :
#   - trouble de Linke MENSUEL de type littoral méditerranéen ;
#   - seuils de classification relevés (gisement élevé, ~900–2000 kWh/m²/an).
# La latitude (~43,7°N) est déduite automatiquement par r.sun du géoréférencement.
#
# Chaîne, pour chaque dalle km² :
#   0. Emprise reconstruite depuis le nom IGN  (ex: ..._0770_6278_...)
#      -> XMIN=770000  YMAX=6278000  XMAX=771000  YMIN=6277000  (dalle de 1 km)
#   1. PDAL  : lecture des points dans l'emprise BUFFERISÉE (dalle + voisines)
#              -> MNS (DSM) bufferisé  ;  MNT (DTM) à l'emprise exacte
#   2. GDAL  : comblement des NoData
#   3. GRASS : pente/exposition (r.slope.aspect), horizon (r.horizon),
#              irradiation annuelle (r.sun) sur l'emprise BUFFERISÉE,
#              puis RECADRAGE à l'emprise EXACTE avant export (raccords nets)
#   4. Mosaïquage des tuiles -> masquage bâti -> classification -> colorisation
#
# Le buffer garantit que les ombres portées par le bâti/relief des dalles
# voisines sont prises en compte, sans discontinuité aux jonctions.
#
# Dépendances : pdal, gdal (gdalbuildvrt, gdal_translate, gdal_rasterize,
#               gdal_calc(.py), gdaldem, gdalinfo, gdal_fillnodata),
#               grass (>= 7.8), awk, find, bash >= 4
#
# Usage :
#   ./cadastre_solaire.sh -i ./dalles_ign -o ./sortie \
#        -r 1.0 -s 15 -B 250 -j 4 -b batiments.gpkg
#
###############################################################################

set -euo pipefail

# Locale numérique neutre : impose le POINT comme séparateur décimal.
# Sans cela, en environnement français (fr_FR), awk/printf produisent une
# VIRGULE (ex: rayon "1,500"), ce qui casse le JSON PDAL et perturbe GDAL/GRASS.
export LC_ALL=C

# ----------------------------------------------------------------------------
# Valeurs par défaut
# ----------------------------------------------------------------------------
: "${INPUT:=}"                          # -i : dossier de dalles (ou 1 fichier)
: "${OUTDIR:=./cadastre_solaire_out}"   # -o : dossier de sortie
: "${EPSG:=2154}"                       # -e : SRC cible (2154 = Lambert-93)
: "${RES:=1.0}"                         # -r : résolution raster (m)
: "${DAY_STEP:=15}"                     # -s : pas annuel (jours) pour r.sun
: "${HORIZON_STEP:=30}"                 # -H : pas angulaire horizon (deg)
: "${LINKE:=3.6}"                       # -l : trouble de Linke CONSTANT (moy. annuelle Lunel)
# Trouble de Linke MENSUEL (jan..déc) — valeurs typiques du littoral méditerranéen
# (zone H3, Lunel/Hérault) : plus élevé l'été (humidité + aérosols marins).
# À affiner sur soda-pro.com (climatologie Linke ESRA) pour les coordonnées exactes.
: "${LINKE_MONTHLY:=2.8 3.0 3.4 3.8 4.1 4.4 4.5 4.5 4.0 3.4 3.0 2.7}"
: "${MONTHLY_LINKE:=1}"                  # 1 = Linke mensuel ; l'option -l force le constant
: "${ALBEDO:=0.2}"                      # -a : albédo
# Coefficient CIEL RÉEL appliqué à l'irradiation (défaut 1.0 = ciel clair r.sun).
# r.sun ne modélise pas les nuages : ses valeurs sont ~15-20 % au-dessus des
# mesures. Pour se rapprocher du réel/PVGIS à Lunel, ~0.82-0.85. NB : si vous
# l'activez, rescalez les seuils -C d'autant (ou relancez l'histogramme).
: "${REALSKY:=1.0}"                     # -K : coefficient ciel réel
# Seuils de classe (kWh/m²/an) recalés sur l'histogramme de Lunel (quartiles :
# moy 1709, éc-type 393) : <T1 Faible | T1..T2 Moyen | T2..T3 Bon | >=T3 Excellent
: "${CLASS_THRESHOLDS:=1450 1700 1950}"
: "${BUFFER:=250}"                      # -B : buffer inter-tuiles (m)
: "${TILE_SIZE:=1000}"                  # -T : taille de dalle IGN (m)
: "${BUILDINGS:=}"                      # -b : emprises bâties (vecteur, option)
: "${MASK_CLASS6:=0}"                   # -c : masque bâti depuis la classif. LiDAR (classe 6)
: "${CLASSIFY_GROUND:=0}"              # -g : classer le sol (SMRF) si non classé
: "${OUTLIER:=0}"                       # -O : filtre outlier statistique (coûteux RAM)
: "${LOWMEM:=0}"                        # -m : r.sun en mode faible mémoire
: "${JOBS:=1}"                          # -j : nombre de tuiles en parallèle
: "${KEEP_TMP:=0}"                      # -k : conserver les fichiers temporaires
# --- Mode téléchargement depuis un vecteur de dalles IGN (geopf.fr) ---
: "${SEL_SHP:=}"                        # -S : vecteur des dalles à télécharger
: "${SEL_FIELD:=nom_pkk}"               # -F : champ contenant le nom de fichier ou l'URL
: "${BASEURL:=}"                        # -U : URL de base (dossier de livraison IGN)
: "${CACHE_DIR:=}"                      # -D : dossier cache des dalles (défaut OUTDIR/dalles_cache)
: "${DL_JOBS:=4}"                       # -P : téléchargements en parallèle
: "${PURGE:=0}"                         # -x : purger chaque dalle après usage (mode -S)
: "${FORCE:=0}"                         # -R : tout recalculer (ignorer la reprise)
# ----------------------------------------------------------------------------
# Utilitaires génériques
# ----------------------------------------------------------------------------
log()  { printf '\033[1;32m[%(%H:%M:%S)T] %s\033[0m\n' -1 "$*"; }
warn() { printf '\033[1;33m[%(%H:%M:%S)T] %s\033[0m\n' -1 "$*" >&2; }
die()  { printf '\033[1;31m[%(%H:%M:%S)T] ERREUR : %s\033[0m\n' -1 "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "Dépendance manquante : $1"; }

# ============================================================================
# GÉOMÉTRIE DES TUILES
# ============================================================================

# Reconstruit l'emprise EXACTE d'une dalle depuis son nom IGN.
# Le nom contient un couple kilométrique "XXXX_YYYY" (coin haut-gauche, en km) :
#   XMIN = XXXX*1000  ;  YMAX = YYYY*1000  ;  dalle de TILE_SIZE de côté.
# Écrit "CODE XMIN YMIN XMAX YMAX" sur stdout, ou retourne 1 si illisible.
tile_extent_from_name() {
    local basename="$1"
    local size="${TILE_SIZE:-1000}"
    local tile_x="" tile_y="" fallback_x="" fallback_y="" xmin ymax xmax ymin

    # ========================================================
    # RECONSTRUCTION EMPRISE IGN
    # Un nom peut contenir un millésime (ex: "Semis_2021_0801_6300...").
    # On liste les nombres dans l'ordre et on retient le couple consécutif
    # (X,Y) de 4 chiffres dont Y est un northing Lambert-93 plausible
    # (6000–7200 km, France métropolitaine). Sinon, 1er couple 4_4 par défaut.
    # ========================================================
    local -a nums
    mapfile -t nums < <(printf '%s\n' "$basename" | grep -oE '[0-9]+')
    local i a b yv
    for ((i=0; i+1 < ${#nums[@]}; i++)); do
        a="${nums[i]}"; b="${nums[i+1]}"
        [ "${#a}" -eq 4 ] && [ "${#b}" -eq 4 ] || continue
        [ -z "$fallback_x" ] && { fallback_x="$a"; fallback_y="$b"; }
        yv=$((10#$b))
        if [ "$yv" -ge 6000 ] && [ "$yv" -le 7200 ]; then
            tile_x="$a"; tile_y="$b"; break
        fi
    done
    [ -z "$tile_x" ] && { tile_x="$fallback_x"; tile_y="$fallback_y"; }
    if [ -z "$tile_x" ] || [ -z "$tile_y" ]; then
        return 1
    fi
    # 10# force la base décimale (évite l'interprétation octale de "0770").
    xmin=$((10#$tile_x * 1000))
    ymax=$((10#$tile_y * 1000))
    xmax=$((xmin + size))
    ymin=$((ymax - size))

    printf '%s_%s %d %d %d %d\n' "$tile_x" "$tile_y" "$xmin" "$ymin" "$xmax" "$ymax"
}

# Test d'intersection de deux rectangles (coordonnées entières).
# boxes_intersect ax0 ay0 ax1 ay1 bx0 by0 bx1 by1  -> code retour 0 si intersection
boxes_intersect() {
    local ax0="$1" ay0="$2" ax1="$3" ay1="$4" bx0="$5" by0="$6" bx1="$7" by1="$8"
    [ "$ax0" -lt "$bx1" ] && [ "$ax1" -gt "$bx0" ] \
        && [ "$ay0" -lt "$by1" ] && [ "$ay1" -gt "$by0" ]
}

# ============================================================================
# CONSTRUCTION DES PIPELINES PDAL
# ============================================================================

# Génère un JSON PDAL de mise en grille.
#   $1 sortie tif | $2 output_type (max/idw/count) | $3..$6 bornes
#   $7 mode : surface (tout sauf bruit) | ground (classe 2) | building (classe 6)
#   $8.. fichiers
build_pdal_json() {
    local out_tif="$1" otype="$2" bx0="$3" by0="$4" bx1="$5" by1="$6" mode="$7"
    shift 7
    local files=("$@")
    local bounds="([$bx0,$bx1],[$by0,$by1])"
    # Pour un masque bâti on ne veut PAS dilater l'emprise -> rayon nul.
    local rad="${RADIUS}"; [ "$mode" = "building" ] && rad=0

    local f
    echo '{'
    echo '  "pipeline": ['
    for f in "${files[@]}"; do
        case "$f" in
            # Dalles COPC (IGN LiDAR HD) : lecture spatiale indexée via bounds.
            *.copc.laz|*.copc.LAZ|*.COPC.LAZ)
                printf '    {"type":"readers.copc","filename":"%s","bounds":"%s"},\n' \
                    "$f" "$bounds" ;;
            # LAS/LAZ classiques : pas de bounds sur le lecteur (non supporté).
            *)
                printf '    {"type":"readers.las","filename":"%s"},\n' "$f" ;;
        esac
    done
    # Recadrage universel à l'emprise (indispensable pour readers.las, sûr pour
    # COPC). Réalisé dans le SRC natif (Lambert-93) avant reprojection.
    printf '    {"type":"filters.crop","bounds":"%s"},\n' "$bounds"
    printf '    {"type":"filters.reprojection","out_srs":"EPSG:%s"},\n' "${EPSG}"
    case "$mode" in
        surface)   # toutes surfaces (bâti + VÉGÉTATION + sol) pour l'ombrage
            # Par défaut : suppression du bruit par la CLASSIFICATION seule
            # (classes 7 bas + 18 haut). Pipeline STREAMABLE -> mémoire quasi
            # constante, indispensable avec buffer + dalles voisines.
            # -O ajoute filters.outlier (statistique) : NON streamable, très
            # gourmand en RAM, à réserver aux nuages peu/mal classés.
            [ "${OUTLIER:-0}" = "1" ] && \
                printf '    {"type":"filters.outlier","method":"statistical","mean_k":8,"multiplier":2.5},\n'
            printf '    {"type":"filters.range","limits":"Classification![7:7],Classification![18:18]"},\n' ;;
        ground)    # sol nu (classe 2)
            [ "${CLASSIFY_GROUND:-0}" = "1" ] && printf '    {"type":"filters.smrf"},\n'
            printf '    {"type":"filters.range","limits":"Classification[2:2]"},\n' ;;
        building)  # bâtiments uniquement (classe 6) -> masque toitures
            printf '    {"type":"filters.range","limits":"Classification[6:6]"},\n' ;;
    esac
    # Grille de sortie IMPOSÉE explicitement. PDAL refuse 'bounds' EN MÊME TEMPS
    # que origin_x/origin_y/width/height : on ne garde que ces derniers, qui
    # définissent la grille sans ambiguïté (pas d'off-by-one selon les versions).
    # 'bounds' reste utilisé en amont par readers.copc et filters.crop.
    local w h
    w=$(awk "BEGIN{printf \"%d\", ($bx1-$bx0)/$RES + 0.5}")
    h=$(awk "BEGIN{printf \"%d\", ($by1-$by0)/$RES + 0.5}")
    printf '    {"type":"writers.gdal","filename":"%s","resolution":%s,' \
        "$out_tif" "${RES}"
    printf '"origin_x":%s,"origin_y":%s,"width":%s,"height":%s,' "$bx0" "$by0" "$w" "$h"
    printf '"output_type":"%s","gdaldriver":"GTiff","data_type":"float32",' "$otype"
    printf '"nodata":-9999,"radius":%s}\n' "$rad"
    echo '  ]'
    echo '}'
}

# Force un raster sur la grille EXACTE de la dalle (origine, taille, résolution).
# Garde-fou contre les décalages/off-by-one de writers.gdal selon les versions
# de PDAL : garantit des tuiles jointives, sans chevauchement ni trou.
snap_grid() { # in out xmin ymin xmax ymax
    local in="$1" out="$2" x0="$3" y0="$4" x1="$5" y1="$6"
    gdalwarp -q -overwrite -te "$x0" "$y0" "$x1" "$y1" -tr "$RES" "$RES" \
        -co COMPRESS=DEFLATE -co TILED=YES "$in" "$out" \
        || { warn "  recalage impossible pour $out"; cp -f "$in" "$out"; }
}

# Une tuile est considérée TERMINÉE si son marqueur de complétion existe ET que
# son raster d'irradiation est lisible par GDAL (détecte un fichier tronqué par
# une interruption). On s'appuie sur un marqueur plutôt que sur la seule présence
# des fichiers, car une tuile sans bâtiment ne produit légitimement pas de masque.
tile_done() {
    local code="$1"
    [ "${FORCE:-0}" = "1" ] && return 1
    [ -f "$DONE_DIR/${code}.done" ] || return 1
    [ -s "$TILES_DIR/irr_${code}.tif" ] || return 1
    gdalinfo "$TILES_DIR/irr_${code}.tif" >/dev/null 2>&1 || return 1
    return 0
}

# ============================================================================
# TRAITEMENT D'UNE TUILE  (exécuté en sous-processus, config via env)
# ============================================================================
process_one_tile() {
    local file="$1"
    local base ext code xmin ymin xmax ymax
    base=$(basename "$file")

    # --- Emprise exacte de la dalle ---
    if ! read -r code xmin ymin xmax ymax < <(tile_extent_from_name "$base"); then
        warn "❌ Nom non conforme au motif IGN, dalle ignorée : $base"
        return 0
    fi

    # --- Emprise bufferisée (pour l'ombrage de bordure) ---
    local bx0=$((xmin - BUFFER)) by0=$((ymin - BUFFER))
    local bx1=$((xmax + BUFFER)) by1=$((ymax + BUFFER))

    # --- REPRISE : tuile déjà calculée lors d'une exécution précédente ---
    if tile_done "$code"; then
        log "⏭ Tuile $code déjà calculée — ignorée (utiliser -R pour recalculer)"
        return 0
    fi

    log "▶ Tuile $code  [$xmin,$ymin,$xmax,$ymax]  buffer=${BUFFER}m"

    # --- Dalles intersectant l'emprise bufferisée (voisines incluses) ---
    local -a nfiles=()
    local line f fx0 fy0 fx1 fy1 _c
    while IFS=$'\t' read -r f _c fx0 fy0 fx1 fy1; do
        if boxes_intersect "$fx0" "$fy0" "$fx1" "$fy1" "$bx0" "$by0" "$bx1" "$by1"; then
            nfiles+=("$f")
        fi
    done < "$FILELIST"
    [ "${#nfiles[@]}" -eq 0 ] && nfiles=("$file")

    local tdir="$WORKDIR/$code"
    mkdir -p "$tdir"
    local dsm_raw="$tdir/dsm_raw.tif"      dsm_fill="$tdir/dsm.tif"
    local dtm_raw="$tdir/dtm_raw.tif"      dtm_fill="$MNT_DIR/mnt_${code}.tif"

    # --- MNS bufferisé : TOUTES surfaces, végétation incluse (ombrage correct) ---
    build_pdal_json "$dsm_raw" "max" "$bx0" "$by0" "$bx1" "$by1" surface "${nfiles[@]}" \
        > "$tdir/dsm.json"
    pdal pipeline "$tdir/dsm.json"
    "$FILLNODATA" -md 20 "$dsm_raw" "$dsm_fill"

    # --- MNT à l'emprise EXACTE (sol nu, classe 2) ---
    build_pdal_json "$dtm_raw" "idw" "$xmin" "$ymin" "$xmax" "$ymax" ground "${nfiles[@]}" \
        > "$tdir/dtm.json"
    pdal pipeline "$tdir/dtm.json"
    "$FILLNODATA" -md 50 "$dtm_raw" "$tdir/dtm_fill.tif"
    snap_grid "$tdir/dtm_fill.tif" "$dtm_fill" "$xmin" "$ymin" "$xmax" "$ymax"

    # --- Masque bâti (classe 6) à l'emprise EXACTE, si demandé (-c) ---
    # La végétation reste dans le MNS (elle ombrage), mais seuls les pixels
    # portant des points bâtiment sont conservés dans le résultat final.
    if [ "${MASK_CLASS6:-0}" = "1" ]; then
        local bati_raw="$tdir/bati_raw.tif" bati="$BATI_DIR/bati_${code}.tif"
        build_pdal_json "$bati_raw" "count" "$xmin" "$ymin" "$xmax" "$ymax" building "${nfiles[@]}" \
            > "$tdir/bati.json"
        if pdal pipeline "$tdir/bati.json" 2>/dev/null; then
            # Binarisation : présence d'au moins un point bâtiment -> 1
            "$GDALCALC" -A "$bati_raw" --outfile "$tdir/bati_bin.tif" --type Byte --NoDataValue=0 \
                --calc="(A>0)*1" --co COMPRESS=DEFLATE --quiet --overwrite
            snap_grid "$tdir/bati_bin.tif" "$bati" "$xmin" "$ymin" "$xmax" "$ymax"
        else
            warn "  aucun point classe 6 sur $code (dalle non classée ?)"
        fi
    fi

    # --- Calcul solaire GRASS sur emprise bufferisée, export recadré exact ---
    local gloc="$GISDB/tile_$code"
    rm -rf "$gloc"
    export DSM_TIF="$dsm_fill"
    export TX0="$xmin" TY0="$ymin" TX1="$xmax" TY1="$ymax"
    export OUT_IRR_TILE="$TILES_DIR/irr_${code}.tif"
    export OUT_MNS_TILE="$MNS_DIR/mns_${code}.tif"
    grass -c "$dsm_fill" "$gloc" --exec bash "$GRASS_BATCH"
    rm -rf "$gloc"

    [ "${KEEP_TMP:-0}" = "1" ] || rm -rf "$tdir"
    # Marqueur de complétion : écrit UNIQUEMENT après succès de toutes les
    # étapes (set -e interrompt avant en cas d'erreur) -> base de la reprise.
    mkdir -p "$DONE_DIR" && : > "$DONE_DIR/${code}.done"
    log "✔ Tuile $code terminée"
}

# ============================================================================
# GÉNÉRATION DU SCRIPT BATCH GRASS  (une session par tuile)
# ============================================================================
write_grass_batch() {
    cat > "$GRASS_BATCH" <<'GRASSEOF'
#!/usr/bin/env bash
set -euo pipefail

# Variables reçues via l'environnement :
#   DSM_TIF, TX0/TY0/TX1/TY1 (emprise exacte), RES, DAY_STEP, HORIZON_STEP,
#   LINKE, ALBEDO, MFLAG, OUT_IRR_TILE, OUT_MNS_TILE

# Import du MNS bufferisé et calage de la région sur sa grille complète.
r.in.gdal input="$DSM_TIF" output=dsm --overwrite
g.region raster=dsm

# Combler d'éventuels NULL résiduels (r.sun n'accepte pas les nuls).
if ! r.fillnulls input=dsm output=dsm_f 2>/dev/null; then
    g.copy raster=dsm,dsm_f --overwrite
fi

# Pente et exposition (aspect sens trigo depuis l'Est : compatible r.sun).
r.slope.aspect elevation=dsm_f slope=slope aspect=aspect --overwrite

# Angles d'horizon sur l'emprise BUFFERISÉE : le bâti/relief voisin projette
# ses ombres jusqu'au coeur de la dalle. Pas identique côté r.horizon / r.sun.
r.horizon elevation=dsm_f step="$HORIZON_STEP" output=horizon --overwrite

# Boucle annuelle : r.sun mode journalier -> irradiation globale du jour [Wh/m²].
# Le trouble de Linke est pris mois par mois (climat méditerranéen : été plus
# turbide) sauf si un Linke constant a été imposé (-l).
IFS=' ' read -ra LKM <<< "${LINKE_MONTHLY:-}"
maps=""
for day in $(seq 1 "$DAY_STEP" 365); do
    if [ "${MONTHLY_LINKE:-0}" = "1" ] && [ "${#LKM[@]}" -eq 12 ]; then
        mois=$(date -d "2023-01-01 +$((day-1)) days" +%-m)
        lk="${LKM[$((mois-1))]}"
    else
        lk="$LINKE"
    fi
    r.sun $MFLAG elevation=dsm_f aspect=aspect slope=slope \
        horizon_basename=horizon horizon_step="$HORIZON_STEP" \
        linke_value="$lk" albedo_value="$ALBEDO" \
        day="$day" glob_rad="glob_$day" --overwrite
    maps="$maps,glob_$day"
done
maps="${maps#,}"

# Somme échantillonnée -> extrapolation annuelle (Wh -> kWh/m²/an).
# float() force un raster simple précision (FCELL) : évite l'avertissement de
# perte de précision DCELL->Float32 à l'export (Float32 suffit pour kWh/m²/an).
r.series input="$maps" output=glob_sum method=sum --overwrite
r.mapcalc "irr = float(glob_sum * $DAY_STEP / 1000.0 * $REALSKY)" --overwrite

# RECADRAGE à l'emprise EXACTE de la dalle : élimine le buffer, raccords nets.
# Pas de drapeau -a : il alignerait la région sur des multiples de résolution
# et pourrait ÉLARGIR l'emprise (tuiles débordantes / chevauchement).
g.region n="$TY1" s="$TY0" e="$TX1" w="$TX0" res="$RES"

# -f : outrepasse le contrôle de précision ; -c : n'écrit pas de table de
# couleurs (impossible sur bande Float32 ; colorisation faite sur la mosaïque).
r.out.gdal -fc input=irr output="$OUT_IRR_TILE" format=GTiff type=Float32 \
    createopt="COMPRESS=DEFLATE,TILED=YES" nodata=-9999 --overwrite
r.out.gdal -fc input=dsm output="$OUT_MNS_TILE" format=GTiff type=Float32 \
    createopt="COMPRESS=DEFLATE,TILED=YES" nodata=-9999 --overwrite
GRASSEOF
    chmod +x "$GRASS_BATCH"
}

# ============================================================================
# AUTO-TEST des fonctions géométriques (bash cadastre_solaire.sh __selftest__)
# ============================================================================
run_selftest() {
    local ok=0 ko=0
    check() { # attendu obtenu message
        if [ "$1" = "$2" ]; then ok=$((ok+1));
        else ko=$((ko+1)); echo "  ÉCHEC: $3 (attendu '$1', obtenu '$2')"; fi
    }
    local name="LHD_FXX_0770_6278_PTS_C_LAMB93_IGN69.copc.laz"
    local out; out=$(TILE_SIZE=1000 tile_extent_from_name "$name")
    check "0770_6278 770000 6277000 771000 6278000" "$out" "emprise IGN 0770_6278"

    out=$(TILE_SIZE=1000 tile_extent_from_name "Semis_2021_0801_6300_LA93.laz")
    check "0801_6300 801000 6299000 802000 6300000" "$out" "emprise IGN 0801_6300"

    tile_extent_from_name "dalle_sans_code.laz" >/dev/null 2>&1 \
        && { echo "  ÉCHEC: un nom sans code aurait dû échouer"; ko=$((ko+1)); } \
        || ok=$((ok+1))

    if boxes_intersect 770000 6277000 771000 6278000 \
                       770500 6277500 772000 6279000; then ok=$((ok+1));
    else echo "  ÉCHEC: intersection attendue"; ko=$((ko+1)); fi
    if boxes_intersect 770000 6277000 771000 6278000 \
                       772000 6280000 773000 6281000; then
        echo "  ÉCHEC: pas d'intersection attendue"; ko=$((ko+1));
    else ok=$((ok+1)); fi

    echo "Auto-test : $ok OK, $ko KO"
    [ "$ko" -eq 0 ]
}

# Résout le nom réel d'un champ sans tenir compte de la casse (les DBF de
# shapefile stockent souvent les noms en MAJUSCULES). Liste les champs
# disponibles si aucune correspondance n'est trouvée.
resolve_field() {
    local shp="$1" want="$2" fields real
    fields=$(ogrinfo -so -al "$shp" 2>/dev/null \
        | awk -F':' '/^[A-Za-z0-9_]+: (String|Integer|Real|Date)/{print $1}')
    [ -z "$fields" ] && die "Impossible de lire les champs de $shp (fichier illisible, ou .dbf/.shx manquant ?)."
    real=$(printf '%s\n' "$fields" | awk -v w="$want" 'tolower($0)==tolower(w){print; exit}')
    if [ -z "$real" ]; then
        warn "Champ '$want' introuvable dans $shp. Champs disponibles :"
        printf '%s\n' "$fields" | sed 's/^/    /' >&2
        die "Précisez le bon champ avec -F."
    fi
    printf '%s\n' "$real"
}

# Extrait les valeurs d'un champ (CSV) SANS masquer les erreurs d'ogr2ogr ;
# retire guillemets et retours chariot Windows.
read_field_values() {
    local shp="$1" field="$2"
    ogr2ogr -f CSV /vsistdout/ -select "$field" "$shp" | tail -n +2 | tr -d '"\r'
}

# ============================================================================
# TÉLÉCHARGEMENT DES DALLES depuis un vecteur (mode -S)
#   Lit le champ $2 du vecteur $1 : si la valeur commence par http -> URL directe,
#   sinon on préfixe l'URL de base $3. Téléchargement parallèle, reprise si déjà
#   présent (fichiers .part renommés seulement en cas de succès complet).
# ============================================================================
download_tiles() {
    local shp="$1" field="$2" base="$3" cache="$4" jobs="$5"
    mkdir -p "$cache"
    local urls="$WORKDIR/dl_urls.txt"; : > "$urls"
    local v url
    while IFS= read -r v; do
        [ -z "$v" ] && continue
        case "$v" in
            http*://*) url="$v" ;;
            *) [ -z "$base" ] && die "Le champ '$field' contient un nom de fichier : fournissez -U <URL de base> (dossier de livraison IGN, ex: https://data.geopf.fr/telechargement/download/LiDARHD-NUALID/NUALHD_1-0__LAZ_LAMB93_NP_2024-12-19/)."
               url="${base%/}/$v" ;;
        esac
        printf '%s\n' "$url" >> "$urls"
    done < <(read_field_values "$shp" "$(resolve_field "$shp" "$field")")
    local n; n=$(grep -c . "$urls" || true)
    [ "${n:-0}" -eq 0 ] && die "Aucune valeur lue dans le champ '$field' de $shp."
    log "Téléchargement de $n dalles vers $cache ( -P $jobs, outil: $DLTOOL )…"
    CACHE="$cache" DLTOOL="$DLTOOL" xargs -P "$jobs" -I{} bash -c '
        url="$1"; dest="$CACHE/$(basename "$url")"
        if [ -s "$dest" ]; then exit 0; fi
        if [ "$DLTOOL" = wget ]; then wget -q -O "$dest.part" "$url"
        else curl -fsSL -o "$dest.part" "$url"; fi \
            && mv "$dest.part" "$dest" \
            || { echo "  ÉCHEC: $url" >&2; rm -f "$dest.part"; }
    ' _ {} < "$urls"
    local got; got=$(find "$cache" -maxdepth 1 -iname '*.copc.laz' -o -iname '*.laz' 2>/dev/null | wc -l)
    log "Dalles présentes dans le cache : $got / $n"
    [ "$got" -eq 0 ] && die "Aucune dalle téléchargée (vérifier l'URL de base / la connectivité)."
}

# Téléchargement d'une dalle unique (reprise si déjà présente).
download_one() {
    local url="$1" dest="$2"
    [ -s "$dest" ] && return 0
    mkdir -p "$(dirname "$dest")"
    if [ "$DLTOOL" = wget ]; then wget -q -O "$dest.part" "$url"
    else curl -fsSL -o "$dest.part" "$url"; fi \
        && mv "$dest.part" "$dest" \
        || { warn "  ÉCHEC téléchargement: $url"; rm -f "$dest.part"; return 1; }
}

# ============================================================================
# MODE PURGE : téléchargement à la demande + traitement séquentiel + suppression
#   Chaque dalle sert de voisine (ombrage) à plusieurs tuiles : on la supprime
#   seulement quand la DERNIÈRE tuile qui en a besoin est traitée (comptage de
#   références). L'occupation disque reste limitée à la fenêtre de voisinage.
# ============================================================================
plan_and_run_purge() {
    log "Mode purge : planification depuis $SEL_SHP…"
    : > "$FILELIST"
    local -a P C X0 Y0 X1 Y1
    local -A URLOF REF
    GXMIN=""; GYMIN=""; GXMAX=""; GYMAX=""
    local v url fname code x0 y0 x1 y1 n=0 path
    local raw="$WORKDIR/plan_raw.tsv" sorted="$WORKDIR/plan_sorted.tsv"
    : > "$raw"

    # 1) Lecture du vecteur -> emprises (ordre des entités : quelconque).
    while IFS= read -r v; do
        [ -z "$v" ] && continue
        case "$v" in
            http*://*) url="$v"; fname="$(basename "$v")" ;;
            *) [ -z "$BASEURL" ] && die "Champ '$SEL_FIELD' = nom de fichier : fournissez -U <URL de base>."
               fname="$v"; url="${BASEURL%/}/$v" ;;
        esac
        if ! read -r code x0 y0 x1 y1 < <(tile_extent_from_name "$fname"); then
            warn "  nom non IGN, ignoré : $fname"; continue
        fi
        printf '%d\t%d\t%d\t%d\t%s\t%s\t%s\n' "$y0" "$x0" "$x1" "$y1" "$code" "$fname" "$url" >> "$raw"
    done < <(read_field_values "$SEL_SHP" "$(resolve_field "$SEL_SHP" "$SEL_FIELD")")
    [ -s "$raw" ] || die "Aucune dalle valide dans $SEL_SHP (champ '$SEL_FIELD' vide, ou noms non conformes au motif IGN)."

    # 2) TRI SPATIAL en BALAYAGE SERPENTIN (rangées Y du nord au sud ; X alterné
    #    d'une rangée à l'autre). Le front de traitement avance de proche en
    #    proche : les voisines restent en cache et les dalles laissées derrière
    #    atteignent vite un compteur nul -> purge réellement efficace.
    sort -k1,1nr -k2,2n "$raw" \
      | awk -F'\t' 'BEGIN{OFS="\t"} {if(NR==1||$1!=py){r++; py=$1} k=(r%2==1?$2:-$2); print r,k,$0}' \
      | sort -k1,1n -k2,2n | cut -f3- > "$sorted"

    # 3) Chargement du plan trié.
    while IFS=$'\t' read -r y0 x0 x1 y1 code fname url; do
        path="$CACHE_DIR/$fname"
        P+=("$path"); C+=("$code"); X0+=("$x0"); Y0+=("$y0"); X1+=("$x1"); Y1+=("$y1")
        URLOF["$path"]="$url"
        printf '%s\t%s\t%d\t%d\t%d\t%d\n' "$path" "$code" "$x0" "$y0" "$x1" "$y1" >> "$FILELIST"
        [ -z "$GXMIN" ] || [ "$x0" -lt "$GXMIN" ] && GXMIN=$x0
        [ -z "$GYMIN" ] || [ "$y0" -lt "$GYMIN" ] && GYMIN=$y0
        [ -z "$GXMAX" ] || [ "$x1" -gt "$GXMAX" ] && GXMAX=$x1
        [ -z "$GYMAX" ] || [ "$y1" -gt "$GYMAX" ] && GYMAX=$y1
        n=$((n+1))
    done < "$sorted"
    NTILES=$n
    log "Plan : $NTILES dalles (balayage serpentin), emprise [$GXMIN,$GYMIN,$GXMAX,$GYMAX]"

    # Comptage de références : seules les tuiles RESTANT À CALCULER génèrent des
    # besoins. Les tuiles déjà terminées (reprise) ne provoquent donc aucun
    # téléchargement de voisines.
    local i j bx0 by0 bx1 by1 todo=0 skipped=0
    local -a TODO
    for ((i=0; i<n; i++)); do
        if tile_done "${C[i]}"; then TODO[i]=0; skipped=$((skipped+1)); continue; fi
        TODO[i]=1; todo=$((todo+1))
        bx0=$((X0[i]-BUFFER)); by0=$((Y0[i]-BUFFER)); bx1=$((X1[i]+BUFFER)); by1=$((Y1[i]+BUFFER))
        for ((j=0; j<n; j++)); do
            boxes_intersect "${X0[j]}" "${Y0[j]}" "${X1[j]}" "${Y1[j]}" "$bx0" "$by0" "$bx1" "$by1" \
                && REF["${P[j]}"]=$(( ${REF["${P[j]}"]:-0} + 1 ))
        done
    done
    [ "$skipped" -gt 0 ] && log "Reprise : $skipped tuiles déjà calculées, $todo à traiter."
    if [ "$todo" -eq 0 ]; then
        log "Toutes les tuiles sont déjà calculées ; passage direct à l'assemblage."
        return 0
    fi

    # Boucle : télécharger les voisines manquantes -> traiter -> purger.
    local done_n=0
    for ((i=0; i<n; i++)); do
        [ "${TODO[i]}" = "1" ] || continue
        done_n=$((done_n+1))
        bx0=$((X0[i]-BUFFER)); by0=$((Y0[i]-BUFFER)); bx1=$((X1[i]+BUFFER)); by1=$((Y1[i]+BUFFER))
        log "[$done_n/$todo] Tuile ${C[i]} — récupération des voisines…"
        for ((j=0; j<n; j++)); do
            boxes_intersect "${X0[j]}" "${Y0[j]}" "${X1[j]}" "${Y1[j]}" "$bx0" "$by0" "$bx1" "$by1" \
                && { [ -s "${P[j]}" ] || download_one "${URLOF[${P[j]}]}" "${P[j]}"; }
        done
        process_one_tile "${P[i]}"
        for ((j=0; j<n; j++)); do
            if boxes_intersect "${X0[j]}" "${Y0[j]}" "${X1[j]}" "${Y1[j]}" "$bx0" "$by0" "$bx1" "$by1"; then
                REF["${P[j]}"]=$(( ${REF["${P[j]}"]:-1} - 1 ))
                [ "${REF["${P[j]}"]}" -le 0 ] && rm -f "${P[j]}"
            fi
        done
    done
    log "Purge terminée : le cache a été vidé au fil de l'eau."
}

###############################################################################
# POINTS D'ENTRÉE INTERNES (dispatch avant la lecture des options)
###############################################################################
case "${1:-}" in
    __selftest__) run_selftest; exit $? ;;
    __tile__)     # traitement d'une tuile isolée (invoqué par le pool parallèle)
        FILLNODATA="${FILLNODATA:-gdal_fillnodata}"
        GDALCALC="${GDALCALC:-gdal_calc.py}"
        process_one_tile "$2"; exit $? ;;
esac

###############################################################################
# LECTURE DES OPTIONS (mode principal)
###############################################################################
usage() {
    cat <<USAGE
Cadastre solaire par tuiles IGN — PDAL / GDAL / GRASS (r.sun)

Usage : $0 -i <dossier_dalles> [options]

  -i  Dossier de dalles LiDAR IGN (.laz/.las/.copc.laz)     [requis sauf -S]
  -S  Vecteur (shp/gpkg) des dalles à télécharger depuis geopf.fr
  -F  Champ contenant le nom de fichier ou l'URL  (défaut: $SEL_FIELD)
  -U  URL de base (dossier de livraison IGN) si -F = nom de fichier
  -D  Dossier cache des dalles                 (défaut: OUTDIR/dalles_cache)
  -P  Téléchargements en parallèle             (défaut: $DL_JOBS)
  -x  Purger chaque dalle après usage (mode -S, disque limité ; séquentiel)
  -R  Tout recalculer (ignorer les tuiles déjà terminées)
  -o  Dossier de sortie                        (défaut: $OUTDIR)
  -e  EPSG cible (garder 2154 pour l'IGN)      (défaut: $EPSG)
  -r  Résolution (m)                           (défaut: $RES)
  -s  Pas annuel r.sun (jours)                 (défaut: $DAY_STEP)
  -H  Pas angulaire horizon (deg)              (défaut: $HORIZON_STEP)
  -l  Trouble de Linke CONSTANT (désactive le mensuel)
  -L  Trouble de Linke MENSUEL "j f m a m j j a s o n d"
        (défaut Lunel: $LINKE_MONTHLY)
  -C  Seuils de classe "T1 T2 T3" kWh/m²/an    (défaut Lunel: $CLASS_THRESHOLDS)
  -K  Coefficient ciel réel (0-1, défaut 1.0=ciel clair r.sun ; ~0.83 Lunel réel)
  -a  Albédo                                   (défaut: $ALBEDO)
  -B  Buffer inter-tuiles (m)                  (défaut: $BUFFER)
  -T  Taille de dalle (m)                      (défaut: $TILE_SIZE)
  -b  Emprises bâties (vecteur) pour le masque (optionnel)
  -c  Masque bâti depuis la classif. LiDAR (classe 6) (drapeau)
  -j  Tuiles traitées en parallèle             (défaut: $JOBS)
  -g  Classer le sol (SMRF) si non classé      (drapeau)
  -O  Filtre outlier statistique (coûteux RAM) (drapeau)
  -m  r.sun en mode faible mémoire             (drapeau)
  -k  Conserver les fichiers temporaires       (drapeau)
  -h  Aide

Le buffer doit dépasser la plus longue ombre portée attendue (bâti haut,
soleil bas). 200–300 m conviennent en milieu urbain courant.

Mémoire : le MNS est calculé en flux (streaming), mémoire quasi constante.
N'activez -O (filtre outlier) que sur des nuages mal classés : il charge tous
les points en RAM et peut déclencher l'OOM killer. La mémoire croît aussi avec
-j : en cas de « Killed », réduisez d'abord -j, puis le buffer -B.

Masque bâti : le MNS (donc l'ombrage) inclut TOUJOURS la végétation et tous
les objets ; -c restreint seulement le RÉSULTAT aux pixels bâtiment (classe 6
du LiDAR HD). -b (vecteur) et -c peuvent se combiner (intersection).

Téléchargement (-S) : lit le champ -F du vecteur de dalles. Si les valeurs sont
des URLs (http…), elles sont téléchargées directement (idéal multi-blocs). Si ce
sont des noms de fichiers, fournissez -U (dossier de livraison IGN, un seul bloc).
Les dalles arrivent avec le nom IGN standard : le reste de la chaîne est inchangé.
Astuce vaste zone : incluez dans le shp un anneau de dalles autour de l'emprise,
pour que l'ombrage de bordure dispose des voisines.
USAGE
}

while getopts ":i:o:e:r:s:H:l:L:a:K:B:T:C:b:j:S:F:U:D:P:cgOmkxRh" opt; do
    case "$opt" in
        i) INPUT="$OPTARG" ;;   o) OUTDIR="$OPTARG" ;;
        e) EPSG="$OPTARG" ;;    r) RES="$OPTARG" ;;
        s) DAY_STEP="$OPTARG" ;; H) HORIZON_STEP="$OPTARG" ;;
        l) LINKE="$OPTARG"; MONTHLY_LINKE=0 ;;
        L) LINKE_MONTHLY="$OPTARG"; MONTHLY_LINKE=1 ;;
        a) ALBEDO="$OPTARG" ;;
        K) REALSKY="$OPTARG" ;;
        C) CLASS_THRESHOLDS="$OPTARG" ;;
        B) BUFFER="$OPTARG" ;;  T) TILE_SIZE="$OPTARG" ;;
        b) BUILDINGS="$OPTARG" ;; j) JOBS="$OPTARG" ;;
        S) SEL_SHP="$OPTARG" ;; F) SEL_FIELD="$OPTARG" ;;
        U) BASEURL="$OPTARG" ;; D) CACHE_DIR="$OPTARG" ;;
        P) DL_JOBS="$OPTARG" ;;
        c) MASK_CLASS6=1 ;;
        g) CLASSIFY_GROUND=1 ;; O) OUTLIER=1 ;;
        m) LOWMEM=1 ;;
        k) KEEP_TMP=1 ;;        x) PURGE=1 ;;
        R) FORCE=1 ;;
        h) usage; exit 0 ;;
        \?) die "Option inconnue : -$OPTARG" ;;
        :)  die "L'option -$OPTARG requiert un argument." ;;
    esac
done

[ -z "$INPUT" ] && [ -z "$SEL_SHP" ] && { usage; die "Fournir -i (dossier de dalles) ou -S (vecteur des dalles à télécharger)."; }
[ "$EPSG" != "2154" ] && warn "EPSG=$EPSG : le tuilage IGN suppose du Lambert-93 (2154)."
# Sécurité : la purge ne supprime QUE des dalles téléchargées (-S). Jamais les
# fichiers fournis par l'utilisateur via -i.
if [ "$PURGE" = "1" ] && [ -z "$SEL_SHP" ]; then
    warn "-x (purge) ignoré : il ne s'applique qu'au mode téléchargement -S."
    PURGE=0
fi

###############################################################################
# VÉRIFICATIONS ET PRÉPARATION
###############################################################################
log "Vérification des dépendances…"
for c in pdal grass gdalinfo gdalbuildvrt gdal_translate gdal_rasterize gdaldem gdalwarp ogr2ogr ogrinfo awk find; do
    need "$c"
done
FILLNODATA="gdal_fillnodata"
command -v gdal_fillnodata >/dev/null 2>&1 || FILLNODATA="gdal_fillnodata.py"
command -v "$FILLNODATA" >/dev/null 2>&1 || die "gdal_fillnodata introuvable."
GDALCALC="gdal_calc.py"
command -v gdal_calc.py >/dev/null 2>&1 || GDALCALC="gdal_calc"
command -v "$GDALCALC" >/dev/null 2>&1 || die "gdal_calc introuvable."
DLTOOL=""
command -v wget >/dev/null 2>&1 && DLTOOL="wget"
[ -z "$DLTOOL" ] && command -v curl >/dev/null 2>&1 && DLTOOL="curl"
[ -n "$SEL_SHP" ] && [ -z "$DLTOOL" ] && die "Mode -S : wget ou curl requis pour le téléchargement."

mkdir -p "$OUTDIR"
WORKDIR="$OUTDIR/tmp"
TILES_DIR="$OUTDIR/tuiles_irr"
MNS_DIR="$OUTDIR/tuiles_mns"
MNT_DIR="$OUTDIR/tuiles_mnt"
BATI_DIR="$OUTDIR/tuiles_bati"
DONE_DIR="$OUTDIR/tuiles_done"
GISDB="$WORKDIR/grassdata"
FILELIST="$WORKDIR/dalles.tsv"
GRASS_BATCH="$WORKDIR/grass_solar.sh"
mkdir -p "$WORKDIR" "$TILES_DIR" "$MNS_DIR" "$MNT_DIR" "$BATI_DIR" "$DONE_DIR" "$GISDB"

RADIUS=$(awk "BEGIN{printf \"%.3f\", $RES*1.5}")
MFLAG=""; [ "$LOWMEM" -eq 1 ] && MFLAG="-m"

# Mode téléchargement : prépare le cache et bascule INPUT dessus. En purge, le
# téléchargement se fait à la demande dans plan_and_run_purge (pas de bulk ici).
if [ -n "$SEL_SHP" ]; then
    [ -f "$SEL_SHP" ] || die "Vecteur de dalles introuvable : $SEL_SHP"
    [ -z "$CACHE_DIR" ] && CACHE_DIR="$OUTDIR/dalles_cache"
    mkdir -p "$CACHE_DIR"
    INPUT="$CACHE_DIR"
    [ "$PURGE" = "1" ] || download_tiles "$SEL_SHP" "$SEL_FIELD" "$BASEURL" "$CACHE_DIR" "$DL_JOBS"
fi

# NB : le nettoyage ET le découpage (-clipsrc) du vecteur bâti ont lieu APRÈS
# le traitement des tuiles, une fois l'emprise globale connue.

###############################################################################
# INDEXATION DES DALLES  (nom -> emprise) + emprise globale
#   En mode purge, l'indexation ET le traitement sont faits par plan_and_run_purge.
###############################################################################
if [ "$PURGE" != "1" ]; then
log "Indexation des dalles et reconstruction des emprises IGN…"
: > "$FILELIST"
GXMIN=""; GYMIN=""; GXMAX=""; GYMAX=""; NTILES=0

while IFS= read -r f; do
    b=$(basename "$f")
    if ! read -r code x0 y0 x1 y1 < <(tile_extent_from_name "$b"); then
        warn "  ignorée (nom non IGN) : $b"; continue
    fi
    printf '%s\t%s\t%d\t%d\t%d\t%d\n' "$f" "$code" "$x0" "$y0" "$x1" "$y1" >> "$FILELIST"
    [ -z "$GXMIN" ] || [ "$x0" -lt "$GXMIN" ] && GXMIN=$x0
    [ -z "$GYMIN" ] || [ "$y0" -lt "$GYMIN" ] && GYMIN=$y0
    [ -z "$GXMAX" ] || [ "$x1" -gt "$GXMAX" ] && GXMAX=$x1
    [ -z "$GYMAX" ] || [ "$y1" -gt "$GYMAX" ] && GYMAX=$y1
    NTILES=$((NTILES+1))
done < <(find "$INPUT" -maxdepth 1 -type f \
            \( -iname '*.laz' -o -iname '*.las' -o -iname '*.copc.laz' \) | sort)

[ "$NTILES" -eq 0 ] && die "Aucune dalle IGN valide trouvée dans $INPUT"
log "Dalles valides : $NTILES  | Emprise globale : [$GXMIN,$GYMIN,$GXMAX,$GYMAX]"
fi

###############################################################################
# BOUCLE DE TRAITEMENT DES TUILES (séquentiel ou parallèle)
###############################################################################
write_grass_batch

# Variables transmises aux sous-processus tuile.
export EPSG RES RADIUS BUFFER TILE_SIZE DAY_STEP HORIZON_STEP LINKE ALBEDO REALSKY
export LINKE_MONTHLY MONTHLY_LINKE
export MFLAG CLASSIFY_GROUND KEEP_TMP FILLNODATA GDALCALC MASK_CLASS6 OUTLIER FORCE
export WORKDIR TILES_DIR MNS_DIR MNT_DIR BATI_DIR DONE_DIR GISDB FILELIST GRASS_BATCH
export GRASS_OVERWRITE=1 GRASS_MESSAGE_FORMAT=plain

if [ "$PURGE" = "1" ]; then
    plan_and_run_purge
else
    log "Traitement des $NTILES tuiles ( -j $JOBS )…"
    cut -f1 "$FILELIST" | xargs -P "$JOBS" -I{} bash "$0" __tile__ "{}"
fi

###############################################################################
# PRÉPARATION DU VECTEUR BÂTI : découpage sur l'emprise + 2D + géométries valides
#   -clipsrc limite la couche à la zone traitée (gain net sur un vaste
#   territoire : rasterisation et statistiques zonales bien plus rapides).
#   -dim 2 supprime les avertissements 3D, -makevalid répare les anneaux non
#   fermés et fiabilise les surfaces calculées par v.rast.stats.
###############################################################################
if [ -n "${BUILDINGS:-}" ]; then
    log "Préparation du vecteur bâti (découpe sur l'emprise, 2D, géométries valides)…"
    BATI_CLEAN="$WORKDIR/bati_clean.gpkg"
    if ogr2ogr -clipsrc "$GXMIN" "$GYMIN" "$GXMAX" "$GYMAX" \
            -dim 2 -nlt PROMOTE_TO_MULTI -makevalid \
            "$BATI_CLEAN" "$BUILDINGS" 2>/dev/null \
       || ogr2ogr -clipsrc "$GXMIN" "$GYMIN" "$GXMAX" "$GYMAX" \
            -dim 2 -nlt PROMOTE_TO_MULTI \
            "$BATI_CLEAN" "$BUILDINGS" 2>/dev/null; then
        NBAT=$(ogrinfo -so -al "$BATI_CLEAN" 2>/dev/null \
                 | awk -F': ' '/^Feature Count/{print $2; exit}')
        if [ "${NBAT:-0}" -gt 0 ] 2>/dev/null; then
            BUILDINGS="$BATI_CLEAN"
            log "  bâtiments retenus dans l'emprise : $NBAT"
        else
            warn "  découpe vide : le vecteur ne recouvre pas l'emprise ; vecteur brut conservé."
        fi
    else
        warn "  préparation impossible ; utilisation du vecteur brut."
    fi
fi

###############################################################################
# MOSAÏQUAGE
###############################################################################
log "Mosaïquage des tuiles…"
DSM_OUT="$OUTDIR/mns.tif"
DTM_OUT="$OUTDIR/mnt.tif"
OUT_IRR="$OUTDIR/irradiation_annuelle.tif"

mosaic() { # motif  sortie
    local vrt="$WORKDIR/$(basename "$2" .tif).vrt"
    gdalbuildvrt -q "$vrt" $1
    gdal_translate -q -co COMPRESS=DEFLATE -co TILED=YES "$vrt" "$2"
}
mosaic "$TILES_DIR/irr_*.tif" "$OUT_IRR"
mosaic "$MNS_DIR/mns_*.tif"   "$DSM_OUT"
mosaic "$MNT_DIR/mnt_*.tif"   "$DTM_OUT"

###############################################################################
# CONSTRUCTION DU MASQUE BÂTI (classe 6 LiDAR et/ou vecteur) + APPLICATION
#   Rappel : la végétation reste dans le MNS -> ses ombres sont bien prises en
#   compte par r.sun. Le masque ne fait que restreindre les pixels RESTITUÉS.
###############################################################################
SOURCE="$OUT_IRR"
OUT_ROOF="$OUTDIR/cadastre_solaire_toitures.tif"
OUT_CLASS="$OUTDIR/cadastre_solaire_classe.tif"
OUT_COLOR="$OUTDIR/cadastre_solaire_couleur.tif"

MASK=""
# 1) Masque issu de la classification LiDAR (classe 6 = bâtiment)
if [ "$MASK_CLASS6" = "1" ] && ls "$BATI_DIR"/bati_*.tif >/dev/null 2>&1; then
    log "Masque bâti classe 6 (mosaïque des tuiles)…"
    mosaic "$BATI_DIR/bati_*.tif" "$OUTDIR/masque_bati_lidar.tif"
    MASK="$OUTDIR/masque_bati_lidar.tif"
fi
# 2) Masque issu d'un vecteur d'emprises (option -b) ; intersection si les deux
if [ -n "${BUILDINGS:-}" ]; then
    log "Masque bâti vecteur (rasterisation)…"
    VMASK="$WORKDIR/masque_vecteur.tif"
    gdal_rasterize -q -burn 1 -init 0 -ot Byte -a_nodata 0 \
        -tr "$RES" "$RES" -te "$GXMIN" "$GYMIN" "$GXMAX" "$GYMAX" \
        "$BUILDINGS" "$VMASK"
    if [ -n "$MASK" ]; then
        "$GDALCALC" -A "$MASK" -B "$VMASK" --outfile "$WORKDIR/masque_combine.tif" \
            --type Byte --NoDataValue=0 --calc="(A==1)*(B==1)" \
            --co COMPRESS=DEFLATE --quiet --overwrite
        MASK="$WORKDIR/masque_combine.tif"
    else
        MASK="$VMASK"
    fi
fi
# 3) Application du masque à l'irradiation
if [ -n "$MASK" ]; then
    log "Application du masque bâti à l'irradiation…"
    "$GDALCALC" -A "$OUT_IRR" -B "$MASK" --outfile "$OUT_ROOF" \
        --calc="A*(B==1)+(-9999)*(B!=1)" --NoDataValue=-9999 \
        --co COMPRESS=DEFLATE --co TILED=YES --quiet --overwrite
    SOURCE="$OUT_ROOF"
fi

# Classification du potentiel (seuils en kWh/m²/an, adaptés à Lunel via -C).
#   1=Faible  2=Moyen  3=Bon  4=Excellent
read -r T1 T2 T3 <<< "$CLASS_THRESHOLDS"
log "Classification du potentiel solaire (seuils $T1/$T2/$T3 kWh/m²/an)…"
"$GDALCALC" -A "$SOURCE" --outfile "$OUT_CLASS" --type Byte --NoDataValue=0 \
    --calc="4*(A>=$T3)+3*((A>=$T2)*(A<$T3))+2*((A>=$T1)*(A<$T2))+1*((A>0)*(A<$T1))" \
    --co COMPRESS=DEFLATE --co TILED=YES --quiet --overwrite

# Colorisation DISCRÈTE des classes (valeurs exactes 1..4, pas de dégradé).
#   1 Faible=jaune | 2 Moyen=orange clair | 3 Bon=rouge | 4 Excellent=violet
OUT_CLASS_COLOR="$OUTDIR/cadastre_solaire_classe_couleur.tif"
CLASSCOLORFILE="$WORKDIR/classes_couleur.txt"
cat > "$CLASSCOLORFILE" <<'CLSRAMP'
0   0   0   0     0
1 255 255   0   255
2 255 178  102   255
3 227  26  28    255
4 128   0 128    255
nv  0   0   0     0
CLSRAMP
gdaldem color-relief "$OUT_CLASS" "$CLASSCOLORFILE" "$OUT_CLASS_COLOR" \
    -exact_color_entry -alpha -co COMPRESS=DEFLATE -co TILED=YES -q

# Colorisation pour visualisation.
log "Colorisation…"
# Rampe alignée sur l'histogramme de Lunel et les seuils de classe.
COLORFILE="$WORKDIR/rampe_solaire.txt"
cat > "$COLORFILE" <<'RAMP'
nv    0   0   0     0
1100  43 131 186
1450 171 221 164
1700 255 255 191
1950 253 174  97
2200 215  25  28
RAMP
gdaldem color-relief "$SOURCE" "$COLORFILE" "$OUT_COLOR" \
    -alpha -co COMPRESS=DEFLATE -co TILED=YES -q

###############################################################################
# STATISTIQUES ZONALES PAR BÂTIMENT (option -b) -> GeoPackage attribué
#   Agrège l'irradiation (déjà restreinte aux toitures si un masque est actif)
#   sous chaque polygone : nombre de pixels, min/max/moyenne/écart-type/somme,
#   + surface de toiture utile et énergie solaire annuelle incidente.
###############################################################################
OUT_ZONAL="$OUTDIR/cadastre_solaire_batiments.gpkg"
if [ -n "${BUILDINGS:-}" ]; then
    log "Statistiques zonales par bâtiment (v.rast.stats)…"
    ZONAL_BATCH="$WORKDIR/grass_zonal.sh"
    cat > "$ZONAL_BATCH" <<'ZEOF'
#!/usr/bin/env bash
set -euo pipefail
# Raster d'irradiation + vecteur bâti importés dans la région du raster.
r.in.gdal input="$ZS_RASTER" output=irr --overwrite
g.region raster=irr
v.import input="$ZS_VECTOR" output=bati --overwrite
# Statistiques univariées de l'irradiation sous chaque polygone (préfixe irr_).
v.rast.stats -c map=bati raster=irr column_prefix=irr \
    method=number,minimum,maximum,average,stddev,sum
# Reconstruction de la classe de potentiel (mêmes seuils que -C).
r.mapcalc "classe = if(irr>=$ZS_T3,4, if(irr>=$ZS_T2,3, if(irr>=$ZS_T1,2, if(irr>0,1,null()))))" --overwrite
# Surface par classe : pour chaque classe, masque -> comptage de pixels/polygone.
for k in 1 2 3 4; do
    r.mapcalc "ck = if(classe==$k,1,null())" --overwrite
    if r.univar -g ck 2>/dev/null | grep -q '^n=[1-9]'; then
        v.rast.stats -c map=bati raster=ck column_prefix=cls$k method=number
    else
        v.db.addcolumn map=bati columns="cls${k}_number integer" 2>/dev/null || true
    fi
done
# Colonnes dérivées :
#   surf_toit_m2 = nb_pixels * aire_pixel         -> surface de toiture utile
#   nrj_kwh_an   = somme(kWh/m²/an) * aire_pixel   -> énergie solaire INCIDENTE
#   surf_clN_m2  = nb_pixels_classe_N * aire_pixel -> surface par classe (m²)
v.db.addcolumn map=bati columns="surf_toit_m2 double precision, nrj_kwh_an double precision, surf_cl1_m2 double precision, surf_cl2_m2 double precision, surf_cl3_m2 double precision, surf_cl4_m2 double precision"
v.db.update map=bati column=surf_toit_m2 query_column="irr_number * ($ZS_PIXAREA)"
v.db.update map=bati column=nrj_kwh_an  query_column="irr_sum * ($ZS_PIXAREA)"
v.db.update map=bati column=surf_cl1_m2 query_column="COALESCE(cls1_number,0) * ($ZS_PIXAREA)"
v.db.update map=bati column=surf_cl2_m2 query_column="COALESCE(cls2_number,0) * ($ZS_PIXAREA)"
v.db.update map=bati column=surf_cl3_m2 query_column="COALESCE(cls3_number,0) * ($ZS_PIXAREA)"
v.db.update map=bati column=surf_cl4_m2 query_column="COALESCE(cls4_number,0) * ($ZS_PIXAREA)"
# Export GeoPackage (polygones attribués).
v.out.ogr input=bati type=area output="$ZS_OUT" format=GPKG --overwrite
ZEOF
    read -r ZS_T1 ZS_T2 ZS_T3 <<< "$CLASS_THRESHOLDS"
    export ZS_RASTER="$SOURCE" ZS_VECTOR="$BUILDINGS" ZS_OUT="$OUT_ZONAL"
    export ZS_T1 ZS_T2 ZS_T3
    export ZS_PIXAREA="$(awk "BEGIN{printf \"%.6f\", $RES*$RES}")"
    rm -rf "$GISDB/zonal"
    grass -c "$SOURCE" "$GISDB/zonal" --exec bash "$ZONAL_BATCH"
    rm -rf "$GISDB/zonal"
fi

[ "$KEEP_TMP" = "1" ] || rm -rf "$WORKDIR"

###############################################################################
# BILAN
###############################################################################
log "Terminé. Résultats dans : $OUTDIR"
cat <<RECAP

  MNS mosaïqué ................... $DSM_OUT
  MNT mosaïqué ................... $DTM_OUT
  Irradiation annuelle .......... $OUT_IRR        [kWh/m²/an]
$( [ -n "$MASK" ] && echo "  Cadastre solaire (toitures) ... $OUT_ROOF" )
$( [ "$MASK_CLASS6" = "1" ] && echo "  Masque bâti classe 6 .......... $OUTDIR/masque_bati_lidar.tif" )
$( [ -n "${BUILDINGS:-}" ] && echo "  Stats par bâtiment (GPKG) ..... $OUT_ZONAL" )
  Potentiel classé .............. $OUT_CLASS      [1..4]
  Classes colorisées ............ $OUT_CLASS_COLOR
  Version colorisée ............. $OUT_COLOR
  Tuiles unitaires .............. $TILES_DIR/

Vérifiez l'histogramme (gdalinfo -hist "$OUT_IRR") pour recaler les seuils de
classification et le trouble de Linke sur des valeurs locales.
RECAP
