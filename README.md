# cpp-runner

Contenedor Docker (basado en Debian/glibc) que compila y ejecuta un proyecto C++ montado desde tu máquina, usando los `Makefile` que viven **dentro de la imagen** (nunca se mezclan con tu código).

- Compila con `g++` (C++17) y muestra **todos** los mensajes del compilador.
- Ejecuta el programa y muestra **su salida por separado**.
- Termina mostrando el **código de estado** del programa.
- Si en tu proyecto existe un fichero `entrada.in`, su contenido se pasa por entrada estándar al programa.
- Incluye un **modo test** (`--test`) que compara la salida con un `entrada.out` esperado y muestra solo las diferencias.

---

## Estructura del repositorio

```
cpp-runner/
├── README.md                 Esta documentación
├── bin/
│   └── cpp-run.sh            Lanzador para el host (Linux/WSL/macOS). No entra en la imagen.
└── image/                    Contexto de build de la imagen Docker
    ├── Dockerfile
    ├── .dockerignore
    ├── entrypoint.sh         Lógica del contenedor (modos, compilación, test, generación)
    └── makefiles/            Se copian a /opt/mk/ dentro de la imagen
        ├── Makefile          Modo juez (-j, -t)
        ├── Makefile.local    Modo local (-l)
        └── gen.mk            Auxiliar de --generar-makefile
```

| Carpeta | Qué contiene | ¿Va dentro de la imagen? |
|---|---|---|
| `image/` | Todo lo necesario para construir la imagen: es el **contexto de `docker build`**. | Sí |
| `image/makefiles/` | Los `Makefile` que el contenedor usa en lugar de los del proyecto del usuario. Deben conservar estos nombres (`Makefile`, `Makefile.local`, `gen.mk`): el entrypoint los busca en `/opt/mk/`. | Sí (en `/opt/mk/`) |
| `bin/` | Herramientas que se ejecutan en tu máquina, no en el contenedor. | No |

---

## 1. Requisitos

| Sistema | Qué necesitas |
|---|---|
| Windows | [Docker Desktop](https://www.docker.com/products/docker-desktop/) en marcha (con WSL 2 o Hyper-V). La unidad donde esté tu proyecto debe estar compartida con Docker (por defecto `C:`). |
| Linux | Docker (o Podman) y el script `cpp-run.sh`. |

Construir la imagen, **desde la raíz del repositorio** (una sola vez, y de nuevo cada vez que cambies algo dentro de `image/`, por ejemplo al actualizar a una versión con `--test`):

```bash
docker build -t cpp-runner image/
```

El comando es el mismo en PowerShell, CMD y Linux. El contexto es `image/`, así que `bin/` y este README no se envían a Docker.

Si la imagen ya está publicada, sustituye `cpp-runner` por su nombre completo (por ejemplo `usuario/cpp-runner:1.0`) en todos los comandos de este documento.

---

## 2. Opciones de la imagen

La imagen admite **una única opción** (son mutuamente excluyentes; dos a la vez dan error con código 2).

| Opción | Corta | Qué hace |
|---|---|---|
| *(ninguna)* | | Igual que `--juez`: compila con `Makefile` y ejecuta. |
| `--juez` | `-j` | Compila con **`Makefile`** (el del juez virtual: `-std=c++17 -Wall -Wno-deprecated -O2`) y ejecuta. Muestra la salida del programa. |
| `--local` | `-l` | Compila con **`Makefile.local`** (para pruebas locales: añade `-Wextra`, más avisos, y seguimiento de dependencias `-MMD -MP`) y ejecuta. |
| `--test` | `-t` | **Modo test.** Igual que `--juez` al compilar y ejecutar, pero en lugar de mostrar la salida del programa la **compara con `entrada.out`** y muestra solo las diferencias. Exige `entrada.in` y `entrada.out`. Ver sección 3. |
| `--generar-makefile` | `-g` | **No compila ni ejecuta.** Genera un `Makefile` estático en tu proyecto, con las rutas de `.cpp` e *includes* ya fijadas, siguiendo la lógica del `Makefile` del juez. |
| `--tar[=NOMBRE]` | `-T` | **No compila ni ejecuta.** Crea en tu proyecto un fichero `.tar` **sin compresión** con todos los `.h`, `.hpp`, `.cpp` y `Makefile` que encuentre (recursivo, sin distinguir mayúsculas, rutas relativas). Sin nombre se llama `codigo.tar`; `--tar=entrega` crea `entrega.tar` (la extensión `.tar` se añade si falta). También vale la variable `TAR_NAME`. |
| `--help` | `-h` | Muestra la ayuda de la imagen. |

Detalles útiles:

- El proyecto se **copia** a un directorio temporal dentro del contenedor y se compila allí: tu carpeta no se llena de `.o` ni de `a.out`, y puede montarse en **solo lectura** (`:ro`).
- Cualquier `Makefile` propio que tengas en el proyecto se **ignora** en los modos de compilación.
- `--generar-makefile` **sobrescribe** un `Makefile` existente (avisa antes). Necesita montaje de lectura y escritura.
- `--tar` equivale a `tar -cf NOMBRE.tar $(find . -type f \( -iname "*.h" -o -iname "*.hpp" -o -iname "*.cpp" -o -iname "Makefile" \) -printf "%P\n")`, pero admite nombres con espacios, excluye el propio `.tar`, **sobrescribe** uno existente con el mismo nombre y necesita montaje de lectura y escritura. Falla (código 1) si no encuentra ningún fichero.
- Si cambias o añades ficheros `.cpp`, vuelve a generar el `Makefile` estático.

### Entrada de datos (modos `--juez`, `--local`)

| Situación | Resultado |
|---|---|
| Existe `entrada.in` en tu proyecto | Su contenido se pasa **íntegro** por entrada estándar al programa. |
| No existe y no hay entrada conectada | El programa recibe una entrada vacía (EOF inmediato). |
| No existe y conectas la entrada (`-i`) | El programa lee de lo que le envíes (teclado, `<` o *pipe*). |

En el modo `--test` la entrada es siempre `entrada.in` (obligatorio).

### Formato de la salida (modos `--juez` y `--local`)

```
===== COMPILACIÓN (Makefile) =====
g++ -I. -std=c++17 -Wall -Wno-deprecated -O2 -c main.cpp -o main.o
...avisos y errores del compilador...

===== SALIDA DEL PROGRAMA =====
...lo que imprime tu programa...

===== CÓDIGO DE ESTADO =====
0
```

- Si la **compilación falla**: se muestran los errores, el programa no se ejecuta y el código de estado es el de `make` (normalmente `2`).
- Si el programa muere por una señal se indica, por ejemplo `139` + `(terminado por la señal SIGSEGV)`.
- El contenedor termina con ese mismo código de salida.

---

## 3. Modo test (`--test`)

Sirve para comprobar de golpe uno o varios casos de prueba: se ejecuta el programa con `entrada.in` y se compara su salida estándar con `entrada.out`.

### Qué necesita

En la carpeta del proyecto (la que montas en `/work`):

| Fichero | Contenido |
|---|---|
| `entrada.in` | Los datos de entrada, tal cual los recibiría el programa. Puede contener varios casos si tu programa los procesa en una sola ejecución. |
| `entrada.out` | La salida esperada **exacta**. |

Si falta alguno de los dos, termina con un error (código 2) indicando cuál, sin compilar.

### Qué hace

1. Compila con **`Makefile`** (el mismo que `--juez`) y muestra todos los mensajes de compilación.
2. Ejecuta el programa con `entrada.in` por entrada estándar.
3. Compara su salida con `entrada.out`.
4. Muestra el resultado y, al final, el código de estado del programa.

**No se muestra la salida completa del programa**, solo las diferencias con lo esperado. Si el programa escribe por `stderr`, se muestra en un bloque aparte (no se compara).

### La comparación es exacta

Se compara byte a byte: espacios, espacios finales, tabuladores, retornos de carro (`\r`) y el **salto de línea final** cuentan. No se ignora nada.

### Cómo se muestran las diferencias

Cada diferencia es un bloque de líneas consecutivas distintas, de uno de estos tres tipos:

| Tipo | Significado |
|---|---|
| **líneas distintas** | Hay líneas en ambas salidas, pero con contenido diferente. |
| **FALTAN líneas** | La salida esperada tiene líneas que la salida del programa no tiene. |
| **SOBRAN líneas** | La salida del programa tiene líneas que no están en `entrada.out`. |

> **Los números de línea son de la salida, no de `entrada.in`.** La salida puede tener más o menos líneas que la entrada (un caso de entrada puede producir muchas líneas de salida), así que no es posible saber qué línea de `entrada.in` originó cada diferencia. Cada diferencia indica la línea en la salida esperada (`esperado Lx`) y en la obtenida (`obtenido Lx`).

Para ver diferencias que a simple vista no se aprecian, cada línea se muestra entre `|...|` (así se ven los espacios finales), los tabuladores se escriben `\t` y los retornos de carro `\r`. Si la única diferencia es que un fichero termina en salto de línea y el otro no, se indica con una nota.

### Ejemplo de salida

```
===== COMPILACIÓN (Makefile) =====
g++ -I. -std=c++17 -Wall -Wno-deprecated -O2 -c m.cpp -o m.o
g++ ./m.o -o a.out

===== TEST: salida del programa vs entrada.out =====
Cada línea va entre |...| para ver espacios finales; tabuladores como \t y CR como \r.
Los números de línea son de la SALIDA (esperada u obtenida), no de entrada.in.

Diferencia 1 de 2: líneas distintas (esperado: 2 | obtenido: 2)
  - esperado L2: |XXXX|
  + obtenido L2: |caso 2 fila 2|

Diferencia 2 de 2: FALTAN líneas en la salida (esperado: 6-7; la salida obtenida sigue tras su línea 5)
  - esperado L6: |LINEA QUE FALTA 1|
  - esperado L7: |LINEA QUE FALTA 2|

RESULTADO: FALLO. 2 diferencia(s). Líneas: esperadas 7, obtenidas 5.

===== CÓDIGO DE ESTADO =====
0
```

Si todo coincide:

```
===== TEST: salida del programa vs entrada.out =====
RESULTADO: OK. La salida coincide exactamente con entrada.out (5 línea(s)).

===== CÓDIGO DE ESTADO =====
0
```

### Límite de diferencias mostradas

Por defecto se muestran como máximo **20** diferencias y se indica cuántas quedan sin mostrar. Se cambia con la variable de entorno `TEST_MAX_DIFFS`:

- Docker directo: `-e TEST_MAX_DIFFS=50` (ver sección 4).
- `cpp-run.sh`: `TEST_MAX_DIFFS=50 cpp-run.sh -t` (se reenvía solo si la defines).

### Códigos de salida del modo test

Aquí el código de salida del contenedor **no** es el del programa (ese se muestra en el bloque `CÓDIGO DE ESTADO`), sino el resultado del test:

| Código | Significado |
|---|---|
| `0` | **OK**: la salida coincide exactamente y el programa terminó con estado 0. |
| `1` | La salida es **distinta** de `entrada.out`. |
| `2` | Error de uso: faltan `entrada.in` / `entrada.out`, o parámetros no válidos. |
| `3` | **Error de compilación**. |
| `4` | Salida idéntica, pero el programa terminó con estado distinto de 0 (se muestra un aviso). |

---

## 4. Ejecución directa en Windows

Los comandos se lanzan **desde la carpeta de tu proyecto**. La parte importante es `-v`, que monta esa carpeta en `/work` dentro del contenedor.

### PowerShell

```powershell
# Modo juez (por defecto)
docker run --rm -v "${PWD}:/work:ro" cpp-runner

# Modo local
docker run --rm -v "${PWD}:/work:ro" cpp-runner --local

# Modo test (necesita entrada.in y entrada.out en la carpeta)
docker run --rm -v "${PWD}:/work:ro" cpp-runner --test

# Modo test mostrando hasta 50 diferencias
docker run --rm -e TEST_MAX_DIFFS=50 -v "${PWD}:/work:ro" cpp-runner --test

# Generar Makefile estático (necesita escritura: sin :ro)
docker run --rm -v "${PWD}:/work" cpp-runner --generar-makefile

# Crear codigo.tar (sin compresión) con .h/.hpp/.cpp/Makefile; con nombre: --tar=entrega
docker run --rm -v "${PWD}:/work" cpp-runner --tar

# Ayuda
docker run --rm cpp-runner --help
```

### CMD (símbolo del sistema)

```bat
docker run --rm -v "%cd%:/work:ro" cpp-runner
docker run --rm -v "%cd%:/work:ro" cpp-runner --local
docker run --rm -v "%cd%:/work:ro" cpp-runner --test
docker run --rm -e TEST_MAX_DIFFS=50 -v "%cd%:/work:ro" cpp-runner --test
docker run --rm -v "%cd%:/work" cpp-runner --generar-makefile
```

### Git Bash

Git Bash convierte rutas como `/work` en rutas de Windows y rompe el montaje. Desactiva esa conversión:

```bash
MSYS_NO_PATHCONV=1 docker run --rm -v "$PWD:/work:ro" cpp-runner --local
MSYS_NO_PATHCONV=1 docker run --rm -v "$PWD:/work:ro" cpp-runner --test
```

### Ver el código de salida

| Terminal | Comando justo después de ejecutar |
|---|---|
| PowerShell | `$LASTEXITCODE` |
| CMD | `echo %ERRORLEVEL%` |
| Git Bash | `echo $?` |

### Entrada de datos en Windows (modos `--juez` y `--local`)

**Lo más fiable: crea `entrada.in`** en la carpeta del proyecto. No hace falta ningún parámetro extra.

Si prefieres enviar datos sin `entrada.in`, añade `-i` (conecta la entrada estándar):

```powershell
# Desde un fichero cualquiera
Get-Content .\datos.txt | docker run --rm -i -v "${PWD}:/work:ro" cpp-runner

# Escribiendo por teclado (finaliza con Ctrl+Z y Enter)
docker run --rm -i -v "${PWD}:/work:ro" cpp-runner
```

```bat
docker run --rm -i -v "%cd%:/work:ro" cpp-runner < datos.txt
```

> Si existe `entrada.in`, tiene prioridad: la imagen lo usa y no lee de `-i`. En el modo `--test` no se usa `-i`: la entrada es siempre `entrada.in`.

### Alternativa: usar `cpp-run.sh` desde WSL

Si tienes WSL 2 con la integración de Docker Desktop activada, puedes abrir una terminal de Linux (por ejemplo `wsl`) y seguir la sección 5. Para mayor velocidad, guarda el proyecto dentro del sistema de ficheros de WSL (`~/proyectos/...`) en lugar de en `/mnt/c/...`.

---

## 5. Ejecución en Linux con `cpp-run.sh`

`cpp-run.sh` se encarga del `docker run`, del montaje y de la entrada de datos.

### Instalación

El lanzador está en `bin/cpp-run.sh` y no depende de dónde esté el repositorio. Los ejemplos de esta sección usan `cpp-run.sh` a secas, suponiendo que está en tu `PATH`.

```bash
chmod +x bin/cpp-run.sh

# Opción A: instalarlo en el PATH (recomendado)
sudo install -m 0755 bin/cpp-run.sh /usr/local/bin/cpp-run.sh

# Opción B: sin instalar, usarlo por su ruta completa desde cualquier carpeta
~/cpp-runner/bin/cpp-run.sh ~/practica1 --local
```

### Uso

```
cpp-run.sh [DIR] [opciones del lanzador] [opción de la imagen]
```

El orden de los parámetros es libre.

### Opciones del lanzador

| Parámetro | Para qué sirve | Por defecto |
|---|---|---|
| `DIR` / `-d`, `--dir DIR` | Carpeta del proyecto a montar. Puede darse como argumento suelto o con `-d`. | Directorio actual |
| `-I`, `--imagen IMAGEN` | Imagen a usar (local o de Docker Hub, `usuario/imagen:tag`). También `--imagen=IMAGEN`. | `$CPP_RUNNER_IMAGE` o `davidgb8246/cpp-runner:latest` |
| `-P`, `--pull` | Descarga/actualiza la imagen antes de ejecutar. | No descarga |
| `-h`, `--help` | Muestra la ayuda del lanzador. | |

### Opciones de la imagen (se reenvían tal cual)

| Parámetro | Efecto |
|---|---|
| *(ninguno)*, `-j`, `--juez` | Compila con `Makefile` y ejecuta. |
| `-l`, `--local` | Compila con `Makefile.local` y ejecuta. |
| `-t`, `--test` | Modo test: compara la salida con `entrada.out` y muestra las diferencias. |
| `-g`, `--generar-makefile` | Genera `./Makefile` estático en el proyecto. |
| `-T`, `--tar[=NOMBRE]` | Crea `NOMBRE.tar` (por defecto `codigo.tar`) sin compresión con los `.h`, `.hpp`, `.cpp` y `Makefile`. El nombre solo se indica con la forma larga (`--tar=entrega`). |

Son mutuamente excluyentes, igual que en la imagen.

### Variables de entorno

| Variable | Para qué sirve | Por defecto |
|---|---|---|
| `CPP_RUNNER_IMAGE` | Imagen a usar sin pasar `-I` cada vez. | `davidgb8246/cpp-runner:latest` |
| `CONTAINER_ENGINE` | Motor de contenedores (`docker`, `podman`...). | `docker` |
| `TEST_MAX_DIFFS` | Máximo de diferencias mostradas con `--test`. Solo se reenvía al contenedor si la defines. | `20` |

### Entrada de datos con el lanzador

| Situación | Qué hace `cpp-run.sh` |
|---|---|
| Existe `entrada.in` | No pregunta nada; la imagen lo usa. |
| No existe y estás en un terminal | Pregunta `¿Quieres introducir los datos de entrada por teclado? [s/N]`. Con `s` escribes **toda** la entrada y finalizas con `Ctrl-D`; se guarda en un fichero temporal y **solo entonces** empieza la ejecución. Con `n` (o Enter) el programa recibe entrada vacía. |
| No existe y la entrada viene redirigida (`<` o *pipe*) | Usa esa entrada directamente, sin preguntar. |
| Modo `-t` | **Nunca pregunta ni usa teclado**: exige `entrada.in` y `entrada.out`; si falta alguno, da error (código 2) **antes** de lanzar el contenedor. |
| Modo `-g` | Nunca pregunta ni usa entrada. |

El fichero temporal se borra siempre al terminar (también con `Ctrl-C`). Tu carpeta no se modifica.

### Ejemplos

```bash
# Modo juez en el directorio actual
cpp-run.sh

# Modo local en otra carpeta
cpp-run.sh ~/practica1 --local

# Modo test (necesita entrada.in y entrada.out en la carpeta)
cpp-run.sh -t
cpp-run.sh ~/practica1 --test

# Modo test mostrando más diferencias
TEST_MAX_DIFFS=100 cpp-run.sh -t

# Modo test dentro de un script: actuar según el resultado
cpp-run.sh -t > informe.txt
case $? in
  0) echo "OK" ;;
  1) echo "Salida distinta: revisa informe.txt" ;;
  3) echo "No compila" ;;
esac

# Generar el Makefile estático
cpp-run.sh -g
cpp-run.sh ~/practica1 --generar-makefile

# Crear el tar de entrega (codigo.tar, o el nombre que se indique)
cpp-run.sh -T
cpp-run.sh --tar=practica1

# Entrada desde un fichero o pipe (sin necesidad de entrada.in)
cpp-run.sh --local < datos.txt
echo "3 4" | cpp-run.sh

# Usar una imagen concreta de Docker Hub, descargándola antes
cpp-run.sh -I usuario/cpp-runner:1.0 -P --local

# Fijar la imagen para toda la sesión
export CPP_RUNNER_IMAGE=usuario/cpp-runner:1.0
cpp-run.sh --local

# Usar Podman
CONTAINER_ENGINE=podman cpp-run.sh
```

---

## 6. Resumen rápido de casos

| Quiero... | Windows (PowerShell) | Linux |
|---|---|---|
| Probar como el juez | `docker run --rm -v "${PWD}:/work:ro" cpp-runner` | `cpp-run.sh` |
| Probar en local (más avisos) | `... cpp-runner --local` | `cpp-run.sh -l` |
| Comprobar la salida contra `entrada.out` | `... cpp-runner --test` | `cpp-run.sh -t` |
| Ver más diferencias en el test | `docker run --rm -e TEST_MAX_DIFFS=50 -v "${PWD}:/work:ro" cpp-runner --test` | `TEST_MAX_DIFFS=50 cpp-run.sh -t` |
| Generar `Makefile` estático | `docker run --rm -v "${PWD}:/work" cpp-runner -g` | `cpp-run.sh -g` |
| Crear `.tar` sin comprimir con las fuentes | `docker run --rm -v "${PWD}:/work" cpp-runner --tar=entrega` | `cpp-run.sh --tar=entrega` |
| Usar un fichero de entrada | Crear `entrada.in` | Crear `entrada.in` |
| Escribir la entrada a mano | `docker run --rm -i -v "${PWD}:/work:ro" cpp-runner` | `cpp-run.sh` y responder `s` |
| Usar otra imagen | Cambiar `cpp-runner` por el nombre | `-I nombre` o `CPP_RUNNER_IMAGE` |

---

## 7. Problemas frecuentes

| Síntoma | Causa y solución |
|---|---|
| `--test` da "opción desconocida" | La imagen es antigua. Reconstrúyela con `docker build -t cpp-runner image/` desde la raíz del repositorio (o descarga la versión nueva con `-P`). |
| `Error: el modo --test exige entrada.in y entrada.out ... Faltan: ...` | Falta alguno de los dos ficheros en la carpeta del proyecto. Créalo. Si no se espera ninguna salida, `entrada.out` puede estar vacío. |
| El test falla pero las líneas "se ven iguales" | Hay diferencias invisibles: espacios al final, tabuladores, `\r` o el salto de línea final. Fíjate en los `|...|`, en `\t`, `\r` y en la nota sobre el salto de línea final. |
| No sé a qué línea de `entrada.in` corresponde una diferencia | No es posible: las líneas indicadas son de la **salida**, y la salida puede ser más larga o más corta que la entrada. Usa el número de línea de la salida (`esperado Lx` / `obtenido Lx`). |
| Windows: `invalid mode` / el montaje falla | Ruta con `:` mal interpretada. Usa `"${PWD}:/work"` (PowerShell) o `"%cd%:/work"` (CMD) y entrecomíllala. En Git Bash añade `MSYS_NO_PATHCONV=1`. |
| Windows: carpeta vacía dentro del contenedor | La unidad no está compartida con Docker Desktop. Actívala en *Settings → Resources → File sharing*. |
| `Error: no se pudo escribir ... (¿montaje de solo lectura?)` | En `--generar-makefile` o `--tar` has montado con `:ro`. Quita `:ro`. |
| El programa no recibe mis datos (`--juez`/`--local`) | Falta `-i` (Windows) o no existe `entrada.in`. Con `cpp-run.sh` responde `s` a la pregunta. |
| Aparece "La compilación ha fallado" | Revisa los mensajes de la sección de compilación; el programa no se ejecutó. |
| Los ficheros que escribe mi programa no aparecen | Se ejecuta sobre una copia temporal, por lo que sus ficheros de salida desaparecen al terminar. Usa la salida estándar. |
| `Error: no se encuentra 'docker'` (lanzador) | Docker no está en el `PATH`; instálalo o usa `CONTAINER_ENGINE`. |
