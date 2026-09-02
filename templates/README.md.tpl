# {{ORG}} {{PROJECT}}

Monorepo skeleton: ASP.NET Core API (Clean Architecture) + Next.js frontend/BFF.

## Layout

```
apps/api            {{NS}} solution — Domain, Application, Infrastructure, Api
apps/web            Next.js app (frontend + BFF)
deployment          compose file and env for dev/deploy
infrastructure      supporting infra config (nginx)
scripts             utility scripts
```

## Develop

```bash
# API — solution and projects are already scaffolded
cd apps/api
dotnet build

# Web — if the wizard didn't create it, scaffold it yourself
cd apps
pnpm create next-app web
```

## Run the whole stack

Dockerfiles for both apps are generated. The web image expects
`output: "standalone"` in `next.config`. `deployment/.env` is created with
generated passwords — review it before deploying.

```bash
cd deployment

# Development
docker compose up -d --build

# Production (no host ports except nginx, Keycloak in production mode —
# set KEYCLOAK_HOSTNAME in .env first)
docker compose -f compose.yaml -f compose.prod.yaml --env-file .env up -d --build
```

## Architecture rules

Dependencies point inward only:

```
Api  ->  Infrastructure  ->  Application  ->  Domain
```

`Domain` references nothing. `Application` defines interfaces that
`Infrastructure` implements.
