# Developing Overwhelmed

This is the maintainer guide: working from a checkout, changing the
generated output, building the bundle, and cutting a release. End-user
docs are in [README.md](README.md).

## Repository layout

```text
init-project.sh     the wizard (bundle sub-command: init)
next-steps.sh       status + next-steps summary (bundle sub-command: next-steps)
templates/          all generated file content (edit these, not the scripts)
pack.sh             builds dist/ and optionally installs the bundle
dist/               build output — generated, git-ignored, never edited
.github/workflows/release.yml   builds + attaches the bundle on a v* tag
```

Both scripts carry the app name and version near the top:

```bash
APP_NAME="Overwhelmed"
APP_VERSION="2.0.0"
```

## Running from a checkout

No build step is needed to try changes — run the scripts directly:

```bash
./init-project.sh                  # the wizard
./init-project.sh -y --dry-run     # print the plan, write nothing
./next-steps.sh --dir <repo>       # status view
```

The repo's `.gitignore` excludes `apps/`, `deployment/`, `infrastructure/`,
`scripts/` and friends, so you can scaffold straight into the checkout for
a quick test and clean up afterwards.

Set `NO_COLOR=1` to check the plain-text output; when stdout is not a
terminal the scripts drop colours automatically.

## Changing what gets generated

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

## Building the bundle

```bash
./pack.sh
```

builds two distributables into `dist/`:

- `overwhelmed.tar.gz` — the two scripts + `templates/`; extract anywhere
  and run `./init-project.sh`
- `overwhelmed.sh` — a single self-contained executable (~20 KB) with the
  templates embedded as base64. It self-extracts to a temp dir per run and
  cleans up after itself. Its first argument selects the script:
  `init` (default) or `next-steps`; everything else is passed through.

Re-run `./pack.sh` after changing the scripts or templates — the bundle is
generated, never edited by hand.

### Installing your local build as `overwhelmed`

```bash
./pack.sh --install            # -> /usr/local/bin/overwhelmed (or ~/.local/bin if not writable)
./pack.sh --install ~/bin      # -> ~/bin/overwhelmed
```

This packs first, then copies the bundle into place. If the directory is not
on your `PATH`, it prints the `export PATH=…` line to add. Handy for testing
the exact file users will get.

## Cutting a release

Releases are built by CI from a `v*` tag: the workflow runs `./pack.sh`,
smoke-tests `dist/overwhelmed.sh --help`, and attaches `overwhelmed.sh` and
`overwhelmed.tar.gz` to a GitHub release with auto-generated notes. The
README's install one-liner always points at `releases/latest`, so the newest
tag is what users get.

1. **Bump the version** in both scripts (they must match):

   ```bash
   sed -i '' 's/^APP_VERSION=.*/APP_VERSION="2.1.0"/' init-project.sh next-steps.sh
   grep -n '^APP_VERSION=' init-project.sh next-steps.sh
   ```

2. **Build and check** the bundle locally:

   ```bash
   ./pack.sh
   ./dist/overwhelmed.sh --help
   ./dist/overwhelmed.sh -y --dry-run          # banner should show the new version
   ```

3. **Commit and tag** (annotated tags are preferred; lightweight also work):

   ```bash
   git add -A
   git commit -m "release: Overwhelmed 2.1.0"
   git tag -a v2.1.0 -m "Overwhelmed 2.1.0"
   ```

4. **Push the branch and the tag** — the tag push is what triggers the
   release workflow:

   ```bash
   git push origin main v2.1.0
   ```

5. **Verify** on GitHub: the Release workflow is green and the release page
   lists both assets. Then confirm the public URL serves the new build:

   ```bash
   curl -fsSL https://github.com/athene-x/Overwhelmed/releases/latest/download/overwhelmed.sh \
     -o /tmp/overwhelmed && bash /tmp/overwhelmed -y --dry-run | head -3
   ```

   (The bundle reads its embedded payload from its own file, so it must be
   saved to disk — piping it into `bash -s` does not work.)

### Versioning

Semantic versioning: bump the **major** for changes that break flags, the
sub-command interface, or the generated layout in incompatible ways; the
**minor** for new options, services, or templates; the **patch** for fixes
and cosmetic changes.

### If a release went wrong

Delete the tag locally and on the remote, fix, and re-tag. Also delete the
GitHub release that the workflow created, otherwise `releases/latest` may
keep pointing at it:

```bash
git tag -d v2.1.0
git push origin :refs/tags/v2.1.0
```
