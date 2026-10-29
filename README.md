# dsh on FreeBSD 部署包

在 FreeBSD 上部署 [`@deepseek-ai/dsh`](https://www.npmjs.com/package/@deepseek-ai/dsh)。
上游发布包在 FreeBSD 上开箱即报错，本包把它补起来。

```
dsh-freebsd/
├── install.sh        # 环境自检 + 安装 dsh + 编译原生模块 + 生成启动器
├── apply-config.sh   # 把 dsh profile 配置写进 ~/.dsh
├── patch-flock.mjs   # 编译 FreeBSD 版 flock 绑定，并给上游 loader 加 freebsd 分支
├── shim.js           # 运行时顶替缺失的原生绑定
├── LICENSE
└── README.md
```

## 为什么上游在 FreeBSD 上跑不起来

```
$ npx @deepseek-ai/dsh web
dsh: host preparation failed: No usable native binding found for
node-addon-require-builtin-freebsd-x64 (auto)
```

- `node-addon-require-builtin` 是 dsh 用来访问 Node `internal/modules/*`
  内部加载器的原生插件，**只发布了 darwin / linux / win32 的预编译二进制，
  没有 `freebsd-x64`**；而且发布包是 fail-closed 的：没有匹配的预编译包时
  直接失败，不会编译本地二进制（npm 包里也不带 native 源码）。
- `node-pty` 同样没有 freebsd 预编译，且它的 `src/unix/pty.cc` 调用了只在
  Linux 分支定义的 `pty_close_inherited_fds()`，直接 `node-gyp rebuild`
  会报 `use of undeclared identifier: 'pty_close_inherited_fds'`。
- `@deepseek-ai/node-addon-system`（dsh 用它做 session 文件的排他锁）在 JS
  里把平台写死成 darwin/linux，FreeBSD 上一写会话就报
  `flock is not supported on freebsd-x64`（`ERR_FLOCK_UNSUPPORTED_PLATFORM`）。
  但 FreeBSD 本身**有** `flock(2)`，而且这个 npm 包把 `src/flock.c` 一起发布了。

## 本包的做法

1. `shim.js` 被 preload 进进程，用普通 `require()` 实现 `requireBuiltin()`，
   于是根本不需要那个原生插件。它依赖 Node 自带的 `--expose-internals`，
   由启动器负责传入。
2. `install.sh` 用 `--ignore-scripts` 安装 dsh，给 `pty.cc` 补一小段 FreeBSD
   分支（改用 `closefrom(3)`），再从源码编译 `node-pty`。
3. `patch-flock.mjs` 用系统 `cc` 把 `src/flock.c` 编译成
   `node-addon-system/bin/system.node`，并在上游 `lib/flock.js` 里补一个
   `freebsd` 分支（上游只认 darwin/linux）。这一步不是可选项：少了它 dsh
   能启动，但**任何会话都写不进去**。
4. 生成的启动器等价于：

   ```sh
   node --expose-internals --require <root>/shim.js \
        <root>/app/node_modules/@deepseek-ai/dsh/lib/bin.js "$@"
   ```

请始终通过这个启动器（`dsh web`）启动。`npx @deepseek-ai/dsh` 和直接
`node .../bin.js` 在这里不可能工作 —— 没有 `--expose-internals`，shim 会
拒绝交出内部模块。

## 在目标机上安装

```sh
tar xzf dsh-freebsd-0.2.1-rc.2-amd64.tar.gz
cd dsh-freebsd
sh install.sh
```

要求：FreeBSD、Node >= 20 + npm、能访问 npm registry，外加一个 C 编译器
（`cc`/`clang`）和 node headers —— session 持久化要用的 flock 绑定就是用它
现编的，node headers 跟 `pkg install node` 一起来。终端功能额外需要
`make` / `python3` / `node-gyp`；这几个缺了只会让终端面板不可用，dsh 本身照常
运行（也可以显式传 `--skip-pty` 跳过编译）。

装完直接启动：

```sh
dsh web                 # 或 ~/.local/share/dsh-freebsd/dsh web
```

`install.sh` 参数：

| 参数 | 含义 |
| --- | --- |
| `--version <ver>` | 要安装的 dsh 版本（默认 `0.2.1-rc.2`） |
| `--root <dir>` | 安装目录（默认 `~/.local/share/dsh-freebsd`） |
| `--bin-dir <dir>` | 启动器软链接位置（默认 `~/.local/bin`） |
| `--no-config` | 不动 `~/.dsh` |
| `--force-config` | 覆盖已存在的 `~/.dsh` profile 文件 |
| `--no-link` | 不创建 `~/.local/bin/dsh` |
| `--skip-pty` | 跳过 node-pty 编译 |
| `-h, --help` | 显示帮助 |

## 配置

`apply-config.sh` 会把 `web` profile 写进 `~/.dsh/profiles/web`：
`package.json`、`cordis.yml`、`cordis.patch.yml`、`pnpm-workspace.yaml`。
已存在的文件默认保留，重复执行是安全的。只想同步配置时单独运行：

```sh
sh apply-config.sh            # 保留已有文件
sh apply-config.sh --force    # 覆盖已有文件
```

**刻意不打包的东西**：

- `~/.dsh/.credentials.yaml` —— 里面有浏览器会话 secret。目标机首次
  `dsh web` 会自己生成，需要在新机器上重新授权/登录。
- `~/.dsh/storages/` —— 旧机器的会话与工作区状态。
- `~/.dsh/profiles/node_modules` —— 上游会把它填成指向旧机器 npx 缓存的
  绝对符号链接，跨机器必然失效；dsh 首次启动会自己重建所需部分。

## 升级

```sh
sh install.sh --version 0.2.2-alpha.2
```

shim 是由启动器注入的，升级不需要重新打补丁；本脚本会重新编译 `node-pty`。

## 故障排查

| 现象 | 原因 / 处理 |
| --- | --- |
| `No usable native binding found ...` | 没走 shim 启动（比如用了 `npx`）。改用生成的 `dsh` 启动器。 |
| `unknown builtin module: internal/modules/...` | Node 大版本升级后内部模块结构变了，需要更新 `shim.js`。 |
| `flock is not supported on freebsd-x64` | flock 绑定没编出来。装好 `cc` 与 node headers（`pkg install node`）后重跑 `sh install.sh`，或单独跑 `node patch-flock.mjs <root>/app`。 |
| 会话创建/写入失败、报 `SessionAlreadyOwned` | 上一次会话的 `session.lock` 被遗留进程占着；结束那个 dsh 进程即可（锁在进程退出时释放）。 |
| 终端面板打不开 | `node-pty` 没编译成功。装好 `cc`/`make`/`python3` 后重跑 `sh install.sh`。 |
| `npm install failed` | 网络或 registry 不通。本包是联网安装，不含离线依赖包。 |
| `~/.local/bin is not in PATH` | 把该目录加进 PATH，或直接用 `<root>/dsh web`。 |

注意：`--expose-internals` 会把 Node 内部模块暴露给整个进程（包括 dsh 加载
的插件）。单人工作站没问题；多用户共享机器上请自行评估。
