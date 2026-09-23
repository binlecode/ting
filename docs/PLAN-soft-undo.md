# PLAN — 歌单单曲操作软撤销（Soft Undo）与无阻塞心流交互

> **Status**: 草案 (Draft) · 方案设计完毕，待进入实施  
> **Priority**: 第一梯队 · 最高优先级（TUI 交互与心流美化专项）  
> **Target Branch**: main  
> **Roadmap 关联**: [`docs/ROADMAP.md`](ROADMAP.md)「待办与待决事项」——歌单单曲操作软撤销  
> **Governing Docs**: [`docs/ARCHITECTURE.md`](ARCHITECTURE.md)「定位与设计目标」「设计决定」、[`docs/ARCH-cli-contract.md`](ARCH-cli-contract.md)「接口与 API」「横切规范」、[`docs/ARCH-player.md`](ARCH-player.md)「两个持久存储」、[`docs/ARCH-tui.md`](ARCH-tui.md)「单视图原地重绘」「存储与历史」  
> **Verification**: `/bin/bash -n shell/*`、`tests/contract.sh --offline`、`tests/contract.sh`、`tests/playback.sh`、`tests/drive.sh -x 62 -y 20`  
> **Scope Boundary**: 改造歌单视图内单曲移出（`d`）交互，消灭阻塞式 `confirm_key`（`y/N`）等待与终端滚屏；构建 TUI 进程内存单槽 Undo 缓冲；扩充 `t-playlist --add` 命令行契约以支持可选 `--index N` 原位插入；绑定 `z` 为通用软撤销按键；不改变歌单彻底删除（`D`）或清空待播队列（`X`）等宏观破坏性操作的确认保护；不引入多级无限撤销栈。

---

## 1. 第一性原理与基线现状

### 1.1 心流阻断与伪安全陷阱

在终端人机交互中，**“心流”（Flow State）**的核心特征是：击键即时反馈、零认知停顿、操作具备确定性且可高密度连续进行。

当前 `shell/ting` 中歌单曲目移出（`d` → `delete_from_playlist`，第 6317 行）的执行链路如下：
1. 计算当前行目标并截断标题；
2. 终端向下打印提示行：`移出列表 -> <歌单名>` 以及带缩进的歌曲标题；
3. 调用 `confirm_key "$S_PL_RM_CONFIRM"` 阻塞 `read -rsn1`，等待用户敲击 `y`；
4. 确认后调用 `t-playlist --rm`，最后调用 `reload_playlist` 整页清屏擦除重绘。

**痛点与反模式剖析**：
* **伪安全感与肌肉记忆**：用户连续整理列表删歌时，删除意图高度确定。阻塞式确认不仅未能防范手抖，反而催生了机械式的 `d -> y -> d -> y` 连招。当误触发生时，用户由于惯性早已经把 `y` 敲了下去，确认形同虚设；
* **终端撕裂与视觉噪点**：单视图原生重绘的核心承诺是“无闪烁、不滚屏”。然而 `confirm_key` 在滚动区下方临时打印提示行，破坏了单视图原地重绘的视觉纯粹度；
* **双重击键负债**：1 次业务动作消耗 2 次击键 + 1 次视觉闪烁 + 1 次思维停顿。

### 1.2 现状对照与核心反证：队列 `x` 的先例

在待播队列视图中，单曲移出（`x` → `queue_remove`，第 6902 行）早已实现了**无确认立即移除**，其源码设计注释明确指出：
```bash
# `x` — drop the focused waiting track. No confirmation, unlike `d` on a playlist: a playlist
# is a thing the user built and keeps, a queue is what they are doing right now, and removing
# the wrong one costs a track they can put back with `+`.
```

**第一性原理洞察**：
* 队列之所以能够“零确认”，是因为**用户拥有极低成本的恢复手段（按一次 `+` 即可重新入队）**；
* 歌单此前之所以不得不妥协引入 `(y/N)`，唯一根本原因在于**一旦从磁盘移出，用户无法在 TUI 内以单键原位插回**；
* **结论**：只要为歌单补齐低成本的“原地软撤销（Soft Undo）”，`d` 的 `(y/N)` 阻断便彻底丧失了存在依据。依据人机工程原则：**“用极低成本的可撤销性（Reversibility），彻底取代高摩擦的预防性确认（Defensive Confirmation）”**。

---

## 2. 方案架构与设计决策

```
+-----------------------------------------------------------------------------------------+
|                                    TUI 用户交互面 (ting)                                 |
|                                                                                         |
|  [按 d 移出]                                                [按 z 原地撤销]              |
|       |                                                           |                     |
|       v                                                           v                     |
|  1. 捕获当前行 Payload + Index                             1. 校验 UNDO 缓冲合法性      |
|  2. 写入单槽缓冲 UNDO_BUF                                  2. 提取目标歌单与原 Index    |
|  3. 联动: 若在播则停播                                     3. 调 t-playlist --add      |
|  4. 调 t-playlist --rm --index                                  --index N 恢复曲目     |
|  5. store_notice "已移出 (z撤销)"                           4. 清空 UNDO_BUF             |
|  6. 原地重绘，光标保持槽位                                 5. store_notice "已恢复"     |
|                                                            6. 原地重绘，光标锁定原位    |
+--------------------------------------------+--------------------------------------------+
                                             |
                                 调用标准 CLI|契约 (-j)
                                             v
+-----------------------------------------------------------------------------------------+
|                                  底层持久存储面 (t-playlist)                             |
|                                                                                         |
|  t-playlist --rm NAME --index N        t-playlist --add NAME [--index N] < stdin        |
|  (从 .items 指定位置切除)              (通过 jq 切片在 0-based 指定位置插回原位)        |
+-----------------------------------------------------------------------------------------+
```

### 2.1 底层 Agent 面：`t-playlist --add` 扩展可选 `--index N`

**契约审查（`ROADMAP.md` 横切规范）**：
> “一个功能必带 agent 面。人有按键，agent 就要有动词加一个 `-j` 信封。它挡住的形状：先给 TUI 加个键、'agent 面回头再说'。”

* **现状缺陷**：目前 `t-playlist --add NAME` 仅支持追加到歌单末尾（`.items += $new`）。若 TUI 撤销只调用现有 `--add`，被删在第 2 行的歌曲会被扔到第 50 行末尾，破坏列表排序，无法达成“原地撤销”；
* **CLI 契约增强**：
  * 为 `t-playlist --add` 扩充可选 `--index N`（0-based 整数）；
  * 门控规则：
    * 仅接受非负整数；若 `--index` 超出当前数组长度，则自动退化为追加至末尾（Clamp 语义，保证容错健壮性）；
    * 保持 stdin 输入标准格式：单行 JSON 搜索信封、`--show` 信封或数组格式；
  * `jq` 核心切片实现：
    ```jq
    if $idx == null or ($idx | length == 0) then
        .items += $new
    else
        ($idx | tonumber) as $i |
        if $i >= (.items | length) then
            .items += $new
        else
            .items = (.items[0:$i] + $new + .items[$i:])
        end
    end
    ```
  * 退出码与信封完全沿用既有标准：写入成功返 0，携带新增后的信封；发生参数错误返 1；存储不可用返 4。

### 2.2 键位冲突仲裁：为什么是 `z` 而不是 `u`？

用户建议中提出“按 u（或特定键）原地撤销”。经全面审查现有键位映射：
* **`u` 键的绝对冲突**：
  * 在 `shell/ting`（第 8802 行）及 `ARCH-tui.md` 中，**`u | U` 是六大行源之一：打开待播队列（`open_queue`）**；
  * 队列与 `+`（入队）、`>`（切歌）构成了播放调度的基础流水线；
  * 若在歌单视图下将 `u` 临时重载为撤销，严重违背 `ROADMAP.md`「按下前可预期」原则，导致用户在歌单中想查看队列时意外触发撤销；
* **为什么裁定 `z` / `Z`**：
  1. **完全空闲**：`z` 与 `Z` 在 `shell/ting` 全局按键表中未分配任何功能；
  2. **现代人机心智统一**：`z` 是桌面与终端下撤销操作（Undo / Ctrl+Z）的首要通用联想；
  3. **左手黄金人机工学**：`z` 与 `d`（移出）、`x`（队列移出）、`a`（添加到歌单）、`s`（停止）均位于键盘左下核心区，用户单手即可连续完成“`d` 修剪曲目”与“`z` 瞬时纠错”，心流体验极度自然；
* **帮助提示更新**：在 `cycle_keys` 的二级提示（`hints_playlist`）中，同步展示 `z 撤销`。

### 2.3 单槽 Undo 缓冲（Single-Slot Buffer）状态机

#### 数据模型（纯 Bash 3.2 标量变量）
```bash
UNDO_PL_NAME=""          # 被删曲目所属歌单名
UNDO_PL_INDEX=""         # 被删曲目原始 0-based 索引
UNDO_ITEM_PAYLOAD=""     # 单曲完整 JSON 信封（由 focused_payload 提取）
UNDO_ITEM_TITLE=""       # 曲目标题（用于单帧通知展示）
```

#### 状态转移与失效矩阵
| 触发行为 | 单槽缓冲行为 | 说明与理由 |
|---|---|---|
| **按 `d` 移出曲目** | **写入 / 覆盖**最新条目 | 单槽始终维持最新一次被移除曲目，允许连续修剪 |
| **按 `z` 撤销操作** | **消费 / 立即清空** | 原位写回后清空缓冲，防止重复插入同一首歌曲 |
| **浏览光标（`j`/`k`/数字跳转）** | **维持保留** | 纯视觉移动不破坏反悔上下文 |
| **播放控制（空格/音量/进度/循环）** | **维持保留** | 播放器调度与曲库管理正交 |
| **切换歌单（按 `b` 换列表）** | **立即失效清空** | 严格限制作用域（Scope-bound），跨歌单撤销在语义上无意义 |
| **退出歌单（`ESC` 回到搜索）** | **立即失效清空** | 离开歌单行源，生命周期结束 |
| **按 `D` 删除整个歌单** | **立即失效清空** | 容器本身已不存在 |

### 2.4 播放状态与安全边界

沿用 `ARCH-tui.md` 确立的播放与存储解耦原则：
1. **移出时联动停播**：若当前被移出的曲目恰好处于正在播放状态（`focused_is_playing` 为真），立即调用 `stop_current_playback` 停播。这一行为保持不变；
2. **撤销时不自动拉起播放器（宁静原则）**：
   * 用户按 `z` 恢复曲目后，仅恢复歌单数据、重绘列表并将光标定位到该行；
   * **严禁自动拉起播放器**。撤销是静态数据恢复，非预期的声学输出会造成惊扰。用户若想继续收听，只需顺手按一次 `Enter`。

### 2.5 视觉呈现：零闪烁单帧通知

彻底废除 `confirm_key` 内部的 `printf` 滚屏打印，接入已有的单帧通知 `store_notice` 系统：
* **`d` 移出瞬间**：
  * 调用底层 `--rm`；
  * `store_notice "$S_PL_ACT:" "$S_PL_REMOVED: $TRUNC_TITLE ($S_PL_UNDO_HINT)"`；
  * 原地重绘，补齐上来的下一首曲目自动承接光标，状态行静默呈现撤销提示；
* **`z` 撤销瞬间**：
  * 调用底层 `--add --index`；
  * `selected=$UNDO_PL_INDEX`；
  * `store_notice "$S_PL_ACT:" "$S_PL_RESTORED: $TRUNC_TITLE"`；
  * 原地重绘，光标精确锁定恢复出来的行。

### 2.6 删空歌单的边界死锁治理

* **现状陷阱**：在现有逻辑中，当歌单中仅剩 1 首歌时按 `d`，歌单变空，`reload_playlist` 会触发 `confirm_key "$S_PL_EMPTY_DEL_CONFIRM"` 强行询问是否删除歌单，随后退出到搜索；
* **优化策略**：
  * 在单槽缓冲激活的情况下，移出最后一首曲目不应立刻弹出“是否彻底删除歌单”的强杀弹窗；
  * 列表重载后若为空，保持在空歌单视图态，通知行显示：`列表已清空 (按 z 撤销)`；
  * 此时按 `z`，曲目可重新插回原歌单，满血复活；只有当用户在空歌单态主动按 `ESC` 退出时，才执行既有的空歌单清理检查。

---

## 3. 详细实施步骤与交付里程碑

### Milestone 1：底层 `t-playlist` 扩充 `--add --index`

1. **参数解析与门控**：
   * 在 `shell/t-playlist` 中解析 `--index` 选项（允许 `--index N` 或 `--index=N`）；
   * 校验非负整数，非整数报错退出 1；
2. **JSON 原位切片注入**：
   * 改造 `action_add` 中的 jq 构造逻辑，在传入 `--index` 时执行数组切片拼接；
3. **离线契约测试证明**：
   * 在 `tests/contract.sh` 中增加测试用例：
     * 向拥有 3 首歌曲的测试歌单使用 `--add NAME --index 0` 插入首位；
     * 使用 `--add NAME --index 1` 插入中间位；
     * 使用 `--add NAME --index 999` 验证越界 clamp 追加行为；
     * 验证 `t-playlist --show` 输出顺序与预期严格吻合。

### Milestone 2：TUI 单槽缓冲与 `d` 键无阻塞化改造

1. **引入单槽 Undo 缓冲变量**：
   * 在 `shell/ting` 全局初始化 `UNDO_PL_NAME=""`, `UNDO_PL_INDEX=""`, `UNDO_ITEM_PAYLOAD=""`, `UNDO_ITEM_TITLE=""`；
   * 编写 `undo_clear` 辅助函数；
2. **改造 `delete_from_playlist`**：
   * 移除 `layout_cols` 打印与 `confirm_key "$S_PL_RM_CONFIRM"` 阻塞调用；
   * 在调用 `t-playlist --rm` 前，调用 `focused_payload` 提取完整曲目信封；
   * 暂存至 `UNDO_*` 变量；
   * 执行移除，发射单帧 notice 并原地重绘；
3. **视图切换与生命周期重置**：
   * 在 `open_playlist`、`browse_playlists`、`back_to_search` 等退出/换源函数中，埋设 `undo_clear`。

### Milestone 3：TUI 原地撤销动词与 `z` 键位闭环

1. **实现 `undo_playlist_removal`**：
   * 校验 `[[ "$LIST_SOURCE" == "playlist" ]]` 且 `[[ "$PLAYLIST_NAME" == "$UNDO_PL_NAME" ]]` 且 `[[ -n "$UNDO_ITEM_PAYLOAD" ]]`；
   * 不合法时提示 `无可用撤销`；
   * 通过管道将 `$UNDO_ITEM_PAYLOAD` 喂给 `"$PLAYLIST_BIN" --add "$UNDO_PL_NAME" --index "$UNDO_PL_INDEX" -j`；
   * 执行 `reload_playlist`，并将光标重设为 `selected=$UNDO_PL_INDEX`；
   * 清空单槽缓冲，发射成功单帧通知；
2. **事件循环按键绑定**：
   * 在 `shell/ting` 的列表按键分发 `case "$READ_NAV_KEY"` 中绑定：
     ```bash
     z | Z)
         if [[ "$LIST_SOURCE" == "playlist" ]]; then
             undo_playlist_removal
         fi
         ;;
     ```
3. **更新 i18n 字符与键位提示**：
   * 增加中英双语提示字典：
     * 中文：`S_PL_UNDO_HINT="z撤销"`, `S_PL_RESTORED="已恢复"`；
     * 英文：`S_PL_UNDO_HINT="z to undo"`, `S_PL_RESTORED="Restored"`；
   * 更新 `hints_playlist` 状态条。

### Milestone 4：边界工况与自动化测试验证

1. **在播歌曲移出与撤销验证**：
   * 验证正在播放的歌曲按 `d` 移出后正常触发停播；按 `z` 撤销后歌曲回到原位，播放器保持停止态；
2. **空列表死锁边界验证**：
   * 验证单首歌曲歌单按 `d` 后的状态呈现，以及按 `z` 后的恢复效果；
3. **tmux 自动化 TUI 驱动回归（`tests/drive.sh`）**：
   * 编写虚拟终端测试序列：进入歌单 -> 焦点移至第 2 首 -> 按 `d` 立即消失 -> 验证无等待停顿 -> 按 `z` 立即恢复在第 2 首 -> 验证标题与顺序完全吻合。

### Milestone 5：文档闭环与规范归档

1. **文档同步**：
   * 更新 [`docs/ARCH-cli-contract.md`](ARCH-cli-contract.md)：补充 `t-playlist --add` 的 `--index` 选项说明；
   * 更新 [`docs/ARCH-player.md`](ARCH-player.md)：更新歌单写操作与数组切片实现说明；
   * 更新 [`docs/ARCH-tui.md`](ARCH-tui.md)：在「存储与历史」中用“软撤销与单槽缓冲”正式替代原有的“`d` 是唯一先问的键”，记入 `z` 键与无阻塞心流原则；
   * 更新 [`docs/USER_MANUAL.md`](USER_MANUAL.md)：更新人机交互按键表；
   * 更新 [`docs/ROADMAP.md`](ROADMAP.md)：标记此项议题完结并移除。
2. **清理计划书**：
   * 按照仓库工作流，实现主体完成并蒸馏入正本文档后，执行 `git rm docs/PLAN-soft-undo.md`。

---

## 4. 风险登记与硬性红线

| 风险点 | 严重级 | 应对与控制措施 |
|---|---|---|
| **Bash 3.2 兼容性破坏** | 阻断 | 严禁使用关联数组 `declare -A` 记录 Undo 缓冲，必须使用普通标量变量；展开空变量前严格遵循引用与默认值约束。 |
| **底层 `t-playlist` 并发写入竞争** | 高 | 沿用 `t-playlist` 已有的 `lock_playlist` 文件锁机制，原位切片插入在临界区内完成，保证原子性。 |
| **CLI 契约破坏** | 阻断 | `--index` 作为纯增量可选参数，缺省时保持严格向后兼容的末尾追加行为；退出码与 JSON 信封字段保持稳定。 |
| **临时文件污染** | 高 | 脚本运行若需临时文件，一律收容在 `$TMPDIR/ting-<uid>/` 下，严禁污染源码树。 |
| **光标漂移与翻页撕裂** | 中 | 撤销后重新计算 `page_index=$((selected / PAGE_SIZE + 1))`，保证在分页模式下视口正确跟随聚焦行。 |
