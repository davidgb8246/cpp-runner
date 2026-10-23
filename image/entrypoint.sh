#!/bin/sh
# Entrypoint del contenedor. Modos (mutuamente excluyentes):
#   (sin argumentos) | --juez | -j   compila con Makefile y ejecuta
#   --local | -l                     compila con Makefile.local y ejecuta
#   --test | -t                      como --juez, pero compara la salida con entrada.out
#   --generar-makefile | -g          genera un Makefile estático en el directorio montado
#   --tar[=NOMBRE] | -T              crea un .tar SIN comprimir con los .h/.cpp/Makefile del proyecto

MK_DIR="${MK_DIR:-/opt/mk}"        # Makefiles internos (no se mezclan con el código del usuario)
WORK_DIR="${WORK_DIR:-/work}"      # Proyecto montado
INPUT_NAME="entrada.in"
EXPECTED_NAME="entrada.out"

# Máximo de diferencias mostradas en el modo --test (variable TEST_MAX_DIFFS)
TAR_DEFAULT="codigo.tar"           # nombre del .tar si no se indica ninguno
TAR_NAME="${TAR_NAME-}"
MAX_DIFFS="${TEST_MAX_DIFFS:-20}"
case "$MAX_DIFFS" in ''|*[!0-9]*) MAX_DIFFS=20 ;; esac

usage() {
cat <<USAGE
Uso: docker run --rm [-i] -v "\$PWD":/work IMAGEN [OPCION]

  (sin opción), --juez, -j     Compila con "Makefile" (modo juez) y ejecuta.
  --local, -l                  Compila con "Makefile.local" y ejecuta.
  --test, -t                   Como --juez, pero compara la salida del programa con
                               "$EXPECTED_NAME" (exacta) y muestra solo las diferencias.
                               Exige "$INPUT_NAME" y "$EXPECTED_NAME" en el directorio montado.
  --generar-makefile, -g       Genera ./Makefile estático (rutas fijas) en el
                               directorio montado. No compila ni ejecuta.
  --tar[=NOMBRE], -T           Crea un fichero .tar SIN compresión en el directorio montado con
                               todos los .h, .hpp, .cpp y Makefile que encuentre (recursivo, rutas
                               relativas). NOMBRE puede llevar o no la extensión .tar; por defecto
                               "$TAR_DEFAULT". Tambien puede darse con la variable TAR_NAME.
                               No compila ni ejecuta. Necesita montaje de lectura y escritura.
  --help, -h                   Muestra esta ayuda.

Si existe "$INPUT_NAME" en el directorio montado, se pasa por entrada estándar.
Códigos de salida de --test: 0 OK, 1 salida distinta, 2 faltan ficheros/uso,
3 error de compilación, 4 salida idéntica pero el programa terminó con estado != 0.
Variable TEST_MAX_DIFFS: máximo de diferencias mostradas con --test (por defecto 20).
USAGE
}

banner() { printf '\n===== %s =====\n' "$1"; }

# ---------- Selección de modo ----------
mode=juez
if [ $# -gt 1 ]; then
    echo "Error: las opciones son mutuamente excluyentes (se recibieron $#)." >&2
    usage >&2
    exit 2
fi
case "${1-}" in
    ""|--juez|-j)             mode=juez ;;
    --local|-l)               mode=local ;;
    --test|-t)                mode=test ;;
    --generar-makefile|-g)    mode=gen ;;
    --tar|-T)                 mode=tar ;;
    --tar=*)                  mode=tar; TAR_NAME=${1#*=}
                              [ -n "$TAR_NAME" ] || { echo "Error: --tar= requiere un nombre." >&2; exit 2; } ;;
    --help|-h)                usage; exit 0 ;;
    *) echo "Error: opción desconocida: $1" >&2; usage >&2; exit 2 ;;
esac

if [ ! -d "$WORK_DIR" ]; then
    echo "Error: no existe el directorio $WORK_DIR. Monta tu proyecto con -v \"\$PWD\":/work" >&2
    exit 2
fi

# ---------- Modo: generar Makefile estático ----------
if [ "$mode" = gen ]; then
    out="$WORK_DIR/Makefile"
    tmp="$WORK_DIR/.Makefile.gen.$$"
    banner "GENERACIÓN DE Makefile ESTÁTICO"
    [ -e "$out" ] && echo "Aviso: se sobrescribirá el Makefile existente."
    trap 'rm -f "$tmp"' EXIT
    cd "$WORK_DIR" || exit 1
    if ! make -f "$MK_DIR/Makefile" -f "$MK_DIR/gen.mk" gen GEN_OUT="$tmp" 2>&1 </dev/null; then
        echo "Error: no se pudo generar el Makefile." >&2
        exit 1
    fi
    if ! mv -f "$tmp" "$out"; then
        echo "Error: no se pudo escribir $out (¿montaje de solo lectura?)." >&2
        exit 1
    fi
    # Que el fichero pertenezca al dueño del directorio montado, no a root
    chown "$(stat -c '%u:%g' "$WORK_DIR")" "$out" 2>/dev/null
    echo "Makefile generado: $out"
    echo "Ficheros .cpp incluidos: $(sed -n 's/^SOURCES = //p' "$out" | wc -w)"
    exit 0
fi

# ---------- Modo: crear .tar (sin compresión) con las fuentes ----------
if [ "$mode" = tar ]; then
    name="${TAR_NAME:-$TAR_DEFAULT}"
    case "$name" in
        */*) echo "Error: el nombre del tar no puede contener '/': $name" >&2; exit 2 ;;
        .|..) echo "Error: nombre de tar no válido: $name" >&2; exit 2 ;;
    esac
    case "$name" in *.[tT][aA][rR]) ;; *) name="$name.tar" ;; esac
    out="$WORK_DIR/$name"
    tmp="$WORK_DIR/.tar.gen.$$"
    banner "CREACIÓN DE $name (tar sin compresión)"
    [ -e "$out" ] && echo "Aviso: se sobrescribirá el fichero existente."
    trap 'rm -f "$tmp"' EXIT
    cd "$WORK_DIR" || exit 1
    list="$(mktemp)" || exit 1
    trap 'rm -f "$tmp" "$list"' EXIT
    # Equivalente a: tar -cf X.tar $(find . -type f \( -iname "*.h" -o -iname "*.hpp" -o -iname "*.cpp" -o -iname "Makefile" \) -printf "%P\n")
    # (con -print0/--null para admitir nombres con espacios; se excluye el propio tar y el temporal)
    find . -type f \( -iname '*.h' -o -iname '*.hpp' -o -iname '*.cpp' -o -iname 'Makefile' \) \
         ! -path "./$name" ! -path "./.tar.gen.$$" -printf '%P\0' | sort -z > "$list"
    if [ ! -s "$list" ]; then
        echo "Error: no se ha encontrado ningún .h, .hpp, .cpp ni Makefile en el proyecto." >&2
        exit 1
    fi
    if ! tar -cf "$tmp" --null -T "$list"; then
        echo "Error: no se pudo crear el tar." >&2
        exit 1
    fi
    if ! mv -f "$tmp" "$out"; then
        echo "Error: no se pudo escribir $out (¿montaje de solo lectura?)." >&2
        exit 1
    fi
    chown "$(stat -c '%u:%g' "$WORK_DIR")" "$out" 2>/dev/null
    echo "Tar creado: $out"
    echo "Ficheros incluidos: $(tr -cd '\0' < "$list" | wc -c)"
    tar -tf "$out"
    exit 0
fi

# ---------- Comprobaciones previas del modo test ----------
if [ "$mode" = test ]; then
    missing=""
    [ -f "$WORK_DIR/$INPUT_NAME" ]    || missing="$missing $INPUT_NAME"
    [ -f "$WORK_DIR/$EXPECTED_NAME" ] || missing="$missing $EXPECTED_NAME"
    if [ -n "$missing" ]; then
        echo "Error: el modo --test exige $INPUT_NAME y $EXPECTED_NAME en el directorio montado. Faltan:$missing" >&2
        exit 2
    fi
fi

# ---------- Modos: compilar + ejecutar ----------
case "$mode" in
    juez|test) mk_name=Makefile ;;
    local)     mk_name=Makefile.local ;;
esac

# Se trabaja sobre una copia: el directorio del usuario queda intacto
# (sin .o, .d ni a.out) y puede montarse como solo lectura.
BUILD="$(mktemp -d)" || exit 1
RES="$(mktemp -d)" || exit 1       # resultados del modo test (fuera de la copia del proyecto)
trap 'rm -rf "$BUILD" "$RES"' EXIT
find "$WORK_DIR" -mindepth 1 -maxdepth 1 ! -name .git -exec cp -a {} "$BUILD"/ \;
# Elimina artefactos de compilación que el usuario pudiera traer del host
find "$BUILD" -type f \( -name '*.o' -o -name '*.d' \) -delete
rm -f "$BUILD/a.out"

cd "$BUILD" || exit 1

banner "COMPILACIÓN ($mk_name)"
make -f "$MK_DIR/$mk_name" 2>&1 </dev/null
rc=$?

if [ "$rc" -ne 0 ]; then
    banner "CÓDIGO DE ESTADO"
    echo "La compilación ha fallado (make terminó con código $rc). El programa no se ha ejecutado."
    [ "$mode" = test ] && exit 3
    exit "$rc"
fi

# Imprime el estado del programa (y la señal si murió por una)
print_status() {
    banner "CÓDIGO DE ESTADO"
    echo "$1"
    if [ "$1" -gt 128 ]; then
        sig="$(kill -l $(($1 - 128)) 2>/dev/null)" && echo "(terminado por la señal SIG$sig)"
    fi
}

# ---------- Modo: compilar + ejecutar (juez / local) ----------
if [ "$mode" != test ]; then
    banner "SALIDA DEL PROGRAMA"
    if [ -f "$WORK_DIR/$INPUT_NAME" ]; then
        ./a.out < "$WORK_DIR/$INPUT_NAME"
    else
        ./a.out
    fi
    rc=$?
    print_status "$rc"
    exit "$rc"
fi

# ---------- Modo: test (salida vs entrada.out) ----------
EXPECTED="$WORK_DIR/$EXPECTED_NAME"

# Utilidades de presentación
rng()     { if [ "$1" = "$2" ]; then echo "$1"; else echo "$1-$2"; fi; }
after()   { if [ "$1" -eq 0 ]; then echo "al principio"; else echo "tras su línea $1"; fi; }
nlines()  { grep -c '' "$1"; }                                  # cuenta también una última línea sin \n
ends_nl() { [ -s "$1" ] && [ -z "$(tail -c1 "$1")" ]; }         # ¿el fichero termina en salto de línea?
vis()     { sed -e 's/\r/\\r/g' -e 's/\t/\\t/g' "$1"; }         # hace visibles CR y tabuladores

# Muestra los grupos de diferencias ($1) con un máximo de $2.
# Todas las referencias son a líneas de la SALIDA (esperada u obtenida): la salida puede
# ser más larga o más corta que entrada.in, así que no existe correspondencia con sus líneas.
show_diffs() {
    file=$1; max=$2
    total=$(grep -c '^@@HUNK ' "$file")
    n=0
    while IFS= read -r line; do
        case "$line" in
            '@@HUNK '*)
                n=$((n + 1))
                [ "$n" -gt "$max" ] && break
                set -- $line      # 1=@@HUNK 2=tipo 3=f 4=l 5=e 6=F 7=L 8=E   (minúsculas: esperado, mayúsculas: obtenido)
                printf '\n'
                case "$2" in
                    C) printf 'Diferencia %s de %s: líneas distintas (esperado: %s | obtenido: %s)\n' \
                           "$n" "$total" "$(rng "$3" "$4")" "$(rng "$6" "$7")" ;;
                    D) printf 'Diferencia %s de %s: FALTAN líneas en la salida (esperado: %s; la salida obtenida sigue %s)\n' \
                           "$n" "$total" "$(rng "$3" "$4")" "$(after "$8")" ;;
                    A) printf 'Diferencia %s de %s: SOBRAN líneas en la salida (obtenido: %s; %s sigue %s)\n' \
                           "$n" "$total" "$(rng "$6" "$7")" "$EXPECTED_NAME" "$(after "$5")" ;;
                esac
                ;;
            *) printf '%s\n' "$line" ;;
        esac
    done < "$file"
    if [ "$total" -gt "$max" ]; then
        printf '\n... y %s diferencia(s) más sin mostrar (límite TEST_MAX_DIFFS=%s).\n' "$((total - max))" "$max"
    fi
}

# Ejecución: stdout a fichero (es lo que se compara); stderr a otro fichero (se muestra aparte).
# El grupo { } captura también los avisos del shell (p. ej. "Segmentation fault").
{ ./a.out < "$WORK_DIR/$INPUT_NAME" > "$RES/actual"; } 2> "$RES/stderr"
rc=$?

if [ -s "$RES/stderr" ]; then
    banner "STDERR DEL PROGRAMA (no se compara)"
    cat "$RES/stderr"
fi

banner "TEST: salida del programa vs $EXPECTED_NAME"
exp_lines=$(nlines "$EXPECTED")
act_lines=$(nlines "$RES/actual")

if cmp -s "$EXPECTED" "$RES/actual"; then
    verdict=0
    echo "RESULTADO: OK. La salida coincide exactamente con $EXPECTED_NAME ($act_lines línea(s))."
    [ "$rc" -ne 0 ] && echo "Aviso: la salida es idéntica, pero el programa terminó con estado distinto de 0."
else
    verdict=1
    vis "$EXPECTED"    > "$RES/exp.vis"
    vis "$RES/actual"  > "$RES/act.vis"
    diff \
        --unchanged-group-format='' \
        --old-line-format='  - esperado L%dn: |%l|
' \
        --new-line-format='  + obtenido L%dn: |%l|
' \
        --changed-group-format='@@HUNK C %df %dl %de %dF %dL %dE
%<%>' \
        --old-group-format='@@HUNK D %df %dl %de %dF %dL %dE
%<' \
        --new-group-format='@@HUNK A %df %dl %de %dF %dL %dE
%>' \
        "$RES/exp.vis" "$RES/act.vis" > "$RES/diff.txt"
    total=$(grep -c '^@@HUNK ' "$RES/diff.txt")
    printf '%s\n' 'Cada línea va entre |...| para ver espacios finales; tabuladores como \t y CR como \r.'
    printf '%s\n' "Los números de línea son de la SALIDA (esperada u obtenida), no de $INPUT_NAME."
    if [ "$total" -gt 0 ]; then
        show_diffs "$RES/diff.txt" "$MAX_DIFFS"
    else
        printf '\n(Los ficheros difieren, pero no en líneas visibles.)\n'
    fi
    # Diferencia solo en el salto de línea final: no se aprecia en las líneas mostradas
    if ends_nl "$EXPECTED" && ! ends_nl "$RES/actual"; then
        printf '\nNota: %s termina en salto de línea y la salida obtenida NO.\n' "$EXPECTED_NAME"
    elif ! ends_nl "$EXPECTED" && ends_nl "$RES/actual"; then
        printf '\nNota: la salida obtenida termina en salto de línea y %s NO.\n' "$EXPECTED_NAME"
    fi
    printf '\nRESULTADO: FALLO. %s diferencia(s). Líneas: esperadas %s, obtenidas %s.\n' "$total" "$exp_lines" "$act_lines"
fi

print_status "$rc"

if [ "$verdict" -ne 0 ]; then exit 1; fi
if [ "$rc" -ne 0 ]; then exit 4; fi
exit 0
