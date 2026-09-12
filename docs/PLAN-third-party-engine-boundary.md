# PLAN — 第三方引擎边界架构裁决与生态接入规约

> **Status**: 草案 (Draft) · 架构裁决与实施规约就绪，待审阅确认  
> **Priority**: P0（极高 ROI，决定主套件代码库维护半径与音源生态扩展模式）  
> **Target Branch**: main  
> **Roadmap 关联**: [`docs/ROADMAP.md`](ROADMAP.md)「待办与待决事项」——【极高 ROI · 待决】第三方引擎边界  
> **Governing Docs**: [`docs/ARCH-cli-contract.md`](ARCH-cli-contract.md)「加一个引擎 —— 清单」、[`docs/ARCH-engine.md`](ARCH-engine.md)「模块功能和结构」、[`docs/ARCHITECTURE.md`](ARCHITECTURE.md)「站点知识的边界」「平级动词，没有内核」  
> **Verification**: `tests/contract.sh --offline`、引擎动态发现扫描测试、`bash -n shell/*`  
> **Scope Boundary**: 规范内置引擎（Tier 1）与外部独立引擎（Tier 2）的架构分层、治理准则、发现机制（`$UT_ENGINE_DIR`）与契约合规验证器。不在此 plan 中引入具体站点的业务解析逻辑。

---

## 1. 量到的事实（2026-09-12 源码核查与实测）

本节所有数据均通过源码实现通读、真实进程查找与历史提交分析获得，严禁凭空推演。

| # | 事实 | 测量方式与源码位置 | 架构影响 |
|---|---|---|---|
| 1 | **`uting` 引擎发现存在"全有全无短路"缺陷** | `shell/uting:372-381` 逻辑为：`scan_engines "$SCRIPT_DIR"` 后，紧跟 `if ((${#ENGINES[@]} == 0)); then ... scan PATH` | 只要 `$SCRIPT_DIR` 存在内置引擎（如 `yt/bili/ne`），`$PATH` 上的任何第三方引擎**永远不会被扫描并追加进 `ENGINES` 数组**，导致 TUI 无法通过 `e` 键轮换外部引擎 |
| 2 | **`ut-play` 与 `uting` 的解析定位存在链式不对称** | `shell/ut-play:477-483` 先查 `$SCRIPT_DIR/$ENGINE-resolve` 再查 `command -v`；但 `uting` 发现依赖步骤 1 的全量扫描 | CLI 具备单点调用外部引擎能力（`ut-play --engine foo ...` 可跑），但 TUI 发现面直接失效，破坏"两面 100% 对等"的核心契约 |
| 3 | **套件缺少合法的外部插件安置路径** | 检查全局配置与常量：仅有 `$TMPDIR/uting-<uid>`、`$UT_STATE_DIR`（默认 `~/.local/state/uting/`）与 `$UT_CONFIG` | 外部引擎若想被 `$SCRIPT_DIR` 发现，必须向源码树 `shell/` 软链或写入文件，直接踩中 `CLAUDE.md`「严禁向源码树写脏文件」红线 |
| 4 | **外部站点维护变更具有高频与突发性** | 检索 Git Log：网易云明文 API 撤下导致引入 `openssl` 独立加解密；B 站 `buvid` 指纹缺失致 412 与 WAF 风控；`yt-dlp` 每月均有提取器修正 | 外部站点是本仓唯一会因网络与反爬变动而破损的代码（`ARCHITECTURE.md`「平级动词」）。全量进仓将使主仓发版周期被站点风控反爬严重绑架 |
| 5 | **`tests/contract.sh` 天然具备自适应引擎探测能力** | `tests/contract.sh:426-512` 通过循环遍历 `discover_engines`，对被发现的每一个引擎强制断言通用不变量（Usage 退出码 1、host 门控、`--auth` 决策、时长整形等） | 契约测试已具备作为“独立外部引擎合规检验器”的技术基础，无需重写校验逻辑 |

---

## 2. 架构决定 (Decisions)

### D1 — 确立「双轨制」分层边界：内置核心引擎 (Tier 1) vs 外部生态引擎 (Tier 2)

- **决定**：主仓坚守“小内核、高稳定”底线，不走“全量大一统打包（Monorepo）”路线，也不走“主程序零内置音源的激进微内核（如 MusicFree）”路线，而是建立明确的 **Tier 1 / Tier 2 双轨准入与维护标准**：
  * **Tier 1（内置核心引擎 / In-Repo Core）**：
    * **入选标准**：严格满足 5 大第一性原理准入判据（双半边完备、零新增全局依赖、纯 bash 3.2、mpv 原生直链、免登录弱风控开箱可用）；服务于全球/国内基石级流媒体生态（当前为 `yt`、`bili`、`ne`；候选为 `sc`、`pod`）；
    * **维护权责**：代码常驻主仓 `shell/` 目录，享受 SemVer 严格版本管理，每次提交受 `tests/contract.sh` 与 `tests/playback.sh` 全量回归门禁守卫。
  * **Tier 2（外部生态引擎 / Out-of-Tree Ecosystem）**：
    * **适用范围**：依赖用户自备账号/高风控登录态、逆向加密算法演化频繁（如需要本地二次解密的流）、特定小众垂直领域、或存在潜在版权争议的音源站点；
    * **维护模式**：社区与第三方独立建仓（标准命名规范 `uting-engine-<name>`），独立负责 issue 响应与版本演进；
    * **隔离边界**：第三方引擎的破损、反爬对抗或弃更，**绝对不触发本套件主仓的发版与回归失败**。
- **被否方案 A：全部音源无条件收录进主仓**。  
  *理由*：违反 `ARCHITECTURE.md`「站点知识的边界」。国内与海外中小平台接口半衰期极短，频繁的代码修补与回归红灯会迅速稀释核心 CLI 契约的稳定性。
- **被否方案 B：主仓剥离所有音源，转为纯空壳播放器**。  
  *理由*：破坏终端用户开箱即用体验。用户安装 `uting` 的第一性诉求是“工作时能直接听音乐”，必须保持主流通用源零配置直开。

### D2 — 修复发现逻辑，规范三级引擎查找链（引入 `$UT_ENGINE_DIR`）

- **决定**：彻底修复 `shell/uting` 的排他短路，建立统一、去重、确定性的 **三级引擎查找与加载链**：
  $$\text{查找优先级: } \text{Sibling (\$SCRIPT\_DIR)} \longrightarrow \text{User Plugin (\$UT\_ENGINE\_DIR)} \longrightarrow \text{System PATH (\$PATH)}$$
  1. **Tier 1 兄弟目录**：`$SCRIPT_DIR`（源码内建引擎，优先保证内置原装）；
  2. **Tier 2 用户扩展目录**：`$UT_ENGINE_DIR`（默认配置为 `~/.local/share/uting/engines/`，支持用户通过环境变量重定向）；
  3. **Tier 2 全局环境**：`$PATH`（支持通过 Homebrew tap 或系统包管理器分发的全局可执行文件）。
- **发现规则**：
  * 引擎必须成对出现：目录或 PATH 下必须同时具备同名的 `<name>-search` 与 `<name>-resolve`，且两者均具备可执行权限（`[[ -x ]]`）；
  * 发现过程通过 `engine_seen` 严格去重，高优先级目录覆盖低优先级同名引擎（允许用户在 `$UT_ENGINE_DIR` 下放置修复版的同名引擎覆盖内置版本）。

### D3 — 交付官方契约检验门禁工具：`tests/contract.sh --engine-only <name>`

- **决定**：扩展主仓的 `tests/contract.sh` 脚本，新增独立质检子动词：
  ```sh
  tests/contract.sh --engine-only <engine-name>
  ```
- **职责**：
  * 针对指定的外部或本地引擎执行 40+ 项不变量探测，验证其是否百分之百符合 `ARCH-cli-contract.md` 的四级退出码模型、单行 JSON envelope、`-V` 门禁、`--auth` 决策信封及错误 reason 枚举；
  * 提供面向第三方作者的 GitHub Action 模板，使外部独立引擎仓能在 CI 中无损复用主套件的契约测试。

### D4 — 严格继承资源与命名空间隔离契约

依据 `CLAUDE.md` 与 `ARCH-player.md`，外部引擎必须严格遵循以下系统隔离原则：
- **临时文件**：运行时必须将临时文件收敛于 `"${TMPDIR:-/tmp}/uting-<uid>/engine-<name>.$$/"`，进程退出时自清理，严禁向源码树或主状态目录写入脏临时文件；
- **配置命名空间**：外部引擎配置项必须严格采用 `<ENGINE_NAME>_*` 大写前缀（如 `SC_COOKIE_BROWSER`），严禁侵入 `UT_*` 命名空间。

---

## 3. 规约与接口标准 (Specification)

### 3.1 引擎目录拓扑与加载规范

```
$HOME/.local/share/uting/engines/          ← $UT_ENGINE_DIR（默认插件目录）
├── sc-search                             ← 可执行文件（符合 <name>-search 契约）
├── sc-resolve                            ← 可执行文件（符合 <name>-resolve 契约）
├── pod-search
└── pod-resolve
```

### 3.2 发现算法实现伪码 (Bash 3.2 冻结规范)

```sh
scan_dir_engines() {
    local dir=$1 f name
    [[ -d "$dir" ]] || return 0
    for f in "$dir"/*-search; do
        [[ -x "$f" ]] || continue
        name=${f##*/}
        name=${name%-search}
        [[ -x "$dir/$name-resolve" ]] || continue
        engine_seen "$name" || ENGINES+=("$name")
    done
}

# 链式三级发现（无短路截断）
scan_dir_engines "$SCRIPT_DIR"

UT_ENGINE_DIR="${UT_ENGINE_DIR:-$HOME/.local/share/uting/engines}"
scan_dir_engines "$UT_ENGINE_DIR"

_saved_ifs=$IFS
IFS=:
for _pdir in $PATH; do
    [[ -n "$_pdir" ]] && scan_dir_engines "$_pdir"
done
IFS=$_saved_ifs
unset _saved_ifs _pdir
```

---

## 4. 实施计划与演进里程碑 (Execution Roadmap)

### 阶段一：发现管道修复与 `$UT_ENGINE_DIR` 基础设施落地（主仓）
1. **修改 `shell/uting`**：
   - 重构 `scan_engines` 为追加式链式扫描，引入 `$UT_ENGINE_DIR`，消除当前若 `$SCRIPT_DIR` 有引擎就忽略 PATH 的缺陷；
   - 更新 `engine_search_bin()` 与 `engine_resolve_bin()`，遵循相同的 Sibling $\to$ UT_ENGINE_DIR $\to$ PATH 查找顺序。
2. **修改 `shell/ut-play`**：
   - 同步对齐 `ENGINE_RESOLVE` 的查找逻辑，支持从 `$UT_ENGINE_DIR` 检索解析脚本。
3. **回归测试**：在 `tests/contract.sh` 中新增外部引擎动态挂载测试用例（临时通过隔离目录注入 dummy 引擎验证 TUI 与 CLI 的正确识别）。

### 阶段二：契约校验工具化（`contract.sh --engine-only`）
1. 重构 `tests/contract.sh` 引擎检查部分，使其支持接收独立引擎参数：
   - 提取通用断言集（Usage 校验、白名单防护、信封模式、错误分类）；
   - 允许外部引擎在不依赖全量主套件环境的前提下单点质检。
2. 编写 `docs/ARCH-engine-template.md`，提供纯标准 bash 3.2 的第三方引擎脚手架与 GitHub Actions CI 工作流示例。

### 阶段三：指导第四音源落地验证（PoC 验证）
- 依据 Tier 1 准入标准，将通过实测筛选的最佳候选（SoundCloud）作为范本完成接入与验证；
- 验证外部建仓方案（如小宇宙或自建聚合源）基于 Tier 2 规范的独立运行能力。

---

## 5. 风险登记与控制措施 (Risk & Mitigation)

| 风险 | 等级 | 控制措施 |
|---|---|---|
| **第三方引擎执行恶意代码或未受控行为** | 中 | 本套件不提供特权提权；外部引擎作为普通可执行程序以调用方同一 UID 运行；文档明确提示仅添加可信源 |
| **第三方引擎信封字段漂移导致 TUI 崩溃** | 低 | `uting` 内部渲染已全面收敛于防御性 `jq` 过滤，缺失字段以 `null` 兜底；`contract.sh --engine-only` 提供标准化验证 |
| **多目录同名引擎产生版本冲突** | 低 | 确定性优先级：Sibling 覆盖 User 覆盖 PATH；`uting -V` 或 `--info` 打印解析到的绝对路径便于排查 |
