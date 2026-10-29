#!/bin/sh
# Applies this bundle's dsh profile configuration to ~/.dsh.
#
# The configuration is embedded below so that this single script is enough to
# reproduce the setup on another host. Existing files are kept unless --force
# is passed, so re-running on a machine that is already configured is safe.
#
# Deliberately NOT shipped:
#   * ~/.dsh/.credentials.yaml — contains the browser-session secret. The first
#     `dsh web` on the new host creates its own file; authorize again there.
#   * ~/.dsh/storages/         — session/workspace state of the old host.
#   * ~/.dsh/profiles/node_modules — upstream links it with absolute paths into
#     the old host's npx cache; dsh recreates what it needs on first boot.
#
# Usage: sh apply-config.sh [--force] [--dsh-home <dir>]
set -eu

FORCE=0
DSH_HOME_DIR="${DSH_HOME:-$HOME/.dsh}"

while [ $# -gt 0 ]; do
	case "$1" in
		--force) FORCE=1; shift ;;
		--dsh-home)
			[ $# -ge 2 ] || { echo "error: --dsh-home needs a value" >&2; exit 2; }
			DSH_HOME_DIR="$2"; shift 2 ;;
		-h|--help)
			cat <<'USAGE'
Applies this bundle's dsh profile configuration to ~/.dsh.

Writes the `web` profile (package.json, cordis.yml, cordis.patch.yml,
pnpm-workspace.yaml) and keeps files that already exist, so re-running on an
already configured host is safe.

Deliberately NOT shipped:
  * ~/.dsh/.credentials.yaml — holds the browser-session secret; the first
    `dsh web` on the new host creates its own, so authorize again there.
  * ~/.dsh/storages/ — session and workspace state of the old host.
  * ~/.dsh/profiles/node_modules — absolute symlinks into the old host's npx
    cache; dsh recreates what it needs on first boot.

Usage: sh apply-config.sh [options]
  --force            overwrite existing files
  --dsh-home <dir>   target this dir instead of ~/.dsh
  -h, --help         show this help
USAGE
			exit 0 ;;
		*) echo "error: unknown option: $1" >&2; exit 2 ;;
	esac
done

write_target() {
	_dest="$1"
	if [ -e "$_dest" ] && [ "$FORCE" -ne 1 ]; then
		echo "    keep existing: $_dest"
		cat >/dev/null
		return 0
	fi
	mkdir -p "$(dirname "$_dest")"
	cat >"$_dest"
	echo "    wrote: $_dest"
}

echo "    target: $DSH_HOME_DIR/profiles/web"

write_target "$DSH_HOME_DIR/profiles/web/package.json" <<'EOF'
{
  "name": "dsh-profile-web",
  "private": true,
  "dependencies": {},
  "dsh": {
    "profile": {
      "bundles": [
        "@deepseek-ai/dsh-base",
        "@deepseek-ai/dsh-web-app"
      ],
      "patchReload": "live"
    }
  }
}
EOF

write_target "$DSH_HOME_DIR/profiles/web/cordis.yml" <<'EOF'
# dsh profile root — an empty entry list. The tree is composed as patches:
# each bundle in package.json's dsh.profile.bundles, then cordis.patch.yml, then any
# --patch overlays. Edit cordis.patch.yml, not this file.
[]
EOF

write_target "$DSH_HOME_DIR/profiles/web/cordis.patch.yml" <<'EOF'
# Your patch layer for this dsh profile, applied after every bundle layer:
# a top-level YAML array of loader patch entries (id-targeted config
# overrides, disables, and insert lists; `!!js` expressions allowed).
[]
EOF

write_target "$DSH_HOME_DIR/profiles/web/pnpm-workspace.yaml" <<'EOF'
packages:
  - .

nodeLinker: hoisted
autoInstallPeers: false
EOF

echo "    profile config applied"
