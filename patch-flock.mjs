/*
 * FreeBSD flock binding for @deepseek-ai/node-addon-system.
 *
 * Why: dsh persists sessions through @deepseek-ai/dsh-session-persistence-jsonl,
 * which takes an exclusive flock() on every session log. The flock entry point
 * of @deepseek-ai/node-addon-system has prebuilt binaries for darwin/linux only
 * and hard-codes that allow-list, so on FreeBSD every session write fails with
 * "flock is not supported on freebsd-x64" (ERR_FLOCK_UNSUPPORTED_PLATFORM).
 * FreeBSD does provide flock(2) and the npm package ships src/flock.c, so we
 * compile that source locally and teach the loader about freebsd.
 *
 * Usage: node patch-flock.mjs <app-dir>
 *   <app-dir> is the directory holding node_modules (e.g. ~/.local/share/dsh-freebsd/app).
 * Idempotent: safe to re-run after every npm install.
 */
import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';

const appRoot = resolve(process.argv[2] ?? '.');
const pkgDir = join(appRoot, 'node_modules', '@deepseek-ai', 'node-addon-system');

if (!existsSync(pkgDir)) {
  console.log('[flock] @deepseek-ai/node-addon-system not installed; nothing to do');
  process.exit(0);
}

if (process.platform !== 'freebsd') {
  console.log(`[flock] platform is ${process.platform}, not freebsd; nothing to do`);
  process.exit(0);
}

// ---------------------------------------------------------------- 1. compile
const src = join(pkgDir, 'src', 'flock.c');
const outDir = join(pkgDir, 'bin');
const out = join(outDir, 'system.node');

if (!existsSync(src)) {
  console.error('[flock] src/flock.c is missing; cannot build the binding');
  process.exit(1);
}

const includeCandidates = [
  '/usr/local/include/node',
  join(process.execPath, '..', '..', 'include', 'node'),
];
const includeDir = includeCandidates.find((dir) => existsSync(join(dir, 'node_api.h')));
if (includeDir === undefined) {
  console.error('[flock] node_api.h not found; install the node headers (pkg install node)');
  process.exit(1);
}

mkdirSync(outDir, { recursive: true });
execFileSync(process.env.CC ?? 'cc', ['-shared', '-fPIC', '-I', includeDir, '-o', out, src], {
  stdio: 'inherit',
});
console.log(`[flock] built ${out}`);

// ------------------------------------------------------------- 2. patch loader
const loader = join(pkgDir, 'lib', 'flock.js');
let code = readFileSync(loader, 'utf8');

if (code.includes("platform === 'freebsd'")) {
  console.log('[flock] loader already knows about freebsd');
  process.exit(0);
}

const guardFrom = "if (platform !== 'linux' && platform !== 'darwin') {";
const guardTo = "if (platform !== 'linux' && platform !== 'darwin' && platform !== 'freebsd') {";
if (!code.includes(guardFrom)) {
  console.error('[flock] platform guard anchor not found (upstream source changed)');
  process.exit(1);
}
code = code.replace(guardFrom, guardTo);

const importAnchor = "import { getSystemErrorName } from 'node:util';";
if (!code.includes(importAnchor)) {
  console.error('[flock] node:util import anchor not found (upstream source changed)');
  process.exit(1);
}
code = code.replace(importAnchor, `${importAnchor}\nimport { fileURLToPath } from 'node:url';`);

const requireAnchor = '    const require = createRequire(import.meta.url);\n';
if (code.split(requireAnchor).length !== 2) {
  console.error('[flock] createRequire anchor is not unique (upstream source changed)');
  process.exit(1);
}
const freebsdBranch = `${requireAnchor}    if (platform === 'freebsd') {
        binding = require(join(dirname(fileURLToPath(import.meta.url)), '..', 'bin', filename));
        return binding;
    }
`;
code = code.replace(requireAnchor, freebsdBranch);

writeFileSync(loader, code);
console.log(`[flock] loader patched: ${loader}`);
