#!/usr/bin/env bash
# Publish a signed Flatpak build into the hwnhub channel.
#
# Drives every step between "I have an app source tree and a manifest" and
# "users see an update in GNOME Software": runs flatpak-builder into a fresh
# archive-z2 OSTree repo, signs it, merges the new objects into the channel's
# gh-pages branch, regenerates the AppStream summary + landing page, then
# pushes.
#
# Usage:
#   publish.sh \
#     --source-dir   /path/to/app/checkout \
#     --manifest     io.github.hawwwran.flatpal.dev.yaml \
#     --app-id       io.github.hawwwran.flatpal \
#     --app-name     "Flatpal" \
#     --version      0.2.1 \
#     --gpg-key      <KEYID> \
#     [--prebuilt-repo /tmp/some-built-repo] \
#     [--branch stable] \
#     [--push]
#
# By default the script stops before pushing, leaving the worktree in place so
# the user can inspect the diff. Pass --push to publish for real.

set -u

HWNHUB_REMOTE_URL="https://hawwwran.github.io/hwnhub/"
HWNHUB_REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
WHITE='\033[1;37m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m'

die()  { echo -e "${RED}error:${NC} $*" >&2; exit 1; }
info() { echo -e "${WHITE}$*${NC}"; }
ok()   { echo -e "  ${GREEN}$*${NC}"; }
warn() { echo -e "  ${YELLOW}$*${NC}"; }

# ----- args ------------------------------------------------------------------

SOURCE_DIR=""
MANIFEST=""
APP_ID=""
APP_NAME=""
VERSION=""
GPG_KEY=""
PREBUILT_REPO=""
BRANCH="stable"
PUSH=0

while [ $# -gt 0 ]; do
    case "$1" in
        --source-dir)     SOURCE_DIR="$2";    shift 2 ;;
        --manifest)       MANIFEST="$2";      shift 2 ;;
        --app-id)         APP_ID="$2";        shift 2 ;;
        --app-name)       APP_NAME="$2";      shift 2 ;;
        --version)        VERSION="$2";       shift 2 ;;
        --gpg-key)        GPG_KEY="$2";       shift 2 ;;
        --prebuilt-repo)  PREBUILT_REPO="$2"; shift 2 ;;
        --branch)         BRANCH="$2";        shift 2 ;;
        --push)           PUSH=1;             shift   ;;
        -h|--help)
            sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) die "unknown argument: $1" ;;
    esac
done

[ -n "$SOURCE_DIR" ] || die "--source-dir is required"
[ -n "$APP_ID" ]     || die "--app-id is required"
[ -n "$APP_NAME" ]   || die "--app-name is required"
[ -n "$VERSION" ]    || die "--version is required (no leading v)"
[ -n "$GPG_KEY" ]    || die "--gpg-key is required (see README for one-time setup)"

if [ -z "$PREBUILT_REPO" ]; then
    [ -n "$MANIFEST" ] || die "--manifest is required unless --prebuilt-repo is given"
    [ -f "$SOURCE_DIR/$MANIFEST" ] || die "manifest not found: $SOURCE_DIR/$MANIFEST"
fi

[ -d "$SOURCE_DIR" ] || die "source dir not found: $SOURCE_DIR"
[ -f "$HWNHUB_REPO_DIR/templates/index.html.tmpl" ] \
    || die "must be run from a hwnhub clone (templates/ missing)"

# ----- tooling preflight -----------------------------------------------------

for cmd in git gpg ostree flatpak python3; do
    command -v "$cmd" >/dev/null 2>&1 \
        || die "required command not on PATH: $cmd"
done

if [ -z "$PREBUILT_REPO" ]; then
    if ! flatpak --user info org.flatpak.Builder >/dev/null 2>&1; then
        die "org.flatpak.Builder not installed (--user). Install with: flatpak install --user -y flathub org.flatpak.Builder"
    fi
fi

if ! gpg --list-secret-keys "$GPG_KEY" >/dev/null 2>&1; then
    die "no secret GPG key matching '$GPG_KEY' (see README for one-time setup)"
fi

# Resolve to the full long key ID — flatpak-builder accepts short IDs but we
# want the canonical form in apps.json for auditability.
GPG_KEY_LONG=$(gpg --list-secret-keys --keyid-format LONG --with-colons "$GPG_KEY" \
    | awk -F: '/^sec/ {print $5; exit}')
[ -n "$GPG_KEY_LONG" ] || die "couldn't resolve long key ID for $GPG_KEY"

# ----- temp workspace --------------------------------------------------------

# Anchor under $HOME so org.flatpak.Builder (a sandboxed Flatpak) can see it
# via its default --filesystem permissions; /tmp is the sandbox's private /tmp.
WORK=$(mktemp -d -p "$HOME" .hwnhub-publish-XXXXXXXX)

cleanup() {
    [ -n "${WORKTREE:-}" ] && [ -d "$WORKTREE" ] && {
        git -C "$HWNHUB_REPO_DIR" worktree remove --force "$WORKTREE" >/dev/null 2>&1 || true
    }
    rm -rf "$WORK"
}
trap cleanup EXIT

# ----- build (or accept prebuilt) -------------------------------------------

BUILD_REPO="$WORK/build-repo"

if [ -n "$PREBUILT_REPO" ]; then
    info "Using prebuilt OSTree repo: $PREBUILT_REPO"
    [ -d "$PREBUILT_REPO/objects" ] || die "prebuilt repo missing objects/: $PREBUILT_REPO"
    BUILD_REPO="$PREBUILT_REPO"

    # Verify the ref we need is actually in there, regardless of branch label.
    if ! ostree --repo="$BUILD_REPO" refs | grep -qE "(^|/)${APP_ID}(/|$)"; then
        die "prebuilt repo doesn't carry a ref for $APP_ID"
    fi
    ok "ref present"
else
    info "Building Flatpak from $MANIFEST..."
    if ! flatpak run --user org.flatpak.Builder \
        --force-clean \
        --install-deps-from=flathub \
        --repo="$BUILD_REPO" \
        --gpg-sign="$GPG_KEY_LONG" \
        --default-branch="$BRANCH" \
        "$WORK/build-dir" \
        "$SOURCE_DIR/$MANIFEST"; then
        die "flatpak-builder failed (see ${WORK}/build-dir/*/build/meson-logs/)"
    fi
    ok "built into $BUILD_REPO"
fi

# ----- gh-pages worktree -----------------------------------------------------

WORKTREE="$WORK/gh-pages"

cd "$HWNHUB_REPO_DIR"

# Fetch latest gh-pages from origin if we already track it.
if git ls-remote --exit-code --heads origin gh-pages >/dev/null 2>&1; then
    info "Fetching gh-pages from origin..."
    git fetch --quiet origin gh-pages:gh-pages 2>/dev/null || \
        git fetch --quiet origin gh-pages 2>/dev/null || true
    git worktree add --quiet "$WORKTREE" gh-pages \
        || die "failed to check out gh-pages worktree"
    ok "worktree at $WORKTREE"
elif git show-ref --verify --quiet refs/heads/gh-pages; then
    git worktree add --quiet "$WORKTREE" gh-pages \
        || die "failed to check out gh-pages worktree"
    ok "worktree at $WORKTREE (local-only branch — origin will be created on push)"
else
    info "gh-pages branch missing — creating orphan worktree"
    git worktree add --quiet --detach "$WORKTREE" \
        || die "failed to create worktree"
    cd "$WORKTREE"
    git checkout --orphan gh-pages
    git rm -rf --quiet . 2>/dev/null || true
    cd "$HWNHUB_REPO_DIR"
    ok "orphan gh-pages worktree at $WORKTREE"
fi

# ----- merge build objects into gh-pages -----------------------------------

cd "$WORKTREE"

if [ ! -d objects ]; then
    info "Initialising archive-z2 OSTree repo on gh-pages..."
    ostree init --repo=. --mode=archive-z2
    ok "repo initialised"
fi

# Git doesn't track empty directories, so refs/remotes/ and refs/mirrors/
# disappear from gh-pages between publishes. `build-update-repo
# --generate-static-deltas` then fails with "opendir(refs/remotes): No such
# file or directory" when it tries to enumerate every ref kind. Recreate them
# unconditionally — cheap, idempotent, fixes the failure for good.
mkdir -p refs/heads refs/remotes refs/mirrors

info "Importing build into channel repo..."
# Use build-commit-from rather than `ostree pull-local`: pull-local rejects a
# signed source with "Must specify remote name to enable gpg verification" when
# the destination has no matching remote (which is always, for local-to-local).
# build-commit-from copies the ref's content into a fresh commit on the dest
# and signs it with our key in one step — exactly what we want.
mapfile -t BUILD_REFS < <(ostree --repo="$BUILD_REPO" refs)
[ "${#BUILD_REFS[@]}" -gt 0 ] || die "build repo has no refs"

for ref in "${BUILD_REFS[@]}"; do
    if ! flatpak build-commit-from \
        --src-repo="$BUILD_REPO" \
        --src-ref="$ref" \
        --gpg-sign="$GPG_KEY_LONG" \
        --no-update-summary \
        . "$ref" >/dev/null; then
        die "build-commit-from failed for ref: $ref"
    fi
done
ok "imported ${#BUILD_REFS[@]} ref(s)"

# ----- regenerate channel metadata -----------------------------------------

# pubkey.gpg — exported public key, also embedded into the .flatpakref/.flatpakrepo
# files below. Always re-export so a rotated key gets picked up automatically.
gpg --export "$GPG_KEY_LONG" > pubkey.gpg
GPG_KEY_B64=$(base64 -w0 pubkey.gpg)

# apps.json — registry of what's in this channel. publish.sh upserts the entry
# for the current --app-id, then the index.html regenerator reads it back.
[ -f apps.json ] || echo '[]' > apps.json

python3 - "$APP_ID" "$APP_NAME" "$VERSION" "$BRANCH" <<'PYEOF'
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

app_id, app_name, version, branch = sys.argv[1:5]
path = Path("apps.json")
apps = json.loads(path.read_text() or "[]")

now = datetime.now(timezone.utc).strftime("%Y-%m-%d")
entry = {
    "app_id": app_id,
    "name": app_name,
    "version": version,
    "branch": branch,
    "updated": now,
    "flatpakref": f"{app_id}.flatpakref",
}

found = False
for i, app in enumerate(apps):
    if app["app_id"] == app_id:
        apps[i] = entry
        found = True
        break
if not found:
    apps.append(entry)

apps.sort(key=lambda a: a["name"].lower())
path.write_text(json.dumps(apps, indent=2) + "\n")
PYEOF
ok "apps.json updated"

# Per-app .flatpakref — clicking this in a browser installs the app + adds
# the hwnhub remote on first install. GPGKey is inline base64 so the user
# doesn't have to trust the URL alone.
sed \
    -e "s|@APP_ID@|${APP_ID}|g" \
    -e "s|@APP_NAME@|${APP_NAME}|g" \
    -e "s|@GPG_KEY_BASE64@|${GPG_KEY_B64}|g" \
    "$HWNHUB_REPO_DIR/templates/app.flatpakref.tmpl" \
    > "${APP_ID}.flatpakref"

# Channel-wide .flatpakrepo — lets users add the remote without installing
# any specific app. Stays the same across releases; regenerate only if missing
# or if the pubkey rotated.
cat > hwnhub.flatpakrepo <<EOF
[Flatpak Repo]
Title=hwnhub
Url=${HWNHUB_REMOTE_URL}
Homepage=https://github.com/hawwwran/hwnhub
Comment=Self-hosted Flatpak channel for hawwwran's apps
GPGKey=${GPG_KEY_B64}
EOF

# Landing page — re-rendered from apps.json so newly published apps show up.
python3 - "$HWNHUB_REPO_DIR/templates/index.html.tmpl" <<'PYEOF'
import html
import json
import sys
from pathlib import Path

tmpl = Path(sys.argv[1]).read_text()
apps = json.loads(Path("apps.json").read_text())

if not apps:
    block = '    <p class="empty">No apps published yet.</p>'
else:
    lines = []
    for app in apps:
        lines.append('    <div class="app">')
        lines.append(f'      <span class="app-name">{html.escape(app["name"])}</span>')
        lines.append(f'      <span class="app-version">{html.escape(app["version"])}</span>')
        lines.append(
            f'      <a class="app-ref" href="{html.escape(app["flatpakref"])}">install</a>'
        )
        lines.append('    </div>')
    block = "\n".join(lines)

Path("index.html").write_text(tmpl.replace("@APP_LIST@", block))
PYEOF
ok "index.html regenerated"

# ----- final summary + signing ---------------------------------------------

info "Regenerating AppStream summary and static deltas..."
if ! flatpak build-update-repo \
    --gpg-sign="$GPG_KEY_LONG" \
    --generate-static-deltas \
    --prune-depth=3 \
    .; then
    die "flatpak build-update-repo failed"
fi
ok "summary signed and updated"

# ----- commit + (maybe) push ----------------------------------------------

git -C "$WORKTREE" add -A
if git -C "$WORKTREE" diff --cached --quiet; then
    warn "no changes staged — already up to date?"
    exit 0
fi

COMMIT_MSG="Publish ${APP_ID} ${VERSION}"
git -C "$WORKTREE" -c user.name="hwnhub" -c user.email="hwnhub@hawwwran.dev" \
    commit -q -m "$COMMIT_MSG"
ok "committed on gh-pages"

echo ""
info "Channel state after this publish:"
echo -e "  Landing page : ${CYAN}${HWNHUB_REMOTE_URL}${NC}"
echo -e "  Install URL  : ${CYAN}${HWNHUB_REMOTE_URL}${APP_ID}.flatpakref${NC}"
echo -e "  Branch       : ${CYAN}${BRANCH}${NC}"
echo -e "  Signed by    : ${CYAN}${GPG_KEY_LONG}${NC}"
echo ""

if [ "$PUSH" = "1" ]; then
    info "Pushing gh-pages..."
    if ! git -C "$WORKTREE" push --quiet origin gh-pages; then
        die "git push failed — gh-pages stays on the local clone for inspection"
    fi
    ok "pushed"
else
    warn "skipping push (re-run with --push to publish)"
    warn "gh-pages worktree has been removed by the trap; the commit lives on"
    warn "the local gh-pages branch. To push manually:"
    echo -e "    ${CYAN}git -C ${HWNHUB_REPO_DIR} push origin gh-pages${NC}"
fi
