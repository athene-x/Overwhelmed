#!/usr/bin/env bash
#
# init-project.sh — small wizard that lays out the monorepo skeleton from
# init-project.md:
#
#   apps/api            .slnx + Clean Architecture projects via dotnet new
#   apps/web            Next.js app via create-next-app (interactive, optional)
#   deployment          compose.yaml + .env for dev/deploy
#   infrastructure      nginx reverse-proxy config
#   scripts             utility scripts (for the generated project's own jobs)
#
# This tool lives OUTSIDE the projects it generates: the wizard asks for the
# target root (any path — created if it does not exist yet). File content is
# rendered from the templates/ folder next to this script — edit those
# files, not heredocs in here. {{NS}}, {{ORG}}, {{PROJECT}} and {{SLUG}}
# are substituted.
#
# Run with no arguments for the wizard, or pass flags to run unattended:
#   ./init-project.sh --dir ~/code/Billing --org Contoso --project Billing --yes
#
set -euo pipefail

# ---------------------------------------------------------------- output ----

APP_NAME="Overwhelmed"
APP_VERSION="1.0.0"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GREEN=$'\033[32m'
  YELLOW=$'\033[33m'; BLUE=$'\033[34m'; MAGENTA=$'\033[35m'; CYAN=$'\033[36m'
  RESET=$'\033[0m'
else
  BOLD=''; DIM=''; RED=''; GREEN=''; YELLOW=''; BLUE=''; MAGENTA=''; CYAN=''; RESET=''
fi
ACCENT=$CYAN
RULE='────────────────────────────────────────────────────────────'

# banner <tagline>
banner() {
  printf '\n  %s%s◆ %s%s %sv%s%s\n' "$BOLD" "$ACCENT" "$APP_NAME" "$RESET" "$DIM" "$APP_VERSION" "$RESET"
  printf '  %s%s%s\n' "$DIM" "$1" "$RESET"
  printf '  %s%s%s\n' "$DIM" "$RULE" "$RESET"
}

step()  { printf '\n  %s◆%s %s%s%s\n' "$ACCENT" "$RESET" "$BOLD" "$*" "$RESET"; }
info()  { printf '    %s\n' "$*"; }
ok()    { printf '    %s✔%s %s\n' "$GREEN" "$RESET" "$*"; }
skip()  { printf '    %s○ %s%s\n' "$DIM" "$*" "$RESET"; }
warn()  { printf '    %s▲%s %s\n' "$YELLOW" "$RESET" "$*" >&2; }
die()   { printf '\n  %s✖ error:%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }
kv()    { printf '    %s%-18s%s %s\n' "$DIM" "$1" "$RESET" "$2"; }

# ------------------------------------------------------------- defaults -----

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TPL_DIR="$SCRIPT_DIR/templates"

ROOT_DIR=""             # target repo root; asked if not given (created if missing)

ORG=""
PROJECT=""
DB="postgres"           # postgres | sqlserver | none
USE_NGINX="yes"
USE_KEYCLOAK="yes"
USE_WEB=""              # create-next-app, interactive (default: ask; no under -y)
INIT_GIT="yes"
ASSUME_YES="no"
DRY_RUN="no"

# derived later:
NS=""
SLUG=""
DOTNET_TAG="10.0"       # sdk/aspnet image tag for the API Dockerfile

# --------------------------------------------------------- CLI arguments ----

usage() {
  cat <<USAGE
${BOLD}Overwhelmed${RESET} — lay out the monorepo skeleton (init-project.sh)

Usage: ./init-project.sh [options]

Options:
  --dir <path>          Repo root to scaffold into — created if it does not
                        exist yet                       (default: asked)
  --org <Name>          Organization name, PascalCase
  --project <Name>      Project name, PascalCase
  --db <name>           postgres | sqlserver | none     (default: $DB)
  --nginx / --no-nginx  Include Nginx reverse proxy     (default: yes)
  --keycloak / --no-keycloak
                        Include Keycloak + realm import (default: yes)
  --web / --no-web      Run create-next-app for apps/web — interactive, you
                        answer the Next.js CLI's own prompts (default: ask;
                        skipped under -y unless --web is given)
  --no-git              Do not run 'git init'
  -y, --yes             Accept every default, no prompts
  -n, --dry-run         Print the plan and exit
  -h, --help            Show this help

Existing files and folders are left alone, so the wizard is safe to re-run
to fill in a piece you skipped the first time.
USAGE
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --dir)          ROOT_DIR=$2; shift 2 ;;
      --org)          ORG=$2; shift 2 ;;
      --project)      PROJECT=$2; shift 2 ;;
      --db)           DB=$2; shift 2 ;;
      --nginx)        USE_NGINX="yes"; shift ;;
      --no-nginx)     USE_NGINX="no"; shift ;;
      --keycloak)     USE_KEYCLOAK="yes"; shift ;;
      --no-keycloak)  USE_KEYCLOAK="no"; shift ;;
      --web)          USE_WEB="yes"; shift ;;
      --no-web)       USE_WEB="no"; shift ;;
      --no-git)       INIT_GIT="no"; shift ;;
      -y|--yes)       ASSUME_YES="yes"; shift ;;
      -n|--dry-run)   DRY_RUN="yes"; shift ;;
      -h|--help)      usage; exit 0 ;;
      *)              usage >&2; die "unknown option: $1" ;;
    esac
  done
}

# --------------------------------------------------------------- helpers ----

# prompt <question> <hint>   — question line + input marker on the next line
prompt() {
  printf '  %s?%s %s%s%s%s\n  %s›%s ' "$ACCENT" "$RESET" "$BOLD" "$1" "$RESET" "${2:+ $DIM$2$RESET}" "$DIM" "$RESET"
}
# preset <question> <value>  — what -y prints instead of asking
preset() {
  printf '  %s○%s %s %s%s%s\n' "$DIM" "$RESET" "$1" "$DIM" "$2" "$RESET"
}

# ask <var> <question> <default>
ask() {
  local __var=$1 __q=$2 __def=$3 __ans=""
  if [ "$ASSUME_YES" = "yes" ]; then
    preset "$__q" "$__def"
    eval "$__var=\$__def"; return
  fi
  prompt "$__q" "[$__def]"
  IFS= read -r __ans || true
  [ -n "$__ans" ] || __ans=$__def
  eval "$__var=\$__ans"
}

# ask_path <var> <question> <default>
# Like ask, but with readline enabled: Tab completes file/dir names and the
# default is pre-filled on the line so it can be edited in place (bash >= 4).
# Falls back to plain ask when stdin is not a terminal.
ask_path() {
  local __var=$1 __q=$2 __def=$3 __ans=""
  if [ "$ASSUME_YES" = "yes" ] || [ ! -t 0 ]; then
    ask "$__var" "$__q" "$__def"; return
  fi
  if [ "${BASH_VERSINFO[0]}" -ge 4 ]; then
    prompt "$__q" "(Tab completes)"
    IFS= read -e -r -i "$__def" __ans || true
  else
    prompt "$__q" "${__def:+[$__def] }(Tab completes)"
    IFS= read -e -r __ans || true
  fi
  [ -n "$__ans" ] || __ans=$__def
  eval "$__var=\$__ans"
}

# ask_yn <var> <question> <yes|no default>
ask_yn() {
  local __var=$1 __q=$2 __def=$3 __ans=""
  if [ "$ASSUME_YES" = "yes" ]; then
    preset "$__q" "$__def"
    eval "$__var=\$__def"; return
  fi
  while :; do
    prompt "$__q" "[$__def]"
    IFS= read -r __ans || true
    [ -n "$__ans" ] || __ans=$__def
    case $(printf '%s' "$__ans" | tr '[:upper:]' '[:lower:]') in
      y|yes) eval "$__var=yes"; return ;;
      n|no)  eval "$__var=no";  return ;;
      *)     warn "please answer y or n" ;;
    esac
  done
}

# ask_choice <var> <question> <default> <option>...
ask_choice() {
  local __var=$1 __q=$2 __def=$3; shift 3
  local __opts="$*" __ans="" __o
  if [ "$ASSUME_YES" = "yes" ]; then
    preset "$__q" "$__def"
    eval "$__var=\$__def"; return
  fi
  while :; do
    prompt "$__q" "(${__opts// /, }) [$__def]"
    IFS= read -r __ans || true
    [ -n "$__ans" ] || __ans=$__def
    for __o in $__opts; do
      if [ "$__o" = "$__ans" ]; then eval "$__var=\$__ans"; return; fi
    done
    warn "pick one of: ${__opts// /, }"
  done
}

valid_name() { printf '%s' "$1" | grep -Eq '^[A-Za-z][A-Za-z0-9]*$'; }

pascalize() {
  printf '%s' "$1" \
    | tr '_-' '  ' \
    | awk '{ for (i = 1; i <= NF; i++) $i = toupper(substr($i,1,1)) tolower(substr($i,2)); print }' \
    | tr -d ' '
}

require() { command -v "$1" >/dev/null 2>&1 || die "'$1' is required but not on PATH"; }

# render <template>... — concatenate templates, substituting placeholders
render() {
  local f
  for f in "$@"; do
    [ -f "$f" ] || die "template missing: $f (keep templates/ next to this script)"
  done
  sed -e "s/{{NS}}/$NS/g" \
      -e "s/{{ORG}}/$ORG/g" \
      -e "s/{{PROJECT}}/$PROJECT/g" \
      -e "s/{{SLUG}}/$SLUG/g" \
      -e "s/{{DOTNET_TAG}}/$DOTNET_TAG/g" \
      "$@"
}

# randomize_secrets <env-file> — replace change-me values with random ones
randomize_secrets() {
  local file=$1 key val
  if ! command -v openssl >/dev/null 2>&1; then
    warn "openssl not found — passwords in $(basename "$file") stay 'change-me'"
    return 0
  fi
  for key in POSTGRES_PASSWORD MSSQL_SA_PASSWORD \
             KEYCLOAK_ADMIN_PASSWORD KEYCLOAK_DB_PASSWORD; do
    if grep -q "^$key=" "$file"; then
      val=$(openssl rand -hex 16)
      # SQL Server enforces complexity: mix in upper/lower/digit/symbol.
      [ "$key" = "MSSQL_SA_PASSWORD" ] && val="Aa1_$val"
      sed -i.bak "s/^$key=.*/$key=$val/" "$file" && rm -f "$file.bak"
    fi
  done
}

# --------------------------------------------------------------- wizard -----

interview() {
  banner "Scaffold a full-stack monorepo · .NET API · Next.js · Docker Compose"
  printf '\n'

  if [ -z "$ROOT_DIR" ]; then
    printf '  %s○ Current directory%s  %s\n' "$DIM" "$RESET" "$PWD"
    if [ "$ASSUME_YES" = "yes" ]; then
      preset "Target directory?" "(current)"
    else
      ask_path ROOT_DIR "Target directory? (relative to current; Enter = current; created if missing)" ""
    fi
    [ -n "$ROOT_DIR" ] || ROOT_DIR=.
  fi
  case "$ROOT_DIR" in
    "~")   ROOT_DIR=$HOME ;;
    "~/"*) ROOT_DIR="$HOME/${ROOT_DIR#\~/}" ;;
  esac
  [ -n "$ROOT_DIR" ] || die "target directory cannot be empty"
  case "$ROOT_DIR" in
    /*) ;;
    *)  ROOT_DIR="$PWD/${ROOT_DIR#./}" ;;   # relative -> absolute (against cwd)
  esac
  if [ -d "$ROOT_DIR" ]; then
    ROOT_DIR=$(cd "$ROOT_DIR" && pwd)
    info "Repo root: $ROOT_DIR"
  else
    info "Repo root: $ROOT_DIR (will be created)"
  fi
  printf '\n'

  local project_default
  project_default=$(pascalize "$(basename "$ROOT_DIR")")
  [ -n "$project_default" ] || project_default="App"

  if [ -z "$ORG" ]; then
    while :; do
      ask ORG "Organization name (PascalCase)?" "Acme"
      valid_name "$ORG" && break
      warn "letters and digits only, must start with a letter"
      [ "$ASSUME_YES" = "yes" ] && die "invalid --org"
    done
  fi
  valid_name "$ORG" || die "invalid organization name: $ORG"

  if [ -z "$PROJECT" ]; then
    while :; do
      ask PROJECT "Project name (PascalCase)?" "$project_default"
      valid_name "$PROJECT" && break
      warn "letters and digits only, must start with a letter"
      [ "$ASSUME_YES" = "yes" ] && die "invalid --project"
    done
  fi
  valid_name "$PROJECT" || die "invalid project name: $PROJECT"

  ask_choice DB "Database (for compose)?" "$DB" postgres sqlserver none
  case "$DB" in postgres|sqlserver|none) ;; *) die "invalid --db: $DB" ;; esac

  ask_yn USE_NGINX "Include Nginx reverse proxy?" "$USE_NGINX"
  ask_yn USE_KEYCLOAK "Include Keycloak (with realm import)?" "$USE_KEYCLOAK"

  if [ -z "$USE_WEB" ]; then
    if [ "$ASSUME_YES" = "yes" ]; then
      # create-next-app is interactive; don't launch it in unattended runs.
      USE_WEB="no"
    else
      ask_yn USE_WEB "Scaffold apps/web now with create-next-app (interactive)?" "yes"
    fi
  fi

  ask_yn INIT_GIT "Initialize a git repository?" "$INIT_GIT"

  NS="$ORG.$PROJECT"
  SLUG=$(printf '%s' "$PROJECT" | tr '[:upper:]' '[:lower:]')
}

show_plan() {
  step "Plan"
  kv "Target root"      "$ROOT_DIR"
  kv "Namespace prefix" "$NS"
  kv "Database"         "$DB"
  kv "Nginx"            "$USE_NGINX"
  kv "Keycloak"         "$USE_KEYCLOAK"
  kv "Web scaffold"     "$USE_WEB $DIM(create-next-app, interactive)$RESET"
  kv "Git init"         "$INIT_GIT"
  printf '\n'
}

confirm_or_exit() {
  if [ "$DRY_RUN" = "yes" ]; then
    printf '  %s○ dry run — nothing written.%s\n\n' "$DIM" "$RESET"
    exit 0
  fi
  if [ "$ASSUME_YES" != "yes" ]; then
    local confirm
    ask_yn confirm "Scaffold with these settings?" "yes"
    [ "$confirm" = "yes" ] || { skip "aborted."; exit 0; }
  fi
  require dotnet
  if [ "$INIT_GIT" = "yes" ]; then require git; fi
  DOTNET_TAG=$(dotnet --version 2>/dev/null | cut -d. -f1-2)
  [ -n "$DOTNET_TAG" ] || DOTNET_TAG="10.0"

  mkdir -p "$ROOT_DIR" || die "cannot create target directory: $ROOT_DIR"
  ROOT_DIR=$(cd "$ROOT_DIR" && pwd)
}

# ---------------------------------------------------------------- steps -----

scaffold_structure() {
  step "Creating folder skeleton"
  local d
  for d in \
    "apps/api/src/$NS.Domain" \
    "apps/api/src/$NS.Application" \
    "apps/api/src/$NS.Infrastructure" \
    "apps/api/src/$NS.Api" \
    "apps/web" \
    "deployment" \
    "infrastructure" \
    "scripts"
  do
    if [ -d "$ROOT_DIR/$d" ]; then skip "$d/ already exists"; else
      mkdir -p "$ROOT_DIR/$d"; ok "$d/"
    fi
  done
}

scaffold_api() {
  local api_dir="$ROOT_DIR/apps/api" src_dir="$ROOT_DIR/apps/api/src" sln layer

  step "Scaffolding API — apps/api"
  if [ -n "$(find "$api_dir" -maxdepth 1 \( -name '*.sln' -o -name '*.slnx' \) -print -quit 2>/dev/null)" ]; then
    skip "solution already exists, leaving apps/api untouched"
    return
  fi

  dotnet new sln -n "$NS" -o "$api_dir" >/dev/null
  # .NET 10+ emits .slnx, older SDKs .sln
  sln=$(find "$api_dir" -maxdepth 1 \( -name '*.slnx' -o -name '*.sln' \) -print -quit)
  [ -n "$sln" ] || die "dotnet new sln did not produce a solution file"
  ok "$(basename "$sln")"

  for layer in Domain Application Infrastructure; do
    dotnet new classlib -n "$NS.$layer" -o "$src_dir/$NS.$layer" >/dev/null
    rm -f "$src_dir/$NS.$layer/Class1.cs"
    ok "$NS.$layer"
  done

  dotnet new webapi -n "$NS.Api" -o "$src_dir/$NS.Api" >/dev/null
  ok "$NS.Api"

  for layer in Domain Application Infrastructure Api; do
    dotnet sln "$sln" add "$src_dir/$NS.$layer/$NS.$layer.csproj" >/dev/null
  done
  ok "projects added to solution"
}

scaffold_web() {
  [ "$USE_WEB" = "yes" ] || return 0
  local web_dir="$ROOT_DIR/apps/web"

  step "Scaffolding web — apps/web"
  if [ -f "$web_dir/package.json" ]; then
    skip "package.json already exists, leaving apps/web untouched"
    return
  fi

  info "handing over to create-next-app — answer its prompts yourself"
  printf '\n'
  (
    cd "$ROOT_DIR/apps"
    if command -v pnpm >/dev/null 2>&1; then
      pnpm create next-app web
    else
      require npx
      npx create-next-app@latest web
    fi
  ) || die "create-next-app failed"
  ok "Next.js app created"
}

write_deployment() {
  step "Writing deployment/"

  local compose="$ROOT_DIR/deployment/compose.yaml"
  if [ -f "$compose" ]; then
    skip "compose.yaml already exists"
  else
    local fragments=("$TPL_DIR/compose/head.yaml" "$TPL_DIR/compose/api-$DB.yaml" "$TPL_DIR/compose/web.yaml")
    [ "$DB" != "none" ]          && fragments+=("$TPL_DIR/compose/$DB.yaml")
    [ "$USE_KEYCLOAK" = "yes" ]  && fragments+=("$TPL_DIR/compose/keycloak.yaml")
    [ "$USE_NGINX" = "yes" ]     && fragments+=("$TPL_DIR/compose/nginx.yaml")
    [ "$DB" != "none" ]          && fragments+=("$TPL_DIR/compose/volumes-$DB.yaml")
    render "${fragments[@]}" > "$compose"
    ok "deployment/compose.yaml"
  fi

  local prod="$ROOT_DIR/deployment/compose.prod.yaml"
  if [ -f "$prod" ]; then
    skip "compose.prod.yaml already exists"
  else
    local prod_fragments=("$TPL_DIR/compose-prod/head.yaml")
    if [ "$USE_NGINX" = "yes" ]; then
      prod_fragments+=("$TPL_DIR/compose-prod/api-nginx.yaml" "$TPL_DIR/compose-prod/web-nginx.yaml")
    else
      prod_fragments+=("$TPL_DIR/compose-prod/api.yaml" "$TPL_DIR/compose-prod/web.yaml")
    fi
    [ "$DB" != "none" ] && prod_fragments+=("$TPL_DIR/compose-prod/$DB.yaml")
    if [ "$USE_KEYCLOAK" = "yes" ]; then
      if [ "$DB" = "postgres" ]; then
        prod_fragments+=("$TPL_DIR/compose-prod/keycloak-postgres.yaml")
      else
        prod_fragments+=("$TPL_DIR/compose-prod/keycloak-generic.yaml")
      fi
    fi
    render "${prod_fragments[@]}" > "$prod"
    ok "deployment/compose.prod.yaml"
  fi

  local env_example="$ROOT_DIR/deployment/.env.example"
  if [ -f "$env_example" ]; then
    skip ".env.example already exists"
  else
    local fragments=("$TPL_DIR/env/base.env")
    [ "$DB" != "none" ]          && fragments+=("$TPL_DIR/env/$DB.env")
    [ "$USE_KEYCLOAK" = "yes" ]  && fragments+=("$TPL_DIR/env/keycloak.env")
    [ "$USE_NGINX" = "yes" ]     && fragments+=("$TPL_DIR/env/nginx.env")
    render "${fragments[@]}" > "$env_example"
    cp "$env_example" "$ROOT_DIR/deployment/.env"
    randomize_secrets "$ROOT_DIR/deployment/.env"
    ok "deployment/.env.example (+ .env copy with generated passwords)"
  fi
}

write_dockerfiles() {
  step "Writing Dockerfiles"

  if [ -f "$ROOT_DIR/apps/api/Dockerfile" ]; then
    skip "apps/api/Dockerfile already exists"
  else
    render "$TPL_DIR/Dockerfile.api" > "$ROOT_DIR/apps/api/Dockerfile"
    ok "apps/api/Dockerfile"
  fi

  if [ -f "$ROOT_DIR/apps/web/Dockerfile" ]; then
    skip "apps/web/Dockerfile already exists"
  else
    render "$TPL_DIR/Dockerfile.web" > "$ROOT_DIR/apps/web/Dockerfile"
    ok "apps/web/Dockerfile (needs output: \"standalone\" in next.config)"
  fi
}

write_infrastructure() {
  if [ "$USE_NGINX" != "yes" ] && [ "$USE_KEYCLOAK" != "yes" ] && [ "$DB" != "postgres" ]; then
    return 0
  fi
  step "Writing infrastructure/"

  if [ "$DB" = "postgres" ]; then
    # Mounted into postgres as /docker-entrypoint-initdb.d (may stay empty).
    mkdir -p "$ROOT_DIR/infrastructure/postgres/init"
    if [ "$USE_KEYCLOAK" = "yes" ]; then
      local kc_init="$ROOT_DIR/infrastructure/postgres/init/10-keycloak-db.sh"
      if [ -f "$kc_init" ]; then
        skip "postgres keycloak init script already exists"
      else
        render "$TPL_DIR/postgres-init-keycloak.sh" > "$kc_init"
        chmod +x "$kc_init"
        ok "infrastructure/postgres/init/10-keycloak-db.sh"
      fi
    fi
  fi

  if [ "$USE_NGINX" = "yes" ]; then
    mkdir -p "$ROOT_DIR/infrastructure/nginx"
    local conf="$ROOT_DIR/infrastructure/nginx/nginx.conf"
    if [ -f "$conf" ]; then
      skip "nginx.conf already exists"
    else
      render "$TPL_DIR/nginx.conf" > "$conf"
      ok "infrastructure/nginx/nginx.conf"
    fi
  fi

  if [ "$USE_KEYCLOAK" = "yes" ]; then
    mkdir -p "$ROOT_DIR/infrastructure/keycloak/realms"
    local realm="$ROOT_DIR/infrastructure/keycloak/realms/$SLUG-realm.json"
    if [ -f "$realm" ]; then
      skip "keycloak realm already exists"
    else
      render "$TPL_DIR/keycloak-realm.json" > "$realm"
      ok "infrastructure/keycloak/realms/$SLUG-realm.json"
    fi
  fi
}

write_root_files() {
  step "Writing root files"
  local readme="$ROOT_DIR/README.md"
  if [ -f "$readme" ]; then
    skip "README.md already exists"
  else
    render "$TPL_DIR/README.md.tpl" > "$readme"
    ok "README.md"
  fi

  local workspace="$ROOT_DIR/$PROJECT.code-workspace"
  if [ -f "$workspace" ]; then
    skip "$PROJECT.code-workspace already exists"
  else
    render "$TPL_DIR/workspace.code-workspace" > "$workspace"
    ok "$PROJECT.code-workspace"
  fi
}

init_git_repo() {
  [ "$INIT_GIT" = "yes" ] || return 0

  step "Git"
  if [ -d "$ROOT_DIR/.git" ]; then
    skip "repository already initialized"
  else
    git -C "$ROOT_DIR" init -q
    # No root .gitignore is written and nothing is staged — add your own
    # ignore rules, then review and stage files yourself.
    ok "repository initialized (nothing staged; add a .gitignore yourself)"
  fi
}

show_next_steps() {
  step "Done ${GREEN}✔${RESET}"
  printf '    %s%s%s\n' "$DIM" "$RULE" "$RESET"
  info "${BOLD}Next steps${RESET}"
  info "  1. cd apps/api && dotnet build"
  if [ "$USE_WEB" = "yes" ]; then
    info "  2. cd apps/web and start the dev server"
  else
    info "  2. Scaffold the web app into apps/web (e.g. pnpm create next-app)"
  fi
  info "  3. Ensure next.config has output: \"standalone\" (the web Dockerfile expects it)"
  info "  4. Review deployment/.env (passwords are generated)"
  if [ "$USE_KEYCLOAK" = "yes" ]; then
    info "  5. Keycloak admin: http://localhost:8081 (realm '$SLUG' imported on first start)"
  fi
  info "  Dev:  cd deployment && docker compose up -d --build"
  if [ "$USE_KEYCLOAK" = "yes" ]; then
    info "  Prod: set KEYCLOAK_HOSTNAME in .env, then"
  else
    info "  Prod:"
  fi
  info "        docker compose -f compose.yaml -f compose.prod.yaml --env-file .env up -d --build"
  printf '\n'
  printf '    %s○ See this summary again anytime:%s\n' "$DIM" "$RESET"
  printf '      %s%s/next-steps.sh --dir %s%s\n\n' "$DIM" "$SCRIPT_DIR" "$ROOT_DIR" "$RESET"
}

# ------------------------------------------------------------------ main ----

main() {
  parse_args "$@"
  interview
  show_plan
  confirm_or_exit
  scaffold_structure
  scaffold_api
  scaffold_web
  write_dockerfiles
  write_deployment
  write_infrastructure
  write_root_files
  init_git_repo
  show_next_steps
}

main "$@"
