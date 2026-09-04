# Overwhelmed

Overwhelmed is an interactive wizard that scaffolds a full-stack monorepo: an ASP.NET Core
API laid out as Clean Architecture, a Next.js frontend/BFF, and a Docker
Compose deployment with PostgreSQL (or SQL Server), Keycloak, and Nginx —
ready for both development and production.

The tool lives outside the projects it generates. Point it at any target
path (created if it does not exist yet) and it lays the skeleton out there.

```text
init-project.sh     the wizard
next-steps.sh       re-print the status + next-steps summary anytime
templates/          all generated file content (edit these, not the script)
```

## Requirements

| Tool             | Needed for                                            |
| ---------------- | ----------------------------------------------------- |
| bash             | running the scripts                                   |
| .NET SDK 10+     | solution + project scaffolding (`dotnet new`)         |
| git              | only with git init enabled                            |
| pnpm or npm      | only when scaffolding the web app (create-next-app)   |
| openssl          | generated passwords in `.env` (falls back to warning) |
| docker + compose | running the generated stack                           |

## Quick start

```bash
./init-project.sh
```

The wizard asks, in order:

1. **Target directory** — any path; created if missing (default: current dir)
2. **Organization / Project name** — PascalCase; together they form the
   namespace prefix `{Org}.{Project}` (e.g. `Contoso.Billing`)
3. **Database** — postgres | sqlserver | none (drives compose + env)
4. **Nginx reverse proxy** — yes/no
5. **Keycloak** — yes/no (container + starter realm, imported on first start)
6. **Web scaffold** — hands the terminal over to `create-next-app`; you
   answer the Next.js CLI's own prompts (uses pnpm when installed, else npx)
7. **Git init** — `git init` only; nothing is staged and no root
   `.gitignore` is written — bring your own ignore rules

Every prompt has a flag, so unattended runs work too:

```bash
./init-project.sh --dir ~/code/Billing --org Contoso --project Billing --yes
```

| Flag | Meaning |
| --- | --- |
| `--dir <path>` | target root, created if missing (default: asked) |
| `--org` / `--project <Name>` | PascalCase names for the namespace |
| `--db postgres\|sqlserver\|none` | database for compose (default: postgres) |
| `--nginx` / `--no-nginx` | reverse proxy (default: yes) |
| `--keycloak` / `--no-keycloak` | identity provider (default: yes) |
| `--web` / `--no-web` | run create-next-app; interactive, so `-y` skips it unless `--web` is given |
| `--no-git` | skip `git init` |
| `-y`, `--yes` | accept every default, no prompts |
| `-n`, `--dry-run` | print the plan and exit (nothing written, not even the target dir) |

Re-running is safe: every step skips anything that already exists, so you
can fill in a piece you skipped the first time.

## What gets generated

```text
{target}/
├── {Project}.code-workspace       VS Code multi-root workspace
├── README.md                      project readme
├── apps/
│   ├── api/
│   │   ├── {Org}.{Project}.slnx   solution (dotnet new; .sln on older SDKs)
│   │   ├── Dockerfile             multi-stage dotnet publish
│   │   └── src/
│   │       ├── {Org}.{Project}.Domain/            classlib
│   │       ├── {Org}.{Project}.Application/       classlib
│   │       ├── {Org}.{Project}.Infrastructure/    classlib
│   │       └── {Org}.{Project}.Api/               webapi
│   └── web/                       Next.js app (via create-next-app)
│       └── Dockerfile             lockfile-aware standalone build
├── deployment/
│   ├── compose.yaml               dev stack
│   ├── compose.prod.yaml          production overrides (see below)
│   ├── .env.example               documented placeholders
│   └── .env                       copy with generated random passwords
├── infrastructure/
│   ├── nginx/nginx.conf           / → web, /api/ → api
│   ├── keycloak/realms/           starter realm ({slug}-web + {slug}-api clients)
│   └── postgres/init/             first-boot SQL/shell init (keycloak db)
└── scripts/                       empty — for the project's own job scripts
```

Deliberately left to you: project references between the layers, NuGet
packages/feeds, and wiring the apps to Keycloak (JWT bearer, client
secrets).

The workspace file defines the roots Main (`.`), Domain, Application,
Infrastructure, Api, UI (`apps/web`), Deployment, and Script.

## Running the stack

```bash
cd {target}/deployment

# Development — all service ports published to the host
docker compose up -d --build

# Production — layered overrides
docker compose -f compose.yaml -f compose.prod.yaml --env-file .env up -d --build
```

The production overrides (`compose.prod.yaml`):

- `ASPNETCORE_ENVIRONMENT=Production`, log rotation on every service
- with nginx enabled, only nginx (and Keycloak) keep host ports —
  api/web/database ports are stripped via `ports: !override []`
- Keycloak switches from `start-dev` to `start` behind the proxy
  (`KC_PROXY_HEADERS: xforwarded`); with postgres it gets durable storage
  in a `keycloak` database that `infrastructure/postgres/init/` creates on
  the first boot of an empty data volume

Before a production run: set `KEYCLOAK_HOSTNAME` in `.env` (it ships as
`auth.example.com`) and put real TLS in front (terminate at nginx or an
outer proxy — the stack itself speaks plain HTTP).

Notes:

- `.env` is created with random passwords (`.env.example` keeps `change-me`
  as documentation). The realm JSON's client secrets are still `change-me`.
- The web Dockerfile expects `output: "standalone"` in `next.config` — add
  it after create-next-app.
- postgres runs the `postgres:18-alpine` image, whose data directory moved:
  the volume mounts `/var/lib/postgresql` (not `…/data`). Keep it that way
  or data will not persist.

## Checking status later

```bash
./next-steps.sh --dir {target}     # default: current directory
```

Re-prints the wizard's closing summary (it scrolls away easily behind
create-next-app's output) plus a detected-from-disk checklist: missing
pieces, `change-me` passwords, the Keycloak hostname placeholder, and the
`standalone` setting.

## Customizing the output

Everything the wizard writes comes from `templates/`, rendered by
concatenating fragments and substituting four placeholders — `{{NS}}`
(`Contoso.Billing`), `{{ORG}}`, `{{PROJECT}}`, `{{SLUG}}` (lowercased
project), plus `{{DOTNET_TAG}}` in the API Dockerfile. Everything else
(compose's own `${VAR}` interpolation included) passes through untouched.

```text
templates/
├── compose/         one fragment per dev service: head, api-{db}, web,
│                    postgres, sqlserver, keycloak, nginx, volumes-{db}
├── compose-prod/    production override fragments (…-nginx variants strip ports)
├── env/             .env fragments: base, postgres, sqlserver, keycloak, nginx
├── Dockerfile.api / Dockerfile.web
├── nginx.conf
├── keycloak-realm.json
├── postgres-init-keycloak.sh
├── workspace.code-workspace
└── README.md.tpl
```

To add a service (say redis): drop `templates/compose/redis.yaml` (and an
`env/redis.env` if it needs variables), then in `init-project.sh` add a
toggle and one `fragments+=` line in `write_deployment`. That's the whole
recipe — keycloak itself is wired exactly this way.

## Packing for distribution

```bash
./pack.sh
```

builds two distributables into `dist/`:

- `overwhelmed.tar.gz` — the two scripts + `templates/`; extract
  anywhere and run `./init-project.sh`
- `overwhelmed.sh` — a single self-contained executable (~20 KB) with
  the templates embedded; it self-extracts to a temp dir per run and cleans
  up after itself. Copy or `curl` just this one file to any machine:

  ```bash
  ./overwhelmed.sh --dir ~/code/Billing        # scaffold (wizard flags apply)
  ./overwhelmed.sh next-steps --dir ~/code/Billing
  ```

Re-run `./pack.sh` after changing the scripts or templates — the bundle is
generated, never edited by hand. `dist/` is build output; keep it out of
version control.
