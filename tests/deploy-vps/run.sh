#!/usr/bin/env bash
# Pruebas del paso de despliegue de .github/workflows/deploy-vps.yml sin VPS.
#
# Extrae del workflow el script del paso «Desplegar (...)» tal y como lo ejecuta
# Actions (el bloque `run:` sin la sangría de YAML) y lo lanza con ssh, docker y
# curl falsos (fake-bin/). El ssh falso ejecuta en local lo que recibiría el VPS,
# así que se prueban la cabecera con printf %q y el script remoto sin copiarlos.
# Cada escenario comprueba el estado final del «VPS»: imagen de cada contenedor,
# etiquetas locales (:latest), .deploy-image-tag y código de salida, y simula
# después un `docker compose up -d` manual sin la variable de la etiqueta.
#
# Uso: bash tests/deploy-vps/run.sh   (bash, awk y coreutils; si shellcheck está
# instalado revisa además el script remoto generado, y en CI es obligatorio).
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
WORKFLOW=$HERE/../../.github/workflows/deploy-vps.yml
STEP='Desplegar (compose pull + up, comprobación y rollback)'
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# --- Script del paso ------------------------------------------------------
# Bloque `run: |` del paso: las líneas con al menos la sangría de la primera,
# sin esa sangría. Las líneas en blanco intermedias se conservan.
awk -v name="- name: $STEP" '
  !step { if (index($0, name)) step = 1; next }
  !run  { if ($0 ~ /^[[:space:]]*run: \|[[:space:]]*$/) run = 1; next }
  {
    if ($0 ~ /^[[:space:]]*$/) { blanks = blanks "\n"; next }
    match($0, /^ */)
    if (indent == "") indent = RLENGTH
    if (RLENGTH < indent) exit
    printf "%s%s\n", blanks, substr($0, indent + 1)
    blanks = ""
  }' "$WORKFLOW" > "$WORK/step.sh"
if ! grep -q '^ssh -F ' "$WORK/step.sh"; then
  echo "No se encontró el paso «$STEP» en $WORKFLOW" >&2
  exit 1
fi
bash -n "$WORK/step.sh"

# --- Escenarios -----------------------------------------------------------
FAILED=0
SHOW_OUT=""

# scenario NOMBRE: VPS simulado vacío; el compose vive en ~/app.
scenario() {
  NAME=$1
  S=$WORK/$NAME
  APP_DIR=$S/home/app
  mkdir -p "$APP_DIR" "$S/runner/ssh"
  : > "$S/runner/ssh/config"
  local f
  for f in compose.tsv registry.tsv tags.tsv ids containers.tsv healthy calls.log curl.log; do
    : > "$S/$f"
  done
  echo api > "$S/health_service"
  echo "== $NAME"
}
add_id()    { grep -qxF -- "$1" "$S/ids" || printf '%s\n' "$1" >> "$S/ids"; }
service()   { printf '%s\t%s\n' "$1" "$2" >> "$S/compose.tsv"; }  # servicio plantilla
published() { printf '%s\t%s\n' "$1" "$2" >> "$S/registry.tsv"; } # referencia id
local_tag() { printf '%s\t%s\n' "$1" "$2" >> "$S/tags.tsv"; add_id "$2"; }
running() { # servicio referencia id
  printf 'old-%s\t%s\t%s\t%s\n' "$1" "$1" "$2" "$3" >> "$S/containers.tsv"
  add_id "$3"
}
healthy() { printf '%s\n' "$@" >> "$S/healthy"; }

# deploy ETIQUETA [VAR=valor...]: ejecuta el paso con las entradas por defecto
# (sobrescribibles con VAR=valor) y deja la salida en $S/out y el código en RC.
deploy() {
  local tag=$1
  shift
  set +e
  # shellcheck disable=SC2088 # la tilde la expande el script remoto, como en el VPS
  env -i PATH="$HERE/fake-bin:$PATH" HOME="$S/home" RUNNER_TEMP="$S/runner" FAKE_STATE="$S" \
    IMAGE=ghcr.io/jaisato/app TAG="$tag" TAG_VARIABLE=IMAGE_TAG COMPOSE_PATH='~/app' \
    COMPOSE_FILES= SERVICES= HEALTH_URL=http://localhost:8000/health HEALTH_RETRIES=3 \
    HEALTH_INTERVAL=0 DEPLOY_USER=deploy "$@" \
    bash -e "$WORK/step.sh" > "$S/out" 2>&1
  RC=$?
  set -e
}

# after_manual_up SERVICIO ID: un `docker compose up -d` a mano en el VPS, sin la
# variable de la etiqueta, funciona y deja el servicio con esa imagen.
after_manual_up() {
  (cd "$APP_DIR" && env -i PATH="$HERE/fake-bin:$PATH" FAKE_STATE="$S" docker compose up -d > /dev/null 2>&1) &&
    runs "$1" "$2"
}

check() { # descripción comando...
  local desc=$1
  shift
  if "$@"; then
    echo "  ok    $desc"
  else
    echo "  FALLO $desc"
    FAILED=1
    SHOW_OUT=1
  fi
}
done_scenario() {
  if [ -n "$SHOW_OUT" ]; then
    echo "  --- salida del paso ---"
    sed 's/^/  | /' "$S/out"
    echo "  --- docker ---"
    sed 's/^/  | /' "$S/calls.log"
  fi
  SHOW_OUT=""
}

exit_code() { [ "$RC" -eq "$1" ]; }
tag_is() { [ "$(awk -F'\t' -v k="$1" '$1 == k { print $2 }' "$S/tags.tsv")" = "$2" ]; } # ref id
no_tag() { ! awk -F'\t' -v k="$1" '$1 == k { f = 1 } END { exit !f }' "$S/tags.tsv"; }
runs() { # servicio id: todos sus contenedores (al menos uno) con esa imagen
  [ "$(awk -F'\t' -v s="$1" '$2 == s { print $4 }' "$S/containers.tsv" | sort -u)" = "$2" ]
}
tag_file() { [ "$(cat "$APP_DIR/.deploy-image-tag" 2> /dev/null)" = "$1" ]; }
no_tag_file() { [ ! -e "$APP_DIR/.deploy-image-tag" ]; }
said() { grep -qF -- "$1" "$S/out"; }
called() { grep -qF -- "$1" "$S/calls.log"; }
not() { ! "$@"; }

# api y worker comparten la imagen de la aplicación; redis es ajena. En
# ejecución, 1.1.0; el :latest local, en una versión aún más vieja (lo que dejaba
# el workflow antes de fijar la versión): es lo que un `up -d` manual recrearía.
base_app() {
  service api 'ghcr.io/jaisato/app:{IMAGE_TAG}'
  service worker 'ghcr.io/jaisato/app:{IMAGE_TAG}'
  service redis 'redis:7-alpine'
  published ghcr.io/jaisato/app:1.1.0 sha256:app110
  published ghcr.io/jaisato/app:1.2.0 sha256:app120
  published redis:7-alpine sha256:redis7
  local_tag ghcr.io/jaisato/app:1.1.0 sha256:app110
  local_tag ghcr.io/jaisato/app:latest sha256:app100
  local_tag redis:7-alpine sha256:redis7
  running api ghcr.io/jaisato/app:1.1.0 sha256:app110
  running worker ghcr.io/jaisato/app:1.1.0 sha256:app110
  running redis redis:7-alpine sha256:redis7
}

scenario despliegue-ok
base_app
healthy sha256:app110 sha256:app120
deploy 1.2.0 SERVICES="api worker"
check "termina bien" exit_code 0
check "api en 1.2.0" runs api sha256:app120
check "worker en 1.2.0" runs worker sha256:app120
check ":latest local apunta a 1.2.0" tag_is ghcr.io/jaisato/app:latest sha256:app120
check ".deploy-image-tag = 1.2.0" tag_file 1.2.0
check "redis no se toca" runs redis sha256:redis7
check "no crea redis:latest" no_tag redis:latest
check "trabaja en ~/app (tilde expandida en el VPS)" called "cwd=$APP_DIR "
check "docker image prune -f" called ":: docker image prune -f"
check "un up -d manual sin IMAGE_TAG sigue en 1.2.0" after_manual_up api sha256:app120
done_scenario

scenario health-ko
base_app
healthy sha256:app110
deploy 1.2.0 SERVICES="api worker"
check "termina en error" exit_code 1
check "avisa de la URL" said "::error::http://localhost:8000/health no respondió"
check "api vuelve a 1.1.0" runs api sha256:app110
check "worker vuelve a 1.1.0" runs worker sha256:app110
check "rollback verificado" said "Rollback verificado"
check ":latest local apunta a la restaurada (1.1.0)" tag_is ghcr.io/jaisato/app:latest sha256:app110
check ".deploy-image-tag = 1.1.0" tag_file 1.1.0
check "sin prune" not called ":: docker image prune"
check "un up -d manual sin IMAGE_TAG sigue en 1.1.0" after_manual_up api sha256:app110
done_scenario

scenario up-ko
base_app
healthy sha256:app110 sha256:app120
deploy 1.2.0 SERVICES="api worker" FAKE_UP_FAIL=1
check "termina en error" exit_code 1
check "avisa del fallo de up -d" said "::error::docker compose up -d falló"
check "api (borrado a medias) vuelve a 1.1.0" runs api sha256:app110
check "worker vuelve a 1.1.0" runs worker sha256:app110
check "rollback verificado" said "Rollback verificado"
check ":latest local apunta a la restaurada (1.1.0)" tag_is ghcr.io/jaisato/app:latest sha256:app110
check ".deploy-image-tag = 1.1.0" tag_file 1.1.0
check "un up -d manual sin IMAGE_TAG sigue en 1.1.0" after_manual_up api sha256:app110
done_scenario

scenario rollback-ko
base_app
healthy sha256:app110
deploy 1.2.0 SERVICES="api worker" FAKE_UP_FAIL=2
check "termina en error" exit_code 1
check "avisa de que el rollback no responde" said "::error::El rollback a ghcr.io/jaisato/app:1.1.0 no responde"
check ":latest local apunta igualmente a 1.1.0" tag_is ghcr.io/jaisato/app:latest sha256:app110
check ".deploy-image-tag = 1.1.0" tag_file 1.1.0
done_scenario

scenario pull-ko
base_app
healthy sha256:app110 sha256:app120
deploy 1.3.0 SERVICES="api worker"
check "termina en error" exit_code 1
check "avisa del fallo de pull" said "::error::docker compose pull falló"
check "no hace up -d" not called ":: docker compose up"
check "api sigue en 1.1.0" runs api sha256:app110
check "worker sigue en 1.1.0" runs worker sha256:app110
check ":latest local apunta a lo que está en ejecución" tag_is ghcr.io/jaisato/app:latest sha256:app110
check ".deploy-image-tag = 1.1.0" tag_file 1.1.0
done_scenario

# tag=latest: el pull mueve :latest; no hay nada que reetiquetar si va bien, y
# el rollback tiene que devolverlo a la imagen anterior.
base_latest() {
  service api 'ghcr.io/jaisato/app:{IMAGE_TAG}'
  published ghcr.io/jaisato/app:latest sha256:app120
  local_tag ghcr.io/jaisato/app:latest sha256:app110
  running api ghcr.io/jaisato/app:latest sha256:app110
}

scenario latest-ok
base_latest
healthy sha256:app110 sha256:app120
deploy latest
check "termina bien" exit_code 0
check "api en la nueva" runs api sha256:app120
check ":latest local es la del pull" tag_is ghcr.io/jaisato/app:latest sha256:app120
check "ningún docker tag" not called ":: docker tag "
check ".deploy-image-tag = latest" tag_file latest
done_scenario

scenario latest-health-ko
base_latest
healthy sha256:app110
deploy latest
check "termina en error" exit_code 1
check "api vuelve a la anterior" runs api sha256:app110
check ":latest local vuelve a la anterior (el pull la había movido)" tag_is ghcr.io/jaisato/app:latest sha256:app110
check ".deploy-image-tag = latest" tag_file latest
check "un up -d manual sigue en la anterior" after_manual_up api sha256:app110
done_scenario

scenario latest-pull-parcial
service api 'ghcr.io/jaisato/app:{IMAGE_TAG}'
service mcp 'ghcr.io/jaisato/app-mcp:{IMAGE_TAG}'
published ghcr.io/jaisato/app:latest sha256:app120
published ghcr.io/jaisato/app-mcp:latest sha256:mcp120
local_tag ghcr.io/jaisato/app:latest sha256:app110
local_tag ghcr.io/jaisato/app-mcp:latest sha256:mcp110
running api ghcr.io/jaisato/app:latest sha256:app110
running mcp ghcr.io/jaisato/app-mcp:latest sha256:mcp110
deploy latest FAKE_PULL_FAIL=partial
check "termina en error" exit_code 1
check "no hace up -d" not called ":: docker compose up"
check ":latest de la imagen ya descargada vuelve a la que corre" tag_is ghcr.io/jaisato/app:latest sha256:app110
check ":latest de la otra no cambia" tag_is ghcr.io/jaisato/app-mcp:latest sha256:mcp110
done_scenario

# Como agentmesh: varias imágenes con la misma variable (AM_IMAGE_TAG), `image`
# solo nombra una, todos los servicios, COMPOSE_FILE y ruta absoluta. sidecar es
# una imagen ajena que casualmente tiene la etiqueta que se despliega.
base_multi() {
  service api 'ghcr.io/jaisato/agentmesh-app:{AM_IMAGE_TAG}'
  service ui 'ghcr.io/jaisato/agentmesh-app:{AM_IMAGE_TAG}'
  service mcp-docs 'ghcr.io/jaisato/agentmesh-mcp-docs:{AM_IMAGE_TAG}'
  service sidecar 'example/sidecar:0.2.0'
  published ghcr.io/jaisato/agentmesh-app:0.1.0 sha256:app010
  published ghcr.io/jaisato/agentmesh-app:0.2.0 sha256:app020
  published ghcr.io/jaisato/agentmesh-mcp-docs:0.1.0 sha256:mcp010
  published ghcr.io/jaisato/agentmesh-mcp-docs:0.2.0 sha256:mcp020
  published example/sidecar:0.2.0 sha256:side
  local_tag ghcr.io/jaisato/agentmesh-app:0.1.0 sha256:app010
  local_tag ghcr.io/jaisato/agentmesh-mcp-docs:0.1.0 sha256:mcp010
  local_tag ghcr.io/jaisato/agentmesh-mcp-docs:latest sha256:mcp000
  local_tag example/sidecar:0.2.0 sha256:side
  running api ghcr.io/jaisato/agentmesh-app:0.1.0 sha256:app010
  running ui ghcr.io/jaisato/agentmesh-app:0.1.0 sha256:app010
  running mcp-docs ghcr.io/jaisato/agentmesh-mcp-docs:0.1.0 sha256:mcp010
  running sidecar example/sidecar:0.2.0 sha256:side
}
deploy_multi() {
  deploy 0.2.0 IMAGE=ghcr.io/jaisato/agentmesh-app TAG_VARIABLE=AM_IMAGE_TAG \
    COMPOSE_PATH="$APP_DIR" COMPOSE_FILES=compose.yaml:compose.prod.yaml
}

scenario varias-imagenes-ok
base_multi
healthy sha256:app010 sha256:app020
deploy_multi
check "termina bien" exit_code 0
check "exporta COMPOSE_FILE" called "COMPOSE_FILE=compose.yaml:compose.prod.yaml :: docker compose up"
check "agentmesh-app:latest apunta a 0.2.0" tag_is ghcr.io/jaisato/agentmesh-app:latest sha256:app020
check "agentmesh-mcp-docs:latest apunta a 0.2.0" tag_is ghcr.io/jaisato/agentmesh-mcp-docs:latest sha256:mcp020
check "la imagen ajena con la misma etiqueta no se reetiqueta" no_tag example/sidecar:latest
check ".deploy-image-tag = 0.2.0" tag_file 0.2.0
check "un up -d manual sin AM_IMAGE_TAG: api en 0.2.0" after_manual_up api sha256:app020
check "un up -d manual sin AM_IMAGE_TAG: mcp-docs en 0.2.0" runs mcp-docs sha256:mcp020
done_scenario

scenario varias-imagenes-health-ko
base_multi
healthy sha256:app010
deploy_multi
check "termina en error" exit_code 1
check "api vuelve a 0.1.0" runs api sha256:app010
check "mcp-docs vuelve a 0.1.0" runs mcp-docs sha256:mcp010
check "agentmesh-app:latest apunta a 0.1.0" tag_is ghcr.io/jaisato/agentmesh-app:latest sha256:app010
check "agentmesh-mcp-docs:latest apunta a 0.1.0" tag_is ghcr.io/jaisato/agentmesh-mcp-docs:latest sha256:mcp010
check ".deploy-image-tag = 0.1.0" tag_file 0.1.0
check "un up -d manual sin AM_IMAGE_TAG: api en 0.1.0" after_manual_up api sha256:app010
check "un up -d manual sin AM_IMAGE_TAG: mcp-docs en 0.1.0" runs mcp-docs sha256:mcp010
done_scenario

scenario primer-despliegue-ko
service api 'ghcr.io/jaisato/app:{IMAGE_TAG}'
published ghcr.io/jaisato/app:1.0.0 sha256:app100
deploy 1.0.0
check "termina en error" exit_code 1
check "avisa de que no hay versión anterior" said "::warning::No había imagen anterior"
check "no fija :latest" no_tag ghcr.io/jaisato/app:latest
check "no escribe .deploy-image-tag" no_tag_file
done_scenario

# El compose no usa la variable (image fija en :latest) pero se pide 1.2.0: el
# despliegue es el de :latest, así que avisa y no escribe una etiqueta falsa.
scenario compose-sin-variable
service api 'ghcr.io/jaisato/app:latest'
published ghcr.io/jaisato/app:latest sha256:app120
published ghcr.io/jaisato/app:1.2.0 sha256:app120
local_tag ghcr.io/jaisato/app:latest sha256:app110
running api ghcr.io/jaisato/app:latest sha256:app110
healthy sha256:app110 sha256:app120
deploy 1.2.0
check "termina bien" exit_code 0
check "avisa de que el compose no usa la variable" said "::warning::El compose no resuelve ghcr.io/jaisato/app con \${IMAGE_TAG}"
check "ningún docker tag" not called ":: docker tag "
check "no escribe .deploy-image-tag" no_tag_file
done_scenario

scenario sin-config-images
base_app
healthy sha256:app120
deploy 1.2.0 SERVICES="api worker" FAKE_NO_CONFIG_IMAGES=1
check "termina bien" exit_code 0
check ":latest local apunta a 1.2.0 (solo la entrada image)" tag_is ghcr.io/jaisato/app:latest sha256:app120
check ".deploy-image-tag = 1.2.0" tag_file 1.2.0
done_scenario

# --- shellcheck del script que recibe el VPS --------------------------------
echo "== shellcheck del script remoto"
if command -v shellcheck > /dev/null; then
  check "sin avisos" shellcheck -s bash "$WORK/despliegue-ok/remote-deploy.sh"
elif [ -n "${CI:-}" ]; then
  check "shellcheck instalado" false
else
  echo "  (shellcheck no está instalado: se omite)"
fi

echo
if [ "$FAILED" -ne 0 ]; then
  echo "Hay escenarios que fallan"
  exit 1
fi
echo "Todos los escenarios pasan"
