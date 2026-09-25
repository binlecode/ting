# PLAN — TUI 改用 Go，CLI 契约成为唯一接缝

> **Status**: 草案 (Draft) · 三项决定已确认（2026-09-24），其余在「未决」  
> **Priority**: 第一梯队  
> **Target Branch**: main  
> **Roadmap 关联**: [`docs/ROADMAP.md`](ROADMAP.md)「Go 重写 NO」（TUI 一半已由本计划反转）  
> **Governing Docs**: [`docs/ARCHITECTURE.md`](ARCHITECTURE.md)「分析：驱动决定的六条发现」、[`docs/ARCH-cli-contract.md`](ARCH-cli-contract.md)「`ting` —— 交互式终端 UI」、[`docs/ARCH-player.md`](ARCH-player.md)「运行时 IPC 控制」、[`docs/ARCH-tui.md`](ARCH-tui.md)  
> **Verification**: `bash -n shell/*`、`tests/contract.sh --offline`、`tests/contract.sh`、`tests/playback.sh`、`go test ./...`、tmux 驱动段  
> **Scope Boundary**: 只换人机那张脸。引擎对（`*-search` / `*-resolve`）、播放器 `t-play`、两个存储（`t-playlist` / `t-history`）留在 shell、bash 3.2、零新增运行时依赖，既有 argv、信封字段、reason 与退出码一字不改。契约只**加**两样东西（`t-play --watch`、`--capabilities -j`），各自是一次 minor。

---

## 1. 为什么现在做，以及它不是什么

定位变了：人机那张脸要的呼吸感（亚秒时钟、插值动效、差量渲染、真正的事件循环）是
bash 3.2 给不了的——`read -t` 只收整数秒，tty VTIME 能到 100 ms 但每拍要 fork，
`ARCH-tui.md` 已把这笔账记全。「六条发现」第 1 条早就承认：`ting` 的大头是在手工重做
Go TUI 栈免费给的东西，重写会**删掉**这份负债而不是搬迁它。当时拒绝的理由是"只有内部收益"；
现在内部收益（能做出那张脸）本身就是目标，所以 TUI 这一半反转。

**不是**全套重写。第 2、5、6 条对引擎与播放器一条未动：站点知识要原地可改，
yt-dlp/mpv 在任何语言里都是子进程，生命周期的回归无法二分。所以 Go 那一侧永远只是
**这套 CLI 的又一个调用方**，与 agent 平级。

---

## 2. 切分原则：TUI 能碰的只有 argv 与信封

```
  +-----------------------+        +-----------------------+
  |  agent (Claude Code)  |        |  ting (Go, Bubbletea) |
  +-----------+-----------+        +-----------+-----------+
              |   argv + -j envelope + exit code   |
              |   t-play --watch -j (NDJSON)       |
              +-----------------+------------------+
                                v
  +----------------------------------------------------------+
  |  t-play | <engine>-search | <engine>-resolve             |
  |  t-playlist | t-history          (shell, bash 3.2)       |
  +----------------------------+-----------------------------+
                               v
                  mpv socket / yt-dlp / curl   (private)
```

一条判据：**Go 二进制里出现 mpv、yt-dlp、socket 路径或站点名，就是一次分层违规。**
一件只有 TUI 能做的事，要么下沉成一个动词（agent 同时得到它），要么不做。
`CLAUDE.md`「严禁单侧新增 TUI 键位」保持原样，而且从此有了机械的检验方式。

---

## 3. 今天的 bash TUI 在哪里绕过了契约（实测清单）

这些是切分必须关掉的洞；每一条都给出去向。

| 现状（`shell/ting`） | 为什么当初这样 | 去向 |
|---|---|---|
| `fetch_play_times` 每拍在 `--status` 公布的 `sock` 上直读 14 个 mpv 属性 | 每拍 fork 一条 `t-play` 太贵 | `t-play --watch`（§4.1） |
| `mpv_get_prop core-idle` 判断起播就绪 | 同上 | `--watch` 的状态事件 |
| `-`/`=` 音量走 `send_mpv_ipc`，先 `get_property volume` 再 set | 按住连发：socket 10 ms/次，`--set-volume` 60 ms/次 | Go 端合并连按（只保留最新目标值、同一时刻最多一个在途调用），走 `--set-volume`；当前音量来自 `--watch` |
| 封面：TUI 自己起一个 `mpv --vo=image` 做转码 | bash 解不了图 | Go 用标准库解码搜索信封里的 `thumbnail`，自己发 Kitty 协议；mpv 从 TUI 里消失 |
| `--parts` / `--info` 支不支持，靠调一次、嗅 stderr 的用法错 | 没有发现动词 | `<engine>-resolve --capabilities -j`（§4.2） |
| 引擎发现：本目录 → `UT_ENGINE_DIR` → PATH 三处扫描，与 `t-play` 各写一份 | — | Go 实现同一条规则（规则正本在 `ARCH-cli-contract.md`「加一个引擎」）；见「未决」 |

**已经干净、原样沿用的**：起播/停止/暂停/seek/循环/队列八个动词、`--undo --owner PID`
（Go 进程传自己的 PID）、`--status` 接管已在跑的播放器、`t-playlist` / `t-history` 全部动词。

---

## 4. 契约增量

### 4.1 `t-play --watch [--id ID] -j` —— 播放器状态的事件流

- **形状**：stdout 每行一个信封（NDJSON），首行是一份完整快照，之后只在变化时出行。
  字段用播放器自己的词（与 `--status` 的 `media` 同源），**不**透传 mpv 属性名 ——
  mpv 仍是私有的，换掉它不应改变这份输出。
- **实现可行性（已实测）**：macOS 自带 `/usr/bin/nc -U` 保持一条长连接，对 mpv 发
  `observe_property` 后，另一个客户端改 volume / pause 时，`property-change` 事件被实时推到
  这条连接上。前提是 nc 的 stdin 一直不关——`--watch` 必须自己持有那个 fd。
  这意味着 bash 端零 fork/拍，时钟精度由 mpv 决定，不再是 1 Hz。
- **跨曲目**：队列每首是一个新的 mpv 进程，socket 连接会断；`--watch` 负责重连，
  并发一个换曲事件，调用方看到的是一条连续的流。
- **结束**：播放器消失时发最后一行并退出；退出码按四级分类（未决：正常结束报 0，
  `--id` 不存在报 4）。
- **agent 同样受益**：`ARCHITECTURE.md`「六条发现」第 4 条列过"流式进度"为 bash 给不了的诉求——
  它给得了，只是当时没有人要。

### 4.2 `<engine>-search` / `<engine>-resolve --capabilities -j`

一次调用答出这个引擎半边支持的动词与选项（`--parts`、`--info`、`--transcript`、
`--items`……），替代嗅探 stderr。三个内置引擎都加；`ARCH-cli-contract.md`
「加一个引擎 —— 清单」把它列为必备项，仓外引擎缺它时调用方按"只有最小集"处理。

两项增量各自先落地、各自 bump（版本独占一次 commit），且都在 Go 代码写第一行之前完成。

---

## 5. Go 一侧

- **位置**：同仓，`go.mod` 在根，入口 `cmd/ting/`。bash 3.2 与"零新增运行时依赖"两条红线
  继续只管 `shell/`；Go 二进制本身不是运行时依赖，Go 工具链是**构建**依赖
  （tap formula 用 `depends_on "go" => :build` 或发布 bottle，见「未决」）。
- **栈**：Bubbletea（事件循环、resize）、Lipgloss（样式）、`go-runewidth`/`uniseg`（显示宽度，
  取代 `disp_w` 的 EAW 表）、`harmonica`（弹簧动效，可选）。
- **一个 `verb` 包**：唯一执行子进程的地方。拼 argv、解信封、把退出码映射成类型化错误；
  所有键处理器只调它。它同时是"Go 里不许出现 mpv"那条判据的落点。
- **配置面**：Go 实现同一条继承链（flag > `TING_*` > `UT_*` > 用户配置 > 出厂配置）与
  11 个偏好键的原地写回（保留注释与布局）。文件格式是既有契约，不改。

### 功能对齐清单（切换前必须全部到位）

`ting --help` 键表里的每一个键；TTY 双门；argv 与三类标志的转发；接管已在跑的播放器、
退出时只停本会话起的那个；撤销的 3 秒窗口；`b`/`h`/`c`/`i` 四种临时行源；`/` 过滤；
`Nj` 跳行；滚动/分页两种列表模式；中英 chrome；13 套主题与 truecolor/ANSI-16 回退、
ASCII 模式、亮暗背景探测；同步重绘（今天是 DCS `1q/2q`，tmux 下关）；封面（tmux 下关）。

---

## 6. 实施顺序

1. **`--watch`**（shell）：实现 + `tests/playback.sh` 里的真实播放器用例（改音量、暂停、
   跨曲目、播放器死亡，全部轮询真实事件，不 sleep）。bump。
2. **`--capabilities -j`**（shell）：三个引擎 + 契约段的跨引擎门。bump。
3. **Go 骨架**：`verb` 包、`--watch` 消费、配置链，先能搜、能播、能停。
4. **对齐**：按 §5 清单逐项。
5. **测试迁移**：`tests/contract.sh` 的 tmux 段与 `tests/drive.sh` 改为驱动 Go 二进制；
   断言针对行为与帧结构，不针对 bash 实现细节。
6. **一次切换**（已确认：不并行运行）：同一个 commit 里 Go 接过 `ting` 这个名字、
   `git rm shell/ting`、更新 tap formula；`--offline` 与全量契约全绿才合入。
7. **蒸馏**：重写 `ARCH-tui.md`；改 `ARCHITECTURE.md` 定位一节与「六条发现」、
   `ARCH-cli-contract.md` 的 `ting` 一节、`CLAUDE.md`（"10 个脚本"、常用命令、`bash -n` 门禁），
   然后 `git rm` 本文件。

---

## 7. 未决

- `--watch` 的事件字段清单与结束退出码。
- `--watch` 的 `--id` 缺省：像其他 socket 动词一样"唯一那个"，还是允许不带 id 时观察全部播放器。
- 引擎发现：Go 复刻三处扫描，还是再加一个列出已装引擎的动词，让规则只在 shell 里写一次。
- 分发：tap 从源码编译还是发 bottle；Go 二进制怎样找到旁边的 shell 动词（同目录 / `libexec`）。
- 封面格式：`thumbnail` 若是 webp，需要 `golang.org/x/image/webp`（构建依赖）。
- 一次切换意味着对齐期间 main 上没有可用的新 TUI：开发在分支上进行，还是 Go 代码先合入但不接名字。
