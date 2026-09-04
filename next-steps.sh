#!/usr/bin/env bash
#
# next-steps.sh — show the wizard's closing "next steps" message again, any
# time after init-project.sh has run, together with a status check
# of what exists so far. Everything is detected from the repo on disk; the
# script prompts for nothing and changes nothing.
#
#   ./next-steps.sh [--dir <path>]
#
set -euo pipefail

# ---------------------------------------------------------------- output ----

APP_NAME="Overwhelmed"
APP_VERSION="2.0.0"

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
warn()  { printf '    %s▲%s %s\n' "$YELLOW" "$RESET" "$*"; }
die()   { printf '\n  %s✖ error:%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }
kv()    { printf '    %s%-18s%s %s\n' "$DIM" "$1" "$RESET" "$2"; }

# ------------------------------------------------------------- arguments ----

ROOT_DIR=$PWD

usage() {
  cat <<USAGE
${BOLD}Overwhelmed${RESET} — repo status + next-steps message

Usage: ${OVERWHELMED_PROG:-./next-steps.sh} [--dir <path>]

Options:
  --dir <path>   Repo root to inspect (default: current directory)
  -h, --help     Show this help
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dir)     ROOT_DIR=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *)         usage >&2; die "unknown option: $1" ;;
  esac
done

[ -d "$ROOT_DIR" ] || die "root directory does not exist: $ROOT_DIR"
ROOT_DIR=$(cd "$ROOT_DIR" && pwd)

# ---------------------------------------------------------------- detect ----

SLN=$(find "$ROOT_DIR/apps/api" -maxdepth 1 \( -name '*.slnx' -o -name '*.sln' \) -print -quit 2>/dev/null || true)
NS=""; PROJECT=""; SLUG=""
if [ -n "$SLN" ]; then
  NS=$(basename "$SLN"); NS=${NS%.slnx}; NS=${NS%.sln}
  PROJECT=${NS##*.}
  SLUG=$(printf '%s' "$PROJECT" | tr '[:upper:]' '[:lower:]')
fi

WEB_READY="no"
[ -f "$ROOT_DIR/apps/web/package.json" ] && WEB_READY="yes"

WEB_STANDALONE="no"
if grep -qs 'standalone' "$ROOT_DIR/apps/web"/next.config.* 2>/dev/null; then
  WEB_STANDALONE="yes"
fi

ENV_FILE="$ROOT_DIR/deployment/.env"
HAS_KEYCLOAK="no"
[ -d "$ROOT_DIR/infrastructure/keycloak" ] && HAS_KEYCLOAK="yes"

# ---------------------------------------------------------------- status ----

banner "Status · $ROOT_DIR"
step "Status"

if [ -n "$SLN" ]; then
  PROJ_COUNT=$(find "$ROOT_DIR/apps/api/src" -maxdepth 2 -name '*.csproj' 2>/dev/null | wc -l | tr -d ' ')
  ok "API solution       $(basename "$SLN") ($PROJ_COUNT projects)"
else
  INIT_CMD="init-project.sh"
  [ -z "${OVERWHELMED_PROG:-}" ] || INIT_CMD="${OVERWHELMED_PROG% *} init"
  warn "API solution       missing — run $INIT_CMD --dir $ROOT_DIR"
fi

if [ "$WEB_READY" = "yes" ]; then
  ok "Web app            apps/web scaffolded"
  if [ "$WEB_STANDALONE" = "yes" ]; then
    ok "Web standalone     output: \"standalone\" configured"
  else
    warn "Web standalone     add output: \"standalone\" to next.config (Dockerfile expects it)"
  fi
else
  warn "Web app            not scaffolded yet"
fi

for f in apps/api/Dockerfile apps/web/Dockerfile \
         deployment/compose.yaml deployment/compose.prod.yaml; do
  if [ -f "$ROOT_DIR/$f" ]; then ok "$f"; else warn "$f missing"; fi
done

if [ -f "$ENV_FILE" ]; then
  if grep -q "change-me" "$ENV_FILE"; then
    warn "deployment/.env    contains 'change-me' passwords — replace them"
  else
    ok "deployment/.env    passwords set"
  fi
  if grep -q "^KEYCLOAK_HOSTNAME=auth.example.com" "$ENV_FILE"; then
    warn "Keycloak hostname  still auth.example.com — set it before production"
  fi
else
  warn "deployment/.env missing"
fi

if [ -f "$ROOT_DIR/infrastructure/nginx/nginx.conf" ]; then
  ok "infrastructure/nginx/nginx.conf"
else
  skip "nginx not configured"
fi

if [ "$HAS_KEYCLOAK" = "yes" ]; then
  ok "infrastructure/keycloak (realm import on first start)"
else
  skip "keycloak not configured"
fi

# ------------------------------------------------------------ next steps ----

step "Next steps"
info "  1. cd apps/api && dotnet build"
if [ "$WEB_READY" = "yes" ]; then
  info "  2. cd apps/web and start the dev server"
else
  info "  2. Scaffold the web app into apps/web (e.g. pnpm create next-app)"
fi
if [ "$WEB_STANDALONE" != "yes" ]; then
  info "  3. Ensure next.config has output: \"standalone\" (the web Dockerfile expects it)"
fi
info "  4. Review deployment/.env (passwords are generated)"
if [ "$HAS_KEYCLOAK" = "yes" ]; then
  info "  5. Keycloak admin: http://localhost:8081 (realm '${SLUG:-<project>}' imported on first start)"
fi
info "  Dev:  cd deployment && docker compose up -d --build"
if [ "$HAS_KEYCLOAK" = "yes" ]; then
  info "  Prod: set KEYCLOAK_HOSTNAME in .env, then"
else
  info "  Prod:"
fi
info "        docker compose -f compose.yaml -f compose.prod.yaml --env-file .env up -d --build"
printf '\n'
