# Workflows reutilizables de GitHub Actions

Repositorio `jaisato/.github`: workflows `workflow_call` que sustituyen al CI
copiado y pegado en cada proyecto. Un repositorio los invoca con `uses:` y pasa
solo lo que le diferencia (versiones, directorio, umbrales); el resto se
mantiene en un único sitio.

| Workflow | Para qué | Fichero |
|---|---|---|
| `python-ci` | ruff, mypy, pytest con cobertura mínima, pip-audit, build de la imagen Docker | [`.github/workflows/python-ci.yml`](.github/workflows/python-ci.yml) |
| `symfony-ci` | composer validate, `php -l`, php-cs-fixer, PHPStan, Rector, PHPUnit con MySQL/MariaDB y umbral de cobertura, composer audit | [`.github/workflows/symfony-ci.yml`](.github/workflows/symfony-ci.yml) |
| `deploy-vps` | despliegue por SSH a un VPS: `docker compose pull && up -d`, comprobación con reintentos y rollback | [`.github/workflows/deploy-vps.yml`](.github/workflows/deploy-vps.yml) |

El repositorio es público porque un workflow reutilizable solo puede invocarse
desde un repositorio privado si vive en un repositorio público (o en la misma
organización con un plan que lo permita).

## Convenciones comunes

- **Permisos mínimos.** Cada workflow declara `permissions: {}` a nivel global y
  `contents: read` solo en los jobs que hacen checkout. El caller puede recortar
  más, nunca ampliar: un workflow llamado no puede pedir más permisos de los que
  tiene el job que lo invoca.
- **Entradas por `env`.** Ningún `${{ inputs.* }}` ni `${{ secrets.* }}` se
  interpola dentro de un `run:`; la sustitución ocurre antes de que el shell vea
  el texto y un valor con `;` o `$(...)` se ejecutaría. Todo pasa por variables de
  entorno y, en `deploy-vps`, además se valida con una expresión regular y viaja
  al VPS escapado con `printf %q`.
- **Acciones ancladas a SHA.** Ver [política de anclaje](#política-de-anclaje-pinning).
- **Referencia del caller.** Los ejemplos usan `@main`. Para un repositorio que
  necesite reproducibilidad estricta se puede anclar a un SHA de este repositorio
  (`@<sha>`), igual que se hace con las acciones.

## `python-ci`

Jobs: `lint` (ruff check + `ruff format --check`), `types` (mypy, opcional),
`tests` (matriz de versiones de Python, cobertura mínima opcional), `audit`
(pip-audit, opcional) y `docker` (build de validación sin push, opcional). La
caché de pip la gestiona `actions/setup-python`.

### Entradas

| Entrada | Tipo | Por defecto | Descripción |
|---|---|---|---|
| `python-versions` | string (JSON) | `["3.12"]` | Versiones para la matriz de tests. |
| `tools-python-version` | string | primera de `python-versions` | Versión para lint, mypy y pip-audit. Útil si mypy necesita una versión concreta. |
| `working-directory` | string | `.` | Directorio del proyecto. |
| `install-command` | string | `pip install -e ".[dev]"` | Si se deja el valor por defecto y no hay `pyproject.toml`, se usan `requirements-dev.lock`, `requirements-dev.txt` (+ `requirements.txt`) o `requirements.txt`, en ese orden. |
| `cache-dependency-path` | string (multilínea) | `**/pyproject.toml`, `**/requirements*.txt`, `**/requirements*.lock` | Globs que forman la clave de la caché de pip. |
| `ruff-paths` | string | `.` | Rutas para ruff. |
| `ruff-format` | boolean | `true` | Ejecutar también `ruff format --check`. |
| `run-mypy` | boolean | `false` | Ejecutar mypy. |
| `mypy-paths` | string | `""` | Rutas para mypy. Vacío: las de la configuración del proyecto (`files =`) o `.`. |
| `coverage-min` | number | `0` | Cobertura mínima de líneas; `0` no mide cobertura. |
| `coverage-source` | string | `""` | Valor de `--cov=`. Vacío: `--cov` con la configuración de `[tool.coverage.run]`. |
| `extra-test-args` | string | `""` | Argumentos extra para pytest. |
| `run-pip-audit` | boolean | `false` | Ejecutar pip-audit. |
| `pip-audit-args` | string | `""` | Por ejemplo `-r requirements.lock`. Vacío: audita el entorno instalado con `install-command`. |
| `pip-audit-strict` | boolean | `false` | Con `false` una vulnerabilidad deja un aviso pero no rompe el CI. |
| `docker-build` | boolean | `false` | Construir la imagen sin publicarla (caché de capas en GHA). |
| `docker-context` | string | `working-directory` | Contexto del build. |
| `dockerfile` | string | `""` | Ruta del Dockerfile; vacío usa el del contexto. |

Si ruff, mypy, pytest o pytest-cov no quedan instalados por `install-command`,
el workflow instala la última versión publicada. Para resultados reproducibles
conviene fijarlos en las dependencias de desarrollo del proyecto.

### Ejemplo de caller

```yaml
# .github/workflows/ci.yml
name: CI
on:
  push:
    branches: [main]
  pull_request:
permissions:
  contents: read
jobs:
  python:
    uses: jaisato/.github/.github/workflows/python-ci.yml@main
    with:
      python-versions: '["3.11", "3.12", "3.13"]'
      tools-python-version: "3.12"
      install-command: pip install -r requirements-dev.lock
      run-mypy: true
      mypy-paths: src/mi_paquete
      coverage-min: 90
      coverage-source: mi_paquete
      run-pip-audit: true
      pip-audit-args: -r requirements.lock
      docker-build: true
```

## `symfony-ci`

Jobs: `lint` (composer validate --strict, composer install, php-cs-fixer en
dry-run, PHPStan, Rector opcional y un comando de lint adicional), `tests`
(matriz de PHP; `php -l` sobre `src tests config public tools` en cada versión,
servicio MySQL/MariaDB opcional con `DATABASE_URL` exportado, preparación de la
base de datos, `doctrine:schema:validate`, PHPUnit con pcov y umbral de
cobertura) y `audit` (composer audit sobre el lock).

El umbral de cobertura se comprueba con un script PHP incluido en el propio
workflow que lee `/coverage/project/metrics` del informe Clover; el proyecto no
necesita su propio `coverage-threshold.php`.

### Entradas

| Entrada | Tipo | Por defecto | Descripción |
|---|---|---|---|
| `php-versions` | string (JSON) | `["8.3", "8.4"]` | Versiones para la matriz de tests. |
| `tools-php-version` | string | primera de `php-versions` | Versión para lint, análisis estático y audit. |
| `working-directory` | string | `.` | Directorio con `composer.json`. |
| `extensions` | string | `intl, mbstring, pdo_mysql, pdo_sqlite, zip` | Extensiones para setup-php. |
| `composer-options` | string | `--no-interaction --no-progress --prefer-dist` | Opciones de `composer install`. |
| `lint-paths` | string | `src tests config public tools` | Directorios para `php -l` (los inexistentes se omiten). |
| `cs-fixer` | boolean | `true` | `vendor/bin/php-cs-fixer fix --dry-run --diff`. |
| `phpstan` | boolean | `true` | `vendor/bin/phpstan analyse --no-progress` (nivel y rutas del `phpstan.dist.neon` del proyecto). |
| `phpstan-args` | string | `--memory-limit=1G` | Argumentos extra para PHPStan. |
| `rector` | boolean | `false` | `vendor/bin/rector process --dry-run`. |
| `pre-analysis-command` | string | `""` | Se ejecuta antes del análisis; p. ej. `php bin/console cache:warmup --env=dev` cuando phpstan-symfony lee el contenedor compilado. |
| `extra-lint-command` | string | `""` | Comando extra al final del job de lint, p. ej. `composer lint`. |
| `mysql` | boolean | `false` | Levantar el servicio de base de datos y exportar `DATABASE_URL`. |
| `mysql-image` | string | `mysql:8.0` | Imagen del servicio (`mariadb:11.4` también funciona: el healthcheck prueba `mysqladmin` y `mariadb-admin`). |
| `database-url` | string | `mysql://app:app_ci_password@127.0.0.1:3306/app?serverVersion=8.0&charset=utf8mb4` | `DATABASE_URL` del entorno de test. El usuario `app` recibe todos los privilegios, así que sirve cualquier nombre de base de datos (p. ej. `app` + `dbname_suffix: _test`). Ajusta `serverVersion` a la imagen. |
| `db-setup-command` | string | `doctrine:database:create --if-not-exists` + `doctrine:migrations:migrate --allow-no-migration` (env test) | Preparación de la base de datos. |
| `schema-validate` | boolean | `true` | `doctrine:schema:validate --env=test` tras migrar. |
| `coverage-min` | number | `80` | Cobertura mínima de líneas; `0` desactiva pcov y el umbral. |
| `phpunit-args` | string | `""` | Argumentos extra para PHPUnit (`bin/phpunit` si existe, si no `vendor/bin/phpunit`). |
| `composer-audit` | boolean | `true` | Ejecutar el job de audit. |
| `composer-audit-args` | string | `--locked --abandoned=report` | Argumentos de `composer audit`. |

Las credenciales del servicio (`root_ci_password`, `app`/`app_ci_password`) son
las de un contenedor efímero del job; van escritas por extenso para que ningún
escáner de secretos las tome por una credencial real.

### Ejemplo de caller

```yaml
# .github/workflows/ci.yml
name: CI
on:
  push:
    branches: [main]
  pull_request:
permissions:
  contents: read
jobs:
  backend:
    uses: jaisato/.github/.github/workflows/symfony-ci.yml@main
    with:
      working-directory: backend
      extensions: intl, mbstring, pdo_mysql, pdo_sqlite
      mysql: true
      coverage-min: 80
      pre-analysis-command: php bin/console cache:warmup --env=dev
      extra-lint-command: composer lint
```

Con MariaDB:

```yaml
    with:
      mysql: true
      mysql-image: mariadb:11.4
      database-url: mysql://app:app_ci_password@127.0.0.1:3306/app?serverVersion=mariadb-11.4.8&charset=utf8mb4
```

## `deploy-vps`

Un único job `deploy` que:

1. valida entradas y secretos (falla si falta `DEPLOY_HOST`, `DEPLOY_USER`,
   `DEPLOY_SSH_KEY` o `DEPLOY_HOST_KEY`; no hay `ssh-keyscan` de respaldo);
2. levanta un túnel WireGuard si `wireguard: true` (secreto `WG_CONFIG`);
3. escribe la clave y la huella del servidor y conecta con ssh nativo
   (`StrictHostKeyChecking yes`, `IdentitiesOnly yes`, `BatchMode yes`);
4. en el VPS: anota la imagen en ejecución, `docker compose pull && up -d`,
   consulta `health-url` con reintentos y, si no responde, vuelve a la imagen
   anterior (`docker tag` + `up -d`) y falla el job;
5. si todo va bien, `docker image prune -f` (nunca `docker system prune`, que en
   un VPS compartido borra volúmenes y contenedores de otros servicios);
6. borra la clave y cierra el túnel (`if: always()`).

La etiqueta se exporta al entorno de compose como `IMAGE_TAG` (configurable con
`tag-variable`), así que el fichero compose del VPS debería referenciar la
imagen como `image: ghcr.io/jaisato/mi-servicio:${IMAGE_TAG:-latest}`. Con un
`:latest` fijo también funciona: el rollback vuelve a etiquetar la imagen
anterior con esa misma referencia.

### Entradas

| Entrada | Tipo | Por defecto | Descripción |
|---|---|---|---|
| `image` | string | (obligatoria) | Referencia sin etiqueta, p. ej. `ghcr.io/jaisato/normarag`. |
| `tag` | string | `latest` | Etiqueta a desplegar. Validada con `^[A-Za-z0-9_][A-Za-z0-9._-]{0,127}$`. |
| `tag-variable` | string | `IMAGE_TAG` | Variable de entorno que lee el compose del VPS. |
| `compose-path` | string | (obligatoria) | Directorio del VPS con el fichero compose (`/opt/...` o `~/...`). |
| `compose-files` | string | `""` | Valor de `COMPOSE_FILE` (separados por `:`). |
| `services` | string | `""` | Servicios a actualizar (separados por espacios); vacío = todos. |
| `health-url` | string | (obligatoria) | URL que debe responder 2xx, consultada con `curl` **desde el VPS** (vale `http://localhost:PUERTO/health`). |
| `health-retries` | number | `30` | Intentos. |
| `health-interval` | number | `5` | Segundos entre intentos. |
| `ssh-port` | string | `22` | Puerto SSH. |
| `wireguard` | boolean | `false` | Levantar túnel WireGuard antes de conectar. |
| `environment` | string | `production` | Environment de GitHub del job (aprobaciones manuales, secretos por entorno). |

### Secretos

| Secreto | Obligatorio | Descripción |
|---|---|---|
| `DEPLOY_HOST` | sí | Host o IP del VPS (la IP del túnel si `wireguard: true`). |
| `DEPLOY_USER` | sí | Usuario SSH. |
| `DEPLOY_SSH_KEY` | sí | Clave privada OpenSSH sin passphrase. |
| `DEPLOY_HOST_KEY` | sí | Huella del servidor: salida de `ssh-keyscan -t ed25519 <host>` (con puerto distinto de 22, `ssh-keyscan -p PUERTO`, que produce `[host]:puerto ...`). También se admite solo `ssh-ed25519 AAAA...` y el workflow antepone el host. |
| `WG_CONFIG` | solo con `wireguard: true` | Contenido de `wg0.conf`. |

Un job que llama a un workflow reutilizable no admite `environment:`; por eso el
environment se fija con la entrada `environment`. Las reglas de protección
(revisores, ramas permitidas) se configuran en el repositorio que llama.

### Ejemplo de caller

```yaml
# .github/workflows/deploy.yml
name: Deploy
on:
  push:
    tags: ["v*.*.*"]
  workflow_dispatch:
    inputs:
      tag:
        description: "Etiqueta de imagen a desplegar"
        default: latest
permissions:
  contents: read
jobs:
  build-push:
    # ... construye y publica ghcr.io/jaisato/mi-servicio:<version> y expone outputs.version
  deploy:
    needs: build-push
    permissions: {}
    uses: jaisato/.github/.github/workflows/deploy-vps.yml@main
    with:
      image: ghcr.io/jaisato/mi-servicio
      tag: ${{ github.event.inputs.tag || needs.build-push.outputs.version }}
      compose-path: /opt/mi-servicio
      health-url: http://localhost:8010/health
      wireguard: true
      environment: production
    secrets:
      DEPLOY_HOST: ${{ secrets.DEPLOY_HOST }}
      DEPLOY_USER: ${{ secrets.DEPLOY_USER }}
      DEPLOY_SSH_KEY: ${{ secrets.DEPLOY_SSH_KEY }}
      DEPLOY_HOST_KEY: ${{ secrets.DEPLOY_HOST_KEY }}
      WG_CONFIG: ${{ secrets.WG_CONFIG }}
```

## Política de anclaje (pinning)

Toda acción de terceros (incluidas las de `actions/*` y `docker/*`) se referencia
por el SHA completo del commit, con la versión legible en un comentario al lado:

```yaml
- uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
```

Una etiqueta (`v4`, `v7.0.1`) es un puntero que su propietario puede mover; un
SHA identifica exactamente el código que se ejecuta con acceso al token del job.
[`dependabot.yml`](.github/dependabot.yml) revisa semanalmente las acciones y
abre PRs que actualizan el SHA y el comentario a la vez. Al revisar uno de esos
PRs basta con comprobar que el comentario y la etiqueta del release coinciden.

Para añadir una acción nueva:

```bash
gh api repos/OWNER/REPO/git/ref/tags/vX.Y.Z -q .object.sha   # si es un tag anotado, resolver con git/tags/<sha>
```

## Validación

Los workflows se validan con [actionlint](https://github.com/rhysd/actionlint)
(con shellcheck sobre los scripts) en cada push y PR de este repositorio
([`.github/workflows/lint.yml`](.github/workflows/lint.yml)). En local:

```bash
uvx --from actionlint-py actionlint .github/workflows/*.yml
```

`deploy-vps` no puede ejecutarse en CI de este repositorio: necesita un VPS real
y sus secretos. Su lógica se verifica con actionlint/shellcheck y en el primer
despliegue del repositorio que lo adopte.
