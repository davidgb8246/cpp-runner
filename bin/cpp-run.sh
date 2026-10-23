#!/usr/bin/env bash
# cpp-run.sh — lanzador del contenedor cpp-runner.
#
# Monta un proyecto C++ en el contenedor y reenvía las opciones de la imagen.
# Si el proyecto no tiene "entrada.in", pregunta si se quiere introducir la
# entrada por teclado: se escribe COMPLETA (hasta Ctrl-D) en un fichero temporal
# y después se entrega al contenedor por entrada estándar, igual que haría la
# imagen con "entrada.in".

ENGINE="${CONTAINER_ENGINE:-docker}"          # docker | podman | ...
IMAGE="${CPP_RUNNER_IMAGE:-davidgb8246/cpp-runner:latest}" # local o de Docker Hub (usuario/imagen:tag)
PROJECT_DIR="$PWD"
INPUT_NAME="entrada.in"
EXPECTED_NAME="entrada.out"
PULL=0
MODE=juez        # juez | local | test | gen | tar   (por defecto, como la imagen: juez)
MODE_ARG=""      # opción de la imagen tal como se reenviará (vacío = sin opción)

usage() {
cat <<USAGE
Uso: $(basename "$0") [DIR] [opciones del lanzador] [opción de la imagen]

Opciones del lanzador:
  -d, --dir DIR          Directorio del proyecto (por defecto: el actual; también
                         puede darse como argumento posicional).
  -I, --imagen IMAGEN    Imagen a usar. Por defecto: \$CPP_RUNNER_IMAGE o
                         davidgb8246/cpp-runner:latest (acepta usuario/imagen:tag de Docker Hub).
  -P, --pull             Descarga/actualiza la imagen antes de ejecutar.
  -h, --help             Muestra esta ayuda.

Opciones de la imagen (mutuamente excluyentes):
  (ninguna), -j, --juez            Compila con "Makefile" (juez) y ejecuta.
  -l, --local                      Compila con "Makefile.local" y ejecuta.
  -t, --test                       Modo test: como --juez, pero compara la salida con
                                   "$EXPECTED_NAME" (exacta) y muestra solo las diferencias.
                                   Exige "$INPUT_NAME" y "$EXPECTED_NAME" en el proyecto.
  -g, --generar-makefile           Genera ./Makefile estático en el proyecto.
  -T, --tar[=NOMBRE]               Crea en el proyecto un .tar SIN compresión con todos los
                                   .h, .hpp, .cpp y Makefile (por defecto: codigo.tar).
                                   El nombre solo se da con la forma larga: --tar=entrega

Entrada de datos (modos juez y local):
  - Si existe "$INPUT_NAME" en el proyecto, la imagen lo pasa por entrada estándar.
  - Si no existe y esto es un terminal, se pregunta si quieres escribir la entrada;
    se guarda entera en un temporal (termina con Ctrl-D) y luego empieza la ejecución.
  - Si no existe y la entrada estándar viene redirigida (pipe/fichero), se usa esa.

Variables de entorno: CONTAINER_ENGINE (docker), CPP_RUNNER_IMAGE,
TEST_MAX_DIFFS (máximo de diferencias mostradas con --test; por defecto 20).
El código de salida es el del contenedor: en juez/local, el del programa (o el de
make si falla la compilación); en --test: 0 OK, 1 salida distinta, 2 faltan
ficheros/uso, 3 error de compilación, 4 salida idéntica pero estado != 0.
USAGE
}

die() { echo "Error: $*" >&2; exit 2; }

set_mode() { # set_mode <modo> <opción canónica de la imagen>
    [ -z "$MODE_ARG" ] && [ "$MODE_SET" != 1 ] || die "las opciones de la imagen son mutuamente excluyentes."
    MODE_SET=1; MODE=$1; MODE_ARG=$2
}

MODE_SET=0
DIR_SET=0
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)      usage; exit 0 ;;
        -I|--imagen)    [ $# -ge 2 ] || die "$1 requiere un valor."; IMAGE=$2; shift 2 ;;
        --imagen=*)     IMAGE=${1#*=}; shift ;;
        -d|--dir)       [ $# -ge 2 ] || die "$1 requiere un valor."; PROJECT_DIR=$2; DIR_SET=1; shift 2 ;;
        --dir=*)        PROJECT_DIR=${1#*=}; DIR_SET=1; shift ;;
        -P|--pull)      PULL=1; shift ;;
        -j|--juez)               set_mode juez  --juez; shift ;;
        -l|--local)              set_mode local --local; shift ;;
        -t|--test)               set_mode test  --test; shift ;;
        -g|--generar-makefile)   set_mode gen   --generar-makefile; shift ;;
        -T|--tar)                set_mode tar   --tar; shift ;;
        --tar=*)                 [ -n "${1#*=}" ] || die "--tar= requiere un nombre."
                                 set_mode tar   "$1"; shift ;;
        -*)             die "opción desconocida: $1 (usa --help)." ;;
        *)              [ "$DIR_SET" = 0 ] || die "directorio indicado más de una vez: $1"
                        PROJECT_DIR=$1; DIR_SET=1; shift ;;
    esac
done

command -v "$ENGINE" >/dev/null 2>&1 || die "no se encuentra '$ENGINE' en el PATH (usa CONTAINER_ENGINE)."
[ -d "$PROJECT_DIR" ] || die "no existe el directorio del proyecto: $PROJECT_DIR"
PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd -P)" || die "no se puede acceder a $PROJECT_DIR"
[ -n "$IMAGE" ] || die "imagen vacía."

# ---------- Temporal de entrada (siempre se limpia) ----------
TMP_INPUT=""
cleanup() { [ -n "$TMP_INPUT" ] && rm -f "$TMP_INPUT"; }
trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM

if [ "$PULL" = 1 ]; then
    "$ENGINE" pull "$IMAGE" || { echo "Error: no se pudo descargar $IMAGE." >&2; exit 1; }
fi

RUN_FLAGS=(--rm)
MOUNT_OPT=ro                       # los modos de ejecución no necesitan escribir en el proyecto
{ [ "$MODE" = gen ] || [ "$MODE" = tar ]; } && MOUNT_OPT=rw  # generar Makefile / tar sí escriben en el proyecto

# ---------- Modo test: ambos ficheros son obligatorios (no se pregunta por teclado) ----------
if [ "$MODE" = test ]; then
    missing=""
    [ -f "$PROJECT_DIR/$INPUT_NAME" ]    || missing="$missing $INPUT_NAME"
    [ -f "$PROJECT_DIR/$EXPECTED_NAME" ] || missing="$missing $EXPECTED_NAME"
    [ -z "$missing" ] || die "el modo --test exige $INPUT_NAME y $EXPECTED_NAME en $PROJECT_DIR. Faltan:$missing"
    # Límite de diferencias mostradas: se reenvía solo si está definido
    [ -n "${TEST_MAX_DIFFS-}" ] && RUN_FLAGS+=(-e "TEST_MAX_DIFFS=$TEST_MAX_DIFFS")
fi

# ---------- Entrada de datos ----------
if [ "$MODE" != gen ] && [ "$MODE" != tar ] && [ "$MODE" != test ] && [ ! -f "$PROJECT_DIR/$INPUT_NAME" ]; then
    capture=0
    if [ -t 0 ]; then
        echo "No existe '$INPUT_NAME' en $PROJECT_DIR." >&2
        read -r -p "¿Quieres introducir los datos de entrada por teclado? [s/N] " ans
        case "$ans" in [sSyY]*) capture=1 ;; esac
        [ "$capture" = 1 ] && echo "Escribe TODA la entrada y finaliza con Ctrl-D (en una línea vacía). La ejecución empezará después." >&2
    else
        capture=1   # entrada estándar redirigida: se usa tal cual
    fi

    if [ "$capture" = 1 ]; then
        TMP_INPUT="$(mktemp "${TMPDIR:-/tmp}/cpp-run-input.XXXXXX")" || die "no se pudo crear el fichero temporal."
        cat > "$TMP_INPUT"
        if [ -t 1 ] || [ -t 2 ]; then
            echo "Entrada guardada: $(wc -l < "$TMP_INPUT" | tr -d ' ') línea(s), $(wc -c < "$TMP_INPUT" | tr -d ' ') byte(s). Ejecutando..." >&2
        fi
        RUN_FLAGS+=(-i)            # el contenedor recibe el temporal por su entrada estándar
    fi
fi

# ---------- Ejecución ----------
CMD=("$ENGINE" run "${RUN_FLAGS[@]}" -v "$PROJECT_DIR:/work:$MOUNT_OPT" "$IMAGE")
[ -n "$MODE_ARG" ] && CMD+=("$MODE_ARG")

if [ -n "$TMP_INPUT" ]; then
    "${CMD[@]}" < "$TMP_INPUT"
else
    "${CMD[@]}"
fi
rc=$?
exit "$rc"
