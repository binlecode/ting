# PLAN-session-reconnect —— TUI 启动自动探测并接管后台活动播放器

> **Status**: 草案 (Draft) · 架构方案与实施规约就绪，待审阅确认  
> **Priority**: P1（人机交互状态接管核心闭环）  
> **Target Branch**: main  
> **Roadmap 关联**: [`docs/ROADMAP.md`](ROADMAP.md)「还没做的事」——【高 ROI】TUI 启动自动探测并接管后台活动播放器（Session Reconnect）  
> **Governing Docs**: [`docs/ARCH-player.md`](ARCH-player.md)「运行时 IPC」「状态机」、[`docs/ARCH-cli-contract.md`](ARCH-cli-contract.md)「数据契约」「命令规格」、[`docs/ARCH-tui.md`](ARCH-tui.md)「唯一视图的渲染」  
> **Verification**: `tests/contract.sh`（CLI 契约与门禁）、`tests/playback.sh`（detached 生命周期）、`tests/drive.sh`（tmux 交互与横幅渲染）  
> **Grounding**: 本文标「实测」项均基于 2026-09 当前代码库与真实 detached 播放器运行输出。

---

## 1. 现状痛点与架构断层审计 (Problem Audit & Grounding)

### 1.1 核心痛点：状态断层、扬声器打架与幽灵进程
本套件宣称并贯彻“播放脱离终端（Detached Playback）”理念（`ARCH-player.md`），即通过 `ut-play -d` 启动的后台播放或在 TUI 内点播的曲目均作为独立后台进程脱离终端存活。但在人机界面（TUI）侧存在严重的状态接管断层：

1. **盲目置空状态**：
   在 `shell/uting:2127-2132`，TUI 启动时无条件将 `CURRENT_PLAY_ID=""`、`CURRENT_PLAY_SOCK=""` 等置空；
2. **无法感知与控制在播媒体**：
   若后台已有 `ut-play -d` 正在播放，再次打开 `uting` 时，顶部 Now-Playing 横幅盲目显示为空，按 `Space`（暂停/恢复）、`s`（停止）、`[` / `]`（快进/快退）均因为 `[[ -n "$CURRENT_PLAY_ID" ]]` 门控而判定为静默空操作；
3. **恶性冲突（扬声器打架）**：
   用户在 TUI 列表中选择任一歌曲按 `Enter` 时，`play_selected` 试图执行 `stop_current_playback`。但由于 `CURRENT_PLAY_ID` 为空，老播放器**完全不会被停止**。结果是：并发启动第二个 mpv 实例，两首曲目在扬声器中重叠播放，老播放器彻底沦为无法在 TUI 内部触达和停止的“幽灵进程”。

### 1.2 契约缺口：`ut-play --status -j` 漏投 `sock` 字段
经排查 `shell/ut-play:1941`，当 detached 播放器启动时，落盘的 `$PLAYERS_DIR/$id.json` 文件中**明确持久化了 `sock` 和 `log` 路径**：
```bash
'{id: $id, pid: $pid, url: $url, engine: $engine, mode: $mode, format: null,
  selected: null, selected_resolution: null, started_at: $started_at, log: $log,
  sock: $sock, title: null, volume: $volume, loop: $loop}' >"$sf.tmp.$pid"
```
且在 `ut-play -d -j` 的 launch 信封（行 1962）中公开暴露了 `sock` 与 `log`。其架构理由在行 1956 注释中阐述得非常透彻：
> *"sock/log are part of the envelope so a caller never has to RECONSTRUCT them from the state-dir layout (uting used to hardcode $TMPDIR/uting-$(id -u)/mpv-$id.sock, duplicating a private path in a second script). ARCH-player.md「运行时 IPC」."*

**但是**，在 `shell/ut-play:2160` 的 `do_status`（即 `--status -j` 响应）中，构造 `players[]` 数组时却将 `sock` 与 `log` 漏掉了：
```bash
parts+=("$(jq -c \
    --argjson live "${LP_VOLUME:-null}" \
    --argjson paused "${LP_PAUSED:-null}" \
    --argjson position "${LP_POSITION:-null}" \
    --argjson duration "${LP_DURATION:-null}" \
    --argjson media "$LP_MEDIA_JSON" \
    --argjson queue "$QUEUE_JSON" \
    '{id, pid, url, engine, mode, volume: ($live // .volume),
      paused: $paused, position: $position, duration: $duration,
      title, selected, selected_resolution, media: $media,
      loop: (.loop // "off"), started_at, queue: $queue}' \
    "${LIVE_PLAYER_FILES[$i]}")")
```
导致外部客户端及重新启动的 `uting` 在轮询 `--status -j` 时，虽能知晓活动播放器的 `id`、`pid`、`url`、`title`，却拿不到控制该播放器所需的 `sock` 路径，直接卡死了 TUI 接管的能力。

---

## 2. 核心设计规约与边界裁决 (Decisions & Invariants)

### 2.1 契约补齐：`ut-play --status -j` 投影补充 `sock` 与 `log`
- **决定**：在 `shell/ut-play:2160` 的 `players[]` 输出对象中，将状态文件原生已有的 `sock` 与 `log` 字段一并投影暴露：
  ```json
  {
    "id": "rddFsB",
    "pid": 12225,
    "url": "https://...",
    "sock": "/tmp/uting-501/mpv-rddFsB.sock",
    "log": "/tmp/uting-501/rddFsB.log",
    ...
  }
  ```
- **契约兼容性论据**：
  1. `ut-play -d -j` 启动信封早已将 `sock` 与 `log` 作为公共信封字段公布；
  2. 磁盘持久化 JSON 文件原本就存储了这两个键，补齐投影属数据契约补全（加宽），对现有消费方（只读取 `id`/`title`/`volume` 等）无任何破坏性破坏；
  3. `tests/contract.sh` 对 `--status` 的断言仅检查列表结构与整体有效性，不会因为补充这两个字段导致任何用例飘红；
  4. 彻底杜绝了 `uting` 内部私自硬编码拼接 socket 路径的违规行为，坚守 `ARCH-player.md`「运行时 IPC」的无重复声明原则。

### 2.2 接管门控与裁决准则 (Target Resolution Policy)
TUI 启动接管严格对齐 `shell/ut-play:2000` `resolve_target` 的既有权威逻辑：
- **场景 A：0 个活动播放器（`players | length == 0`）**：
  正常初始化，`CURRENT_PLAY_ID=""`，界面无 Now-Playing 横幅；
- **场景 B：恰好 1 个活动播放器（`players | length == 1`，常规高频场景）**：
  **全自动无感接管**。将该唯一播放器的元数据与 Socket 完整绑定进 `uting` 全局变量，第一帧立即绘制活动横幅；
- **场景 C：2 个及以上活动播放器（`players | length >= 2`，多实例并发）**：
  **不盲目猜测**。由于无法确定用户意图，保持 `CURRENT_PLAY_ID=""`，不在横幅盲目挂接任一实例；同时在状态行/notice 区机会性提示 `Multiple players running (use ut-play --status)`，引导用户或等待用户显式点播覆盖。

### 2.3 状态恢复与首帧渲染联动
接管唯一播放器后，需保证 TUI 的内部状态机与后台 mpv 保持严格同步：
1. **基础元数据恢复**：
   - `CURRENT_PLAY_ID="$id"`
   - `CURRENT_PLAY_PID="$pid"`
   - `CURRENT_PLAY_SOCK="$sock"`
   - `CURRENT_PLAY_URL="$url"`
   - `CURRENT_PLAY_ENGINE="$engine"`
   - `CURRENT_PLAY_TITLE="$title"`（若为 null，则回退至 URL 或短标题）
   - `CURRENT_PLAY_DURATION="$duration"`（由秒数转换为 `fmt_sec`）
   - `CURRENT_PLAY_PAUSED=$paused`（1 或 0）
   - `CURRENT_PLAY_LOADING=0`
2. **IPC 实时属性同步**：
   - 检查 `$CURRENT_PLAY_SOCK` 文件描述符是否真实可用；
   - 若可用，启动时单次调用 `fetch_play_times` 获取最新的 `PT_CUR`（已播时间）与 `PT_POS_SEC`，并置 `CURRENT_PLAY_STARTED` 为合理估算值（当前时间减去已播秒数），使第一帧重绘时即能准确渲染进度条轨道的游标点；
3. **列表行匹配与高亮（Track Locator）**：
   - 若用户启动时携带的查询或默认列表恰好包含了正在播放的 `CURRENT_PLAY_URL`，TUI 自动在列表中将该曲目标注为当前在播状态（行首播放图标或活动底色），人机视觉完美对齐。

### 2.4 退出行为边界处理 (Exit Intent)
- **现状保留**：当前 `shell/uting:3822` 在 `cleanup_on_exit` 中执行 `stop_current_playback`。
- **接管实例的退出策略**：
  - 若用户进入 TUI 并主动按 `s` 或 Enter 换歌，正常调度停止；
  - 针对 `q` 退出：保持当前套件的一贯行为（退出即清理当前会话绑定的播放器）。关于“`q` 脱离退出 vs `Q` 强杀退出”的更宽议题，继续交由 ROADMAP「还没定的事」统一裁决，本 PLAN 不单侧引入新按键或修改退出全局契约。

---

## 3. 详细实施规格 (Implementation Spec)

### 3.1 `shell/ut-play` 改动
在 `do_status()` 的 JSON 投影处（行 2160 附近），将 `sock` 与 `log` 加入投影对象：

```bash
# 修改前：
'{id, pid, url, engine, mode, volume: ($live // .volume),
  paused: $paused, position: $position, duration: $duration,
  title, selected, selected_resolution, media: $media,
  loop: (.loop // "off"), started_at, queue: $queue}'

# 修改后：
'{id, pid, url, engine, mode, volume: ($live // .volume),
  paused: $paused, position: $position, duration: $duration,
  title, selected, selected_resolution, media: $media,
  loop: (.loop // "off"), started_at, queue: $queue,
  sock, log}'
```

### 3.2 `shell/uting` 改动
在 `shell/uting` 中新增 `probe_active_player()` 函数，并在首帧绘制前（`while true; do` 循环之前）调用：

```bash
probe_active_player() {
    [[ -x "$PLAY_BIN" ]] || return 0
    local out cnt line
    out=$("$PLAY_BIN" --status -j 2>/dev/null) || return 0
    cnt=$(printf '%s' "$out" | jq -r '.players | length' 2>/dev/null || echo 0)
    
    # 仅当恰好存在 1 个活动播放器时自动接管
    if ((cnt != 1)); then
        if ((cnt > 1)); then
            store_notice "$S_STATUS:" "multiple background players active"
        fi
        return 0
    fi

    # 提取首个播放器的全部结构化数据
    local id pid sock url engine title dur paused pos
    IFS="$US" read -r id pid sock url engine title dur paused pos < <(
        printf '%s' "$out" | jq -r '
            .players[0] as $p |
            [
              ($p.id // ""),
              ($p.pid | tostring // ""),
              ($p.sock // ""),
              ($p.url // ""),
              ($p.engine // ""),
              ($p.title // ""),
              ($p.duration | tostring // ""),
              (if $p.paused then "1" else "0" end),
              ($p.position | tostring // "")
            ] | join("\u001f")
        ' 2>/dev/null
    ) || return 0

    [[ -n "$id" && -n "$sock" && -S "$sock" ]] || return 0

    CURRENT_PLAY_ID="$id"
    CURRENT_PLAY_PID="$pid"
    CURRENT_PLAY_SOCK="$sock"
    CURRENT_PLAY_URL="$url"
    CURRENT_PLAY_ENGINE="${engine:-$ENGINE}"
    CURRENT_PLAY_TITLE="${title:-$url}"
    if [[ -n "$dur" && "$dur" != "null" && "$dur" != "" ]]; then
        CURRENT_PLAY_DURATION=$(fmt_sec "$dur")
    else
        CURRENT_PLAY_DURATION=""
    fi
    CURRENT_PLAY_PAUSED="$paused"
    CURRENT_PLAY_LOADING=0

    # 同步起播与进度时间基准
    local now
    now=$(date +%s 2>/dev/null || echo 0)
    if [[ -n "$pos" && "$pos" != "null" && "$pos" =~ ^[0-9]+ ]]; then
        CURRENT_PLAY_STARTED=$((now - pos))
    else
        CURRENT_PLAY_STARTED=$now
    fi

    # 预刷新一次播放时间
    fetch_play_times
}
```

在启动流调用：
```bash
# 在 apply_search_results 之后、进入 while true 菜单循环之前执行
probe_active_player
```

---

## 4. 验证矩阵与回归判据 (Verification Matrix)

### 4.1 离线与静态检查
- `bash -n shell/*` 语法检查全绿；
- `tests/contract.sh --offline` 288 项离线门禁全绿，确保 `--status -j` 新增字段未破坏现有断言。

### 4.2 端到端生命周期接管测试（自动化验证脚本）
在测试脚本中模拟完整闭环：
1. 启动 detached 播放器：
   `out=$(shell/ut-play -d -j --engine yt -- "https://www.youtube.com/watch?v=dQw4w9WgXcQ")`
   断言启动成功，记录 `id` 与 `pid`；
2. 运行 `shell/ut-play --status -j`：
   断言返回的 `players[0]` 中包含有效的 `.sock` 且指向可用的 UNIX Socket 文件；
3. 通过 `tests/drive.sh` 启动 TUI：
   验证终端抓取的首帧文本中**直接出现了该曲目的 Now-Playing 横幅**；
4. 在 TUI 中发送 `Space` 键：
   验证后台播放器的暂停状态被成功切换；
5. 在 TUI 中选曲按 `Enter` 换歌：
   验证老播放器进程被正常杀除，新播放器接管，**不存在两个 mpv 进程并发竞争扬声器**；
6. 测试完成，自动清理测试环境。

---

## 5. 落地后同步的文档与版本

1. `docs/ARCH-player.md`「运行时 IPC」与「状态机」：
   - 补充说明 `--status -j` 携带 `sock` 与 `log` 字段，作为与 `-d -j` 对齐的外部 IPC 发现契约；
2. `docs/ARCH-cli-contract.md`「数据契约」：
   - 在 `--status` 信封说明中补充 `sock` 与 `log` 键；
3. `docs/ROADMAP.md`：
   - 勾除并删除「【高 ROI】TUI 启动自动探测并接管后台活动播放器（Session Reconnect）」条目；
4. **清理计划**：
   - 本特性代码落地并通过全部测试后，将核心架构论证蒸馏入 `ARCH-player.md` 与 `ARCH-tui.md`，当场执行 `git rm docs/PLAN-session-reconnect.md`。
