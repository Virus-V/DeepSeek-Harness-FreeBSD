/**
 * FreeBSD shim for @deepseek-ai/dsh.
 *
 * dsh 通过 `node-addon-require-builtin` 这个原生插件拿到 Node 内部模块
 * (internal/modules/esm/loader 等)，用来 hook ESM/CJS 解析器。该插件只发布
 * darwin/linux/win32 的预编译二进制，FreeBSD 上没有可用的 native binding，
 * 并且官方对发布包采取 fail-closed（不编译本地二进制）策略。
 *
 * 这个 preload 脚本用 `--expose-internals` 下的普通 require 提供等价实现，
 * 从而让 dsh 在 FreeBSD 上启动：
 *
 *   node --expose-internals --require /path/to/shim.js \
 *        /path/to/node_modules/@deepseek-ai/dsh/lib/bin.js web
 */
'use strict';

const Module = require('node:module');

function requireBuiltin(moduleId) {
  return require(moduleId);
}

function isAllowedInternalId() {
  return true;
}

function getBindingInfo() {
  return {
    mode: 'js-shim',
    product: 'require-builtin',
    backend: 'js',
    abi: `node-v${process.versions.modules}`,
    bindingSource: 'freebsd-shim',
    bindingPath: null,
  };
}

const shim = { requireBuiltin, isAllowedInternalId, getBindingInfo };
shim.default = shim;

const originalLoad = Module._load;
Module._load = function load(request, parent, isMain) {
  if (request === 'node-addon-require-builtin') return shim;
  return originalLoad.apply(this, arguments);
};
