#!/bin/sh
# Deploy @deepseek-ai/dsh on FreeBSD.
#
# Why this package exists — upstream publishes native prebuilds only for
# darwin/linux/win32, and the npm packages fail closed on anything else:
#   * node-addon-require-builtin has no freebsd-x64 binding. dsh needs it to read
#     Node's internal/modules/* loaders, so it dies at startup with
#     "No usable native binding found for node-addon-require-builtin-freebsd-x64".
#   * node-pty has no freebsd prebuild, and its src/unix/pty.cc calls
#     pty_close_inherited_fds(), which upstream defines for Linux only, so
#     `node-gyp rebuild` fails with "use of undeclared identifier".
#
# What this script does:
#   1. checks the environment (FreeBSD, Node >= 20, npm, build tools)
#   2. installs @deepseek-ai/dsh with --ignore-scripts
#   3. patches node-pty's pty.cc for FreeBSD and compiles it from source
#   4. writes a launcher that runs dsh with --expose-internals + shim.js, which
#      replaces the missing native binding with a plain require()
#   5. applies this bundle's dsh profile config (see apply-config.sh)
#   6. links the launcher to ~/.local/bin/dsh
#
# Usage: sh install.sh [options]
#   --version <ver>   dsh version to install            (default 0.2.1-rc.2)
#   --root <dir>      install prefix      (default ~/.local/share/dsh-freebsd)
#   --bin-dir <dir>   launcher symlink dir          (default ~/.local/bin)
#   --no-config       do not touch ~/.dsh
#   --force-config    overwrite existing ~/.dsh profile files
#   --no-link         do not create ~/.local/bin/dsh
#   --skip-pty        skip the node-pty build (terminal feature stays off)
#   -h, --help        show this help
set -eu

DEFAULT_VERSION="0.2.1-rc.2"
VERSION="$DEFAULT_VERSION"
ROOT="${DSH_FREEBSD_ROOT:-$HOME/.local/share/dsh-freebsd}"
BIN_DIR="$HOME/.local/bin"
DO_CONFIG=1
DO_LINK=1
DO_PTY=1
CONFIG_ARGS=""
SRC=$(cd "$(dirname "$0")" && pwd)

usage() {
	awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$SRC/install.sh"
}

while [ $# -gt 0 ]; do
	case "$1" in
		--version)
			[ $# -ge 2 ] || { echo "error: --version needs a value" >&2; exit 2; }
			VERSION="$2"; shift 2 ;;
		--root)
			[ $# -ge 2 ] || { echo "error: --root needs a value" >&2; exit 2; }
			ROOT="$2"; shift 2 ;;
		--bin-dir)
			[ $# -ge 2 ] || { echo "error: --bin-dir needs a value" >&2; exit 2; }
			BIN_DIR="$2"; shift 2 ;;
		--no-config) DO_CONFIG=0; shift ;;
		--force-config) CONFIG_ARGS="--force"; shift ;;
		--no-link) DO_LINK=0; shift ;;
		--skip-pty) DO_PTY=0; shift ;;
		-h|--help) usage; exit 0 ;;
		*) echo "error: unknown option: $1" >&2; usage >&2; exit 2 ;;
	esac
done

step() { printf '\n==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

# --------------------------------------------------------------------------
step "checking environment"
os=$(uname -s)
arch=$(uname -m)
[ "$os" = "FreeBSD" ] || warn "this bundle targets FreeBSD, detected $os — continuing anyway"
command -v node >/dev/null 2>&1 || die "node not found in PATH (dsh needs Node >= 20)"
command -v npm  >/dev/null 2>&1 || die "npm not found in PATH"
node_major=$(node -p 'process.versions.node.split(".")[0]')
[ "$node_major" -ge 20 ] || die "Node $node_major is too old; dsh needs Node >= 20"
printf '    node %s (%s/%s, ABI node-v%s), npm %s, %s %s\n' \
	"$(node -v)" "$(node -p 'process.platform')" "$(node -p 'process.arch')" \
	"$(node -p 'process.versions.modules')" "$(npm -v)" "$os" "$arch"

GYP=""
if command -v node-gyp >/dev/null 2>&1; then
	GYP="node-gyp"
elif command -v npx >/dev/null 2>&1; then
	GYP="npx --yes node-gyp"
fi
if [ "$DO_PTY" -eq 1 ]; then
	missing=""
	for tool in cc make python3; do
		command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"
	done
	if [ -n "$missing" ]; then
		warn "missing build tools:$missing"
		warn "node-pty cannot be compiled, so the terminal feature will be off"
		warn "install them or rerun with --skip-pty to silence this"
		DO_PTY=0
	elif [ -z "$GYP" ]; then
		warn "node-gyp not found and npx unavailable; skipping node-pty"
		DO_PTY=0
	fi
fi

# --------------------------------------------------------------------------
step "installing @deepseek-ai/dsh@$VERSION into $ROOT/app"
mkdir -p "$ROOT/app"
cd "$ROOT/app"
if [ ! -f package.json ]; then
	printf '{"name":"dsh-freebsd","private":true}\n' >package.json
fi
npm install --ignore-scripts --no-audit --no-fund "@deepseek-ai/dsh@$VERSION" ||
	die "npm install failed (needs access to the npm registry)"
[ -f "$ROOT/app/node_modules/@deepseek-ai/dsh/lib/bin.js" ] ||
	die "dsh entry point missing after install: $ROOT/app/node_modules/@deepseek-ai/dsh/lib/bin.js"
printf '    dsh %s installed\n' "$(node -p "require('$ROOT/app/node_modules/@deepseek-ai/dsh/package.json').version")"

# --------------------------------------------------------------------------
if [ "$DO_PTY" -eq 1 ] && [ -d "$ROOT/app/node_modules/node-pty" ]; then
	step "patching node-pty for FreeBSD"
	cd "$ROOT/app/node_modules/node-pty"
	node - <<'PATCH'
const fs = require('node:fs');
const file = 'src/unix/pty.cc';
let src = fs.readFileSync(file, 'utf8');
if (src.includes('closefrom(3)')) {
  console.log('    node-pty already carries the FreeBSD branch');
  process.exit(0);
}
const anchor = `  for (fd = 3; ; fd++)\n    if (SetCloseOnExec(fd) && fd > 15)\n      break;\n}\n#endif\n`;
const patch = `  for (fd = 3; ; fd++)\n    if (SetCloseOnExec(fd) && fd > 15)\n      break;\n}\n#elif defined(__FreeBSD__)\n/* FreeBSD: closefrom(2) covers the same CLOEXEC intent inside the forked child. */\nstatic void\npty_close_inherited_fds() {\n  closefrom(3);\n}\n#endif\n`;
if (!src.includes(anchor)) {
  console.error('error: node-pty patch anchor not found (upstream source changed)');
  process.exit(1);
}
fs.writeFileSync(file, src.replace(anchor, patch));
console.log('    node-pty patched');
PATCH
	if [ "$?" -ne 0 ]; then
		warn "could not patch node-pty; terminal feature will be off"
	else
		step "compiling node-pty from source"
		if $GYP rebuild; then
			printf '    node-pty built: %s\n' "$(ls build/Release/pty.node 2>/dev/null || echo 'missing')"
		else
			warn "node-pty build failed; dsh works but its terminal feature stays off"
		fi
	fi
fi

# --------------------------------------------------------------------------
step "writing launcher and shim"
cp "$SRC/shim.js" "$ROOT/shim.js"
cat >"$ROOT/dsh" <<'LAUNCHER'
#!/bin/sh
set -eu
root="${DSH_FREEBSD_ROOT:-$HOME/.local/share/dsh-freebsd}"
bin="$root/app/node_modules/@deepseek-ai/dsh/lib/bin.js"
if [ ! -f "$bin" ]; then
	echo "dsh: not installed at $root (run $root/install.sh first)" >&2
	exit 1
fi
exec node --expose-internals --require "$root/shim.js" "$bin" "$@"
LAUNCHER
chmod +x "$ROOT/dsh"
printf '    %s\n' "$ROOT/dsh"
printf '    %s\n' "$ROOT/shim.js"

# --------------------------------------------------------------------------
if [ "$DO_CONFIG" -eq 1 ] && [ -f "$SRC/apply-config.sh" ]; then
	step "applying dsh profile config"
	# shellcheck disable=SC2086
	sh "$SRC/apply-config.sh" $CONFIG_ARGS
fi

# --------------------------------------------------------------------------
if [ "$DO_LINK" -eq 1 ]; then
	step "linking launcher"
	mkdir -p "$BIN_DIR"
	ln -sf "$ROOT/dsh" "$BIN_DIR/dsh"
	printf '    %s -> %s\n' "$BIN_DIR/dsh" "$ROOT/dsh"
	case ":$PATH:" in
		*":$BIN_DIR:"*) ;;
		*) warn "$BIN_DIR is not in PATH; add it to use the bare \`dsh\` command" ;;
	esac
fi

# --------------------------------------------------------------------------
step "done"
cat <<EOF
    start the Web UI:  $ROOT/dsh web
    (or just 'dsh web' if $BIN_DIR is in PATH)

    Notes
      * ~/.dsh/.credentials.yaml is NOT shipped; the first Web UI session
        creates one, so log in / authorize again on this host.
      * Upgrade later with: sh install.sh --version <newer version>
      * If dsh reports "No usable native binding ..." the shim is not active:
        always start dsh through $ROOT/dsh (it passes --expose-internals
        --require shim.js); 'npx @deepseek-ai/dsh' cannot work on FreeBSD.
EOF
