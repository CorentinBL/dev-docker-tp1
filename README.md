# DevSecOps TP1 - Hardening Flask / PostgreSQL

Binôme : Blairon Corentin - Jeremy Prat

Dépôt : https://github.com/CorentinBL/dev-docker-tp1

Microservice Flask + PostgreSQL repris d'une stack "artisanale" puis durci : image multi-stage Chainguard sans shell, exécution non-root, Postgres Chainguard épinglé par digest, réseau isolé, et pipeline GitHub Actions qui bloque sur chaque porte qualité/sécurité avant de publier sur GHCR en SemVer.

```
            frontend (bridge)                 backend (bridge, internal: true)
 host 127.0.0.1:5000 ──► api-python (gunicorn, UID 65532) ──► db (Chainguard Postgres 18, UID 70)
                                                         ▲
                                       tests (pytest, profile "test")
```

## 1. Packages GHCR

- Package : https://github.com/users/CorentinBL/packages/container/package/dev-docker-tp1-api
- Image : `ghcr.io/corentinbl/dev-docker-tp1-api`

```bash
docker pull ghcr.io/corentinbl/dev-docker-tp1-api:1.0.0
```

```bash
docker run --rm -p 127.0.0.1:5000:5000 ghcr.io/corentinbl/dev-docker-tp1-api:1.0.0
```

```bash
curl http://127.0.0.1:5000/health
```

Tags publiés pour une release `v1.0.0` : `1.0.0`, `1.0`, `1`, `sha-<commit>`.

Lancer la stack complète en local :

```bash
cp .env.example .env
```

```bash
docker compose up -d --build --wait
```

```bash
docker compose --profile test run --rm --build tests
```

## 2. Tableau comparatif Avant / Après

### API

| Critère | Avant (`python:3.10-slim`) | Après (Chainguard Python, multi-stage) |
|---|---|---|
| Poids de l'image | 255 Mo | 135 Mo |
| Utilisateur d'exécution | `root` (UID 0) | `nonroot` (UID 65532) |
| Shell (`sh`, `bash`) | présent | absent |
| Gestionnaire de paquets / pip | `apt-get`, `pip` présents | absents |
| Serveur | serveur de dev Flask (`app.run`) | gunicorn |
| CVE Trivy (total) | 185 (OS 165 + Python 20) | **0** |
| CVE HIGH / CRITICAL | 47 HIGH / 0 CRITICAL | **0 / 0** |
| CVE Python corrigeables | 20 (dont 3 HIGH) | 0 |
| Efficience Dive | 97,8 % | **99,7 %** |
| Hadolint (gouvernance `.hadolint.yaml`) | non configuré | 0 violation |

### Base de données

| Critère | Avant (`postgres:14-alpine`) | Après (`cgr.dev/chainguard/postgres@sha256:0c4e…`) |
|---|---|---|
| Épinglage | tag mouvant | digest SHA256 immuable |
| Utilisateur d'exécution | entrypoint lancé en root | `user: "70:70"` dès le démarrage |
| Port publié sur l'hôte | `5432:5432` | aucun (réseau `internal`) |
| CVE Trivy | 47 (1 CRITICAL, 21 HIGH dans `gosu`) | **0** |
| Poids | 406 Mo | 537 Mo (Postgres 18 + extensions) |

## 3. Justification des images de base

- **Chainguard Python** (`cgr.dev/chainguard/python`) plutôt que Distroless Python :
  - même principe que distroless (pas de shell, pas de pip ni d'apk dans l'image finale, utilisateur `nonroot` par défaut) ;
  - mises à jour rapides basées sur Wolfi, 0 CVE au moment du build ;
  - une variante `-dev` existe avec exactement la même version de Python (3.14.8). Elle sert d'étage de build : le venv compilé est copié tel quel dans l'image finale sans incompatibilité d'ABI. Distroless Python impose au contraire de trouver un builder Debian avec la même version de Python.
- **Chainguard Postgres** : imposé par le sujet, 0 CVE contre 47 pour l'image officielle alpine.
- **Immuabilité et reproductibilité** :
  - chaque `FROM` et l'image Postgres sont épinglés par **digest SHA256**. Le tag `latest`/`latest-dev` présent dans le `FROM` est purement informatif, seul le digest compte ;
  - toutes les dépendances Python, y compris transitives, sont figées dans `requirements.txt` ;
  - toutes les actions GitHub sont épinglées par SHA de commit ;
  - les outils lancés en conteneur (Dive) sont épinglés par digest.
- **Multi-stage** (`builder` → `test` → `runtime`) :
  - le manifeste est copié avant le code, donc une modification de `app.py` ne relance pas `pip install` ;
  - le venv est créé `--without-pip` et rempli par le pip du builder (`pip --python`), si bien que l'image finale ne contient ni pip, ni cache, ni en-têtes de compilation ;
  - l'étage `test` (pytest) n'est jamais publié.

Pour mettre à jour une base : récupérer le nouveau digest (`docker pull` puis `docker inspect --format '{{index .RepoDigests 0}}'`), le reporter dans le `Dockerfile` ou le compose, et laisser la CI revalider.

## 4. Healthchecks sans shell

Dans les images Chainguard sans shell, la forme `CMD-SHELL` (ou une chaîne simple) ne peut pas fonctionner : Docker lance `/bin/sh -c`, qui n'existe pas. Les deux sondes sont donc en forme **exec** (`["CMD", ...]`) :

- **API** : la sonde réutilise l'interpréteur Python déjà présent dans l'image et sa bibliothèque standard, sans ajouter `curl` ni `wget` qui augmenteraient la surface d'attaque :
  `["CMD", "python", "-c", "import sys, urllib.request; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:5000/health', timeout=3).status == 200 else 1)"]`
- **PostgreSQL** : `["CMD", "pg_isready", "-h", "127.0.0.1", "-U", "${POSTGRES_USER}", "-d", "${POSTGRES_DB}"]`. Les variables sont interpolées par Compose, aucun shell n'est nécessaire. `-h 127.0.0.1` force une connexion TCP : pendant l'initialisation, l'entrypoint lance un serveur temporaire qui n'écoute que sur le socket Unix. Sans ce flag, la base serait déclarée saine trop tôt.
- **Synchronisation** : `api-python` et `tests` attendent `db: condition: service_healthy`. En CI, `docker compose up --wait --wait-timeout 120` échoue si les deux services ne sont pas sains dans le délai.

Autres durcissements Compose :
- `read_only: true`, avec des `tmpfs` uniquement pour `/var/run/postgresql` et `/tmp` ;
- `cap_drop: [ALL]` et `no-new-privileges` ;
- `pids_limit` et `mem_limit` ;
- secrets lus depuis `.env` (jamais commité) avec une erreur explicite (`${VAR:?}`) s'ils manquent ;
- API publiée uniquement sur `127.0.0.1`.

## 5. Journal des remédiations

### Flake8

Le `.flake8` fourni masque `E302, E305, W293, W292, W391`, donc il passait déjà sur le code d'origine. Une analyse sans ces exclusions (`flake8 --isolated`) relevait 11 écarts réels, tous corrigés :

| Fichier | Violations |
|---|---|
| `app.py` | E302 ×4 (2 lignes vides avant les fonctions), W293 (ligne blanche avec espaces), W391 (ligne vide en fin de fichier) |
| `test_app.py` | E302 ×4, W292 (pas de saut de ligne final) |

Le code passe maintenant flake8 avec la configuration fournie **et** sans aucune exclusion. Autres corrections dans `app.py` :
- `/dbtest` ne renvoie plus `str(e)` au client, ce qui révélait des détails internes de la base. L'erreur est journalisée côté serveur ;
- ajout d'un `connect_timeout` ;
- le marqueur pytest `integration` est déclaré dans `pytest.ini`.

### Dépendances (`requirements.txt`)

| Paquet | Avant | Après | CVE corrigées |
|---|---|---|---|
| Werkzeug | 2.3.3 | 3.1.9 | CVE-2024-34069 (HIGH, debugger RCE), CVE-2023-46136, CVE-2024-49766, CVE-2024-49767, CVE-2025-66221, CVE-2026-21860, CVE-2026-27199, CVE-2026-102598 |
| Flask | 2.3.2 | 3.1.3 | CVE-2026-27205 |
| pytest | 7.4.0 (dans le runtime) | 9.1.1, déplacé dans `requirements-dev.txt` | CVE-2025-71176 |
| psycopg2-binary | non épinglé | 2.9.13 | build non reproductible |
| gunicorn | absent | 26.2.0 | remplace le serveur de développement Flask |

Les CVE de `pip`, `setuptools`, `wheel` et `jaraco.context` (dont 2 HIGH) venaient de l'image de base : elles disparaissent, car l'image finale ne contient plus ces outils. Les dépendances transitives sont épinglées. La compatibilité avec PostgreSQL est validée par `/dbtest` et `test_dbtest` contre Postgres 18.

## 6. Sécurisation de la chaîne CI/CD

Workflow : `.github/workflows/ci-cd.yml`, déclenché sur `push` et `pull_request` vers `main`, et sur les tags `v*.*.*`.

| Job | Porte bloquante |
|---|---|
| `quality` | `flake8 --config .flake8` puis tests unitaires |
| `hadolint` | Hadolint avec `.hadolint.yaml` (seuil `warning`) |
| `build` | build BuildKit (cache GHA) puis Dive `--ci --lowestEfficiency=0.8` |
| `security` | Trivy image et Trivy fs (dépendances + secrets), `HIGH,CRITICAL`, `ignore-unfixed`, `exit-code: 1` |
| `integration` | `compose up --wait`, curl `/health` et `/dbtest`, pytest dans le réseau backend, teardown `down -v` |
| `release` | uniquement sur un tag SemVer et si **toutes** les portes ont réussi : push sur GHCR |

- **Permissions minimales** :
  - `permissions: {}` au niveau du workflow, puis chaque job demande seulement `contents: read` ;
  - seul `release` obtient `packages: write` ;
  - l'authentification GHCR utilise le `GITHUB_TOKEN` natif, sans aucun PAT ;
  - `persist-credentials: false` est mis sur chaque checkout.
- **Pinning** : toutes les actions tierces sont référencées par SHA de commit complet, avec la version en commentaire. Un tag déplacé ou compromis ne peut donc pas injecter de code. L'image Dive est épinglée par digest.
- **Ce qui est publié est ce qui a été testé** : l'image est construite une seule fois, puis passée d'un job à l'autre en artefact. `release` la recharge et la pousse sans la reconstruire.
- **SemVer** : `docker/metadata-action` produit `X.Y.Z`, `X.Y`, `X` et `sha-<commit>`. Le tag majeur est désactivé pour les versions `0.x`, qui sont instables par définition. Pour publier une release :

```bash
git tag -a v1.0.0 -m "v1.0.0"
```

```bash
git push origin v1.0.0
```

## 7. Preuves d'exécution

Sorties obtenues en local, avec les mêmes commandes et versions que la CI (à compléter avec les liens des runs GitHub Actions) :

```
$ flake8 --config .flake8 .            -> 0 erreur (et 0 avec --isolated)
$ hadolint --config .hadolint.yaml Dockerfile -> 0 violation (exit 0)
$ dive dev-docker-tp1-api --ci --lowestEfficiency=0.8
  efficiency: 99.7449 %   wastedBytes: 238 kB   userWastedPercent: 0.44 %
  Result: PASS
$ trivy image --severity HIGH,CRITICAL --ignore-unfixed --exit-code 1 dev-docker-tp1-api
  dev-docker-tp1-api (wolfi)  0 vulnérabilité ; Python  0 vulnérabilité ; exit 0
$ docker compose up -d --wait
  db          Up (healthy)
  api-python  Up (healthy)   127.0.0.1:5000->5000/tcp
$ curl /health  -> {"status":"ok"}
$ curl /dbtest  -> {"db_connection":"successful"}
$ docker compose --profile test run --rm tests
  test_health PASSED / test_hello PASSED / test_dbtest PASSED  -> 3 passed
$ docker compose top
  api-python  UID 65532 (gunicorn) ; db  UID 70 (postgres)
```

Publication GHCR : lien du run `release` à ajouter après le premier tag.

---

# TP2 - Industrialisation BuildKit et supply chain

## 8. Preuves d'industrialisation BuildKit (étape 1)

### Cache persistant et secret de build

- `# syntax=docker/dockerfile:1` en tête du `Dockerfile`.
- `pip install` utilise un `--mount=type=cache` (`/home/nonroot/.cache/pip`, uid 65532) : le cache vit dans le builder, jamais dans une couche. L'image finale ne copie que le venv.
- Le jeton `pkg_token` est monté par `--mount=type=secret` (tmpfs, mode 0400) le temps d'un seul `RUN`, jamais par `ARG` ni `ENV`.
- `secrets/` est exclu de Git (`.gitignore`) et du contexte de build (`.dockerignore` en liste blanche).

Benchmark (build initial à froid vs reconstruction après modification mineure de `requirements.txt`) :

| | Durée | Téléchargements pip |
|---|---|---|
| À froid (builder neuf, cache vide) | 22,4 s (dont le pull des images de base) | 18 téléchargements, 0 depuis le cache |
| Après ajout d'une ligne dans `requirements.txt` | **1,2 s** | **0 téléchargement**, 18 depuis le cache |

La modification invalide bien la couche `pip install`, mais pip ne retélécharge rien : tout est relu depuis le cache mount.

Preuve d'absence de fuite : étape CI « Contrôle d'absence de fuite du secret de build » (recherche de la valeur du jeton dans `docker history --no-trunc`, les métadonnées, chaque couche, et `/run/secrets` absent de l'image) + scan `trivy --scanners secret`.

### Multi-architecture déclaratif

`docker-bake.hcl` : variables `REGISTRY`, `IMAGE`, `VERSION`, `GIT_SHA`, plateformes `linux/amd64` + `linux/arm64`, secret `pkg_token` (variable d'environnement), cache registre `mode=max` en import et export.

```bash
docker buildx bake -f docker-bake.hcl
```

Index publié par le job de release (tag `v1.1.0-rc.1`) :

```
$ docker buildx imagetools inspect ghcr.io/corentinbl/dev-docker-tp1-api@sha256:b1f2e0446f4a914ae1c7555280ee9c9539bd5ff8204e7a728d5618f0bd1e338f
MediaType: application/vnd.oci.image.index.v1+json
  Platform:    linux/amd64
  Platform:    linux/arm64
  Platform:    unknown/unknown   (attestations de provenance BuildKit)
```

## 9. Traçabilité SBOM et gouvernance VEX (étape 2)

### SBOM

Générés par Syft par analyse statique de l'image sur le registre, sans l'exécuter : `sbom.cdx.json` (CycloneDX, OWASP) et `sbom.spdx.json` (SPDX, ISO/IEC 5962).

```bash
syft registry:ghcr.io/corentinbl/dev-docker-tp1-api@sha256:b1f2e0446f4a914ae1c7555280ee9c9539bd5ff8204e7a728d5618f0bd1e338f --platform linux/amd64 -o cyclonedx-json=sbom.cdx.json -o spdx-json=sbom.spdx.json
```

| Requête | Résultat |
|---|---|
| `jq '[.components[] \| select(.type != "file")] \| length' sbom.cdx.json` | **40** composants (Syft liste aussi les fichiers, d'où le filtre) |
| Répartition par type de PURL | apk : 30, pypi : 9 (+ la distribution wolfi) |
| `jq -r '.components[] \| select(.purl) \| .purl' sbom.cdx.json` | ex. `pkg:pypi/flask@3.1.3`, `pkg:pypi/werkzeug@3.1.9`, `pkg:apk/wolfi/python-3.15@3.15.1_git20261024-r0` |
| `jq -r '[.packages[].licenseDeclared \| select(. != "NOASSERTION")] \| unique \| .[]' sbom.spdx.json` | Apache-2.0, BSD-2-Clause, BSD-3-Clause, MIT, MPL-2.0, PSF-2.0, GPL-3.0-or-later, LGPL-2.1-or-later, blessing, ... |

### Grype sur SBOM et VEX

`.grype.yaml` : arrêt bloquant sur les vulnérabilités High+ disposant d'un correctif, document VEX pris en compte.

```
$ grype sbom:sbom.cdx.json
python-3.15  3.15.1_git20261024-r0  apk  CVE-2026-114583  Medium  (pas de correctif)
$ grype sbom:sbom.cdx.json -c .grype.yaml
No vulnerabilities found   (exit 0)
```

`security.vex.json` (OpenVEX) : CVE-2026-114583, `not_affected`, justification `vulnerable_code_not_in_execute_path`. La faille permet de contourner `tarfile.tar_filter` lors d'un `tarfile.extractall()` sur une archive malveillante. L'API n'importe pas `tarfile` et n'extrait aucune archive : le code vulnérable n'est jamais exécuté. L'alerte est levée de façon traçable (le fichier est versionné, daté et signé de l'équipe) plutôt qu'ignorée.

## 10. Commandes de vérification publique

Image : `ghcr.io/corentinbl/dev-docker-tp1-api:1.1.0-rc.1`
Digest : `sha256:b1f2e0446f4a914ae1c7555280ee9c9539bd5ff8204e7a728d5618f0bd1e338f`

```bash
docker buildx imagetools inspect ghcr.io/corentinbl/dev-docker-tp1-api@sha256:b1f2e0446f4a914ae1c7555280ee9c9539bd5ff8204e7a728d5618f0bd1e338f
```

## 11. Reste à faire

- Signature Cosign (keyless OIDC) de l'image par son digest, attestation du SBOM et gate de vérification finale (partie F).
- Jobs SBOM et Grype + VEX intégrés au pipeline CI, avec SBOM publiés en artefacts.

## 12. Réflexion critique

### Jeremy

- La publication multi-arch m'a obligé à un compromis : l'artefact `image.tar` testé par la CI est amd64 uniquement, donc le job de release reconstruit l'image pour les deux architectures au lieu de pousser exactement celle qui a passé les tests. Le même commit et les mêmes digests de base limitent l'écart, mais ce n'est pas la même image au bit près. La signature et le scan de l'image publiée (partie F) devaient combler ce trou.
- `docker buildx bake` sans `-f` lit aussi `docker-compose.yml`, et le build échouait sur l'interpolation des variables Postgres. Il faut toujours préciser le fichier HCL.
- Le SBOM a montré qu'une image qui n'a pas bougé depuis le TP1 se retrouvait avec des CVE critiques quelques semaines plus tard : le scan doit être continu, pas seulement au build.

### Corentin
