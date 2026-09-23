# PLAN — 全套件撤销铁律：以可撤销取代预先确认

> **Status**: 实施中 · 铁律、范围与空歌单处理均已确认；2026-09-23 对照代码核查，补入首帧提示、推迟停播的执行点与失效、改名撤销的刷新、`--rm` 下标入副本四处缺口  
> **Priority**: 第一梯队 · 最高优先级（TUI 交互与心流专项）  
> **Target Branch**: main  
> **Roadmap 关联**: [`docs/ROADMAP.md`](ROADMAP.md)「第一梯队」——全套件撤销铁律  
> **Governing Docs**: [`docs/ARCHITECTURE.md`](ARCHITECTURE.md)「定位与设计目标」「设计决定（按模块与接口）」、[`docs/ARCH-cli-contract.md`](ARCH-cli-contract.md)「接口与 API（semver 的版本化对象）」「门模型 —— 一层，十个自己把门的动词」、[`docs/ARCH-player.md`](ARCH-player.md)「两个持久存储」、[`docs/ARCH-tui.md`](ARCH-tui.md)「`ting` 编排（自有胶水，零站点逻辑）」、[`docs/ROADMAP.md`](ROADMAP.md)「横切规范 —— 每个新功能都要过的判据」  
> **Verification**: `bash -n shell/*`、`tests/contract.sh --offline`、`tests/contract.sh`、`tests/playback.sh`、`tests/drive.sh -x 62 -y 20`  
> **Scope Boundary**: 为套件内所有「有撤销需求」的写操作建立同一套撤销铁律：写操作的所有者命令在锁内留持久副本，`--owner PID` 绑定副本到调用进程，宽限期 3 秒，写回前逐字节核对。TUI 绑定 `z`，并删除 `d` / `D` / `X` 的 `y/N` 确认与 `confirm_key`。agent 写操作（不带 `--owner`）不留副本。`t-history` 整体不纳入。不做多级撤销栈，不做重做（redo）。

本计划取代原 `PLAN-soft-undo.md`（只覆盖歌单 `d`）。原稿核查出的缺陷——清空点落在 `reload_playlist` 路径上、副本先于 `--rm` 写入、按名字比对撤销目标、`--add` 会复活已删列表、停播不可撤销、提示随任意键消失而缓冲仍有效——全部由下面的铁律在结构上消除，逐条对照见「边界工况对照」。

---

## 空歌单：保留文件，只删确认

已确认：`--rm` 删掉最后一项后，歌单文件照旧保留（count 0），`t-playlist` 的 `--rm` 与 `--show` 语义不变，不产生契约变化。

- **TUI 删空之后**：`reload_playlist` 发现列表为空时不再问「是否彻底删除」，直接回到搜索视图，提示 `S_PL_EMPTY` 与撤销提示；按 `z` 恢复最后一首并重新打开该列表。
- **`b` 打开空列表**：只提示 `S_PL_EMPTY`，不再询问删除。
- **空列表的去处**：它会一直出现在 `--ls` 与 `b` 的选择器里，直到用户按 `D` 删除。清理空列表是用户的显式动作，不再由删空的那一刻代为发问。
- 两处 `S_PL_EMPTY_DEL_CONFIRM` 与它们调用的 `--del` 一起删除。

---

## 为什么：可撤销取代预先确认

- **确认挡不住误操作。** 连续整理时，用户很快会把 `d → y` 练成一个连招，误触时 `y` 早已按下。确认的代价（每次两个键、一次打断视图的打印、一次停顿）是真实的，收益却是虚的。
- **队列 `x` 已经证明了这一点。** `queue_remove` 的注释写明它不需要确认，因为「误删的那一首用 `+` 就能放回去」。能否零确认，取决于恢复成本，而不是操作本身有多危险。
- **所以缺的是一个通用的、低成本的恢复手段。** 有了它，`d`、`D`、`X` 的确认都失去了存在的理由，`confirm_key` 整套机制可以删除。
- **为什么是一套铁律而不是逐个动词打补丁。** 原稿只给 `d` 做了一个内存缓冲，结果核查出十余处问题，根源都是同两个：缓冲活得比屏幕上的提示久；缓冲只靠一个名字字符串认对象。换一个动词就会重犯一遍。铁律让「谁写副本、何时失效、写回前核对什么」只有一种答案。

---

## 撤销铁律

凡纳入撤销的写操作，**全部**遵循以下规则，没有例外：

1. **副本由拥有该对象的命令在同一把锁内写。** 锁内顺序固定为：读出修改前的内容 → 写副本 → 写新内容；每一步都是「写临时文件 + `mv -f`」。任何一步失败，整个写操作失败；副本已写而正文未写成时，副本里的「修改后内容」和磁盘不符，撤销必被拒绝，不会造成错误恢复。**锁超时必须失败**：`t-play` 的 `lock_queue_state "$id" || true` 这类尽力而为的锁，在**带 `--owner` 的写**和 `--undo` 路径上改为超时即退出 4 `locked`。不带 `--owner` 的调用保持尽力而为，行为逐字节不变——`queue_edit` 同时服务 `--queue-rm`、`--queue-mv`、`--queue-jump`，`queue_append` 服务 `--enqueue`，所以严格与否由调用方传参决定，不能在这两个函数里一刀切。
2. **副本记录四样东西**：涉及的对象、每个对象修改前的内容、每个对象修改后的内容（原文，不存时间戳；`now_utc` 只到秒，同一秒两次写入区分不开）、截止时间（epoch 秒，写入时刻 + 3）。「不存在」本身也是一种合法内容，用于新建与删除。
3. **撤销只由同一命令的 `--undo` 执行。** 锁内先核对：截止时间未过；所属进程仍然存活；每个对象的当前内容与副本里的修改后内容逐字节一致（`cmp -s`；「不存在」对「不存在」）。全部满足才把修改前的内容写回，然后删除副本；否则退出 4，原因见「CLI 契约增量」。
4. **副本绑定所属进程，一个进程在一个存储里只有一个槽。** 由调用方用 `--owner PID` 显式传入，不用 `$PPID`：`ting` 大量走管道（`printf … | t-playlist --add …`），子进程的 `$PPID` 是管道子 shell。同一 owner 的新副本覆盖旧副本。**不带 `--owner` 的写操作不留副本**——agent 写操作走这条路。
5. **副本随所属进程结束而删除。** 正常退出（EXIT / INT / TERM / HUP）由 `ting` 的 `cleanup_on_exit` 调所有者命令的 `--undo --discard --owner $$` 删除；`ting` 不自己 `rm`，副本路径是存储的私有布局（与 `play_selected` 只从信封读 socket 路径同理）。`kill -9` 或崩溃时陷阱不会执行，由所有者命令每次运行时顺手清理：所属进程已不存在（`kill -0` 失败）的副本一律删除，做法照搬 `t-play` 的 `reap_dead_players`。副本实际寿命 = min(3 秒截止, 所属进程存活)；pid 在 3 秒内被复用的概率可以忽略。
6. **副本与对象存在同一层。** 歌单副本放在状态目录（持久存储），队列副本放在 `$TMPDIR/ting-<uid>/`（队列本身随播放器消失，副本活得比对象久没有意义，写回核对也必然失败）。两者都是磁盘文件：`z` 调用的是子进程，副本本来就必须在磁盘上。
7. **复制不了的副作用不得在宽限期内发生。** mpv 进程与播放状态无法复制再放回。凡写操作会连带停播（`d` 删到在播行、`D` 删的列表里有在播曲目），停播推迟到截止时间才执行；在此之前按 `z`，播放从未中断。
8. **到期是惰性判定。** `--undo` 执行时比较截止时间即可，没有后台定时器。`date +%s` 是整秒，实际窗口 2–3 秒。宽限期是写死的常量 `UNDO_GRACE=3`，在 `t-playlist` 与 `t-play` 中各写一份（命令之间允许复制、命令内部不允许，与现有「十个入口逐字重复」的块同理），不开放为配置项。

```
  ting (owner = $$)                     owner command (t-playlist / t-play)
  -----------------                     -----------------------------------
  key d / D / X / x / + / a
        |
        |  VERB ... --owner $$ -j
        +----------------------------->  reap copies of dead owners
                                         lock object(s)
                                         read PRE  -> write COPY {pre, post, deadline}
                                                   -> write POST (tmp + mv)
                                         unlock
        <-----------------------------+  envelope + undo.deadline
  hint "z undo" until deadline
  deferred stop (if any) armed
        |
  key z (before deadline)
        |  --undo --owner $$ -j
        +----------------------------->  lock object(s)
                                         now <= deadline ?  owner alive ?
                                         cmp current == COPY.post ?
                                           yes -> write COPY.pre back, drop COPY, exit 0
                                           no  -> exit 4 (undo_expired / undo_stale)
        <-----------------------------+
  cancel deferred stop, refresh view

  exit / INT / TERM / HUP
        |  --undo --discard --owner $$
        +----------------------------->  drop COPY of this owner
```

---

## 写操作清单与归类

| 命令与动词 | TUI 键 | 纳入撤销 | 修改前 → 修改后 | 理由 |
|---|---|---|---|---|
| `t-playlist --rm` | `d` | 是 | 文件 → 文件（删最后一首时修改后为空列表文件） | 用户主动删除 |
| `t-playlist --del` | `D` | 是 | 文件 → 不存在 | 用户主动删除，去掉确认 |
| `t-playlist --rename` | `R` | 是 | 旧名文件 → 不存在；不存在 → 新名文件 | 两个对象，锁顺序沿用现有 `--rename` |
| `t-playlist --add` | `a` | 是 | 文件或不存在 → 文件 | `a` 的选择器选错列表时，反操作要进列表找行再按 `d`，不是一个键 |
| `t-play --queue-rm` | `x` | 是 | 队列文件 → 队列文件 | `+` 放回会丢掉原位置 |
| `t-play --queue-clear` | `X` | 是 | 队列文件 → 队列文件 | 去掉确认 |
| `t-play --enqueue` | `+` | 是 | 队列文件 → 队列文件 | 与 `a` 对称 |
| `t-play --queue-mv` | `p` / `P` | 否 | — | 反方向的键就是精确的反操作 |
| `t-play` 播放控制（`-d` `--stop` `--next` `--queue-jump` 暂停 seek 音量 循环） | 多个 | 否 | — | 实时进程状态，不是文件，复制不了 |
| `t-history --record` | 无 | 否 | — | 自动写入，不是用户操作 |
| `t-history --clear` | 无 | 否 | — | 无锁追加是 `t-history` 的设计前提（见其文件头与 `do_clear` 注释）；TUI 无对应键。记为明确的 NO |
| `ting` 偏好写回 | 各循环键 | 否 | — | 再按一次同一个键就是反操作 |

---

## CLI 契约增量

全部是新增，不改任何已有字段、退出码或参数语义。版本 minor 升级，独占一次 commit。

### `--owner PID`

- 接受于：`t-playlist --add / --rm / --del / --rename / --undo`；`t-play --enqueue / --queue-rm / --queue-clear / --undo`。
- 门控（与 `--index belongs to --rm` 同一种门，`ARCH-cli-contract.md`「门模型」；和那道门一样只在 stderr 说一句、退出 1，不出信封）：
  - 值必须是正整数，否则退出 1；
  - 出现在其他动词上退出 1（「`--owner` belongs to …」），不静默忽略；
  - 不检查 PID 是否存活：写操作时 owner 已死只意味着副本会在下次调用时被清掉，不是用法错误。
- 带 `--owner` 的成功写操作，`-j` 信封新增 `undo: {deadline: <epoch 秒>}`；不带则信封完全不变。
- 写操作没有改动任何东西时（`--del` 一个不存在的列表，`deleted:false`）不写副本、信封不带 `undo`，该 owner 原有的副本原样保留：没有写就没有可撤销的东西。

### `--undo --owner PID [--discard] [-j]`

- `--undo` 是新动词，与现有动词互斥（「only one action per call」）；必须带 `--owner`，否则退出 1。
- `--discard` 只能与 `--undo` 同用：删除该 owner 的副本，不写回；无副本也返回 0（幂等，与 `--stop` 对已退出播放器的处理一致）。
- 退出码与原因：

| 情形 | 退出码 | reason |
|---|---|---|
| 写回成功 | 0 | — |
| 该 owner 在本存储没有副本（含已被清理、已消费） | 4 | `undo_none` |
| 已过截止时间 | 4 | `undo_expired` |
| 对象当前内容与副本的修改后内容不一致 | 4 | `undo_stale` |
| 锁超时 | 4 | `locked`（沿用 `t-playlist` 现有原因；`t-play` 新增同名原因） |
| 参数错误 | 1 | `invalid_input` |

- 成功信封：`{status:"ok", undone:<原动词>, ...}`。`t-playlist` 附 `name`（撤销后应显示的列表名，`--del` 与 `--rename` 撤销后就是原名）与 `index`（仅 `--rm` 的撤销：恢复出来那一项的位置，供 TUI 放光标），`--rename` 的撤销再附 `from`（撤销前的名字，即改名后的新名；与 `--rename` 自己的信封对称），TUI 靠它认出屏幕上显示的是哪个列表；`t-play` 附与其他队列动词相同的播放器记录（`pos/len/next/upcoming`），TUI 走现成的 `apply_player_record`。

### 每次调用顺手清理

`t-playlist` 与 `t-play` 的每次运行（任何动词，包括 `--ls` / `--status`）先清理本存储里所属进程已死的副本。清理本身不加对象锁（只删副本文件，不碰对象），失败不影响本次动词。

---

## 副本的存储格式与位置

- **`t-playlist`**：`$UT_STATE_DIR/undo/playlist-<owner>/`。不放在 `playlists/` 下：那里的 `*.json` 是 `--ls` 的命名空间；歌单名不能以 `.` 开头（`validate_name`），但把副本放到命名空间外面，就不用依赖这条规则。
- **`t-play`**：`$TMPDIR/ting-<uid>/undo-queue-<owner>/`。在 `players/` 之外，`reap_dead_players` 遍历的是 `players/*.json`，不会误读。
- **目录内容**（一个副本 = 一个目录，整体 `mv` 到位，保证原子）：
  - `meta.json`：`{schema:1, owner, verb, deadline, objects:[{key, pre_exists, post_exists}]}`，`--rm` 另加 `index`（撤销信封要回报它，而撤销时正文里已经没有那一项可查）；`key` 在 `t-playlist` 是歌单名，在 `t-play` 是播放器 id；
  - `t-play` 的副本目录另放一个 `id` 文件（播放器 id 的纯文本）：`rm_player_files` 要找出以某个播放器为对象的副本，读这个文件是一次 `read`，不必对每个目录跑一次 `jq`；
  - `<k>.pre`、`<k>.post`：对象修改前 / 后的原文字节，`k` 是 `objects` 的下标；对应 `*_exists` 为 false 时不存在该文件。
- 写副本：先在同级 `…tmp.$$` 目录写全，再 `rm -rf` 旧副本目录并 `mv` 新目录到位。都在对象锁内完成。
- 核对：`[[ -f obj ]]` 与 `post_exists` 一致，且存在时 `cmp -s obj <k>.post`。`cmp` 与 `mv`、`mktemp`、`date` 同属系统基础工具，不算新增运行时依赖。
- **队列的额外约束**：播放器每换一首会在锁内改写 `pos`（`queue_advance_from`），所以跨过曲目边界后核对必然失败，撤销被拒。这正是想要的：写回修改前的内容会把 `pos` 倒回去，导致重播。

---

## TUI 侧设计

### 内存记录（纯标量，bash 3.2）

```bash
UNDO_STORE=""        # playlist | queue — 本实例最后一次可撤销写发给了哪个存储
UNDO_END=0           # 撤销到期的时刻，换算到 $SECONDS 的时钟上（见下）
UNDO_LABEL=""        # 提示用的短文本（动作 + 曲目或列表名）
UNDO_STOP_PENDING=0  # 规则 7：到期才执行的停播
```

它们不是副本，只是 `ting` 记得「该去哪个存储撤销、提示显示到什么时候」。副本本身只在磁盘上，是否能撤销永远由所有者命令判定。

**本地时钟用 `$SECONDS`**：写成功时 fork 一次 `date +%s`，`UNDO_END=$((SECONDS + deadline - now))`。之后每一帧、每一轮的到期判定都是一次算术比较，不 fork——bash 3.2 没有 `EPOCHSECONDS` 也没有 `printf '%(%s)T'`，按帧 fork `date` 是每次重绘多一个进程。两边都是整秒，本地判定与所有者命令的判定最多差一秒，差出来的那一秒里按 `z` 得到的是 `undo_expired`，照第 4 步处理。

**记录失效时挂着的停播立即执行**：内存记录被清空或被新记录替换，只要不是 `z` 成功，旧的撤销就再也做不成了——同存储的新写覆盖了槽，跨存储的新写 discard 了旧副本，到期，或 `undo_last` 得到退出 4。此时若 `UNDO_STOP_PENDING` 为 1，当场 `stop_current_playback`。清空记录只有一个函数（`undo_forget`），这条规则只写在它里面。

### 所有可撤销调用都带 `--owner $$`

调用点：`add_to_playlist`（`--add`）、`delete_from_playlist`（`--rm`）、`delete_current_playlist`（`--del`）、`rename_current_playlist`（`--rename`）、`enqueue_selected`（`--enqueue`）、`queue_verb` 的 `--queue-rm` / `--queue-clear` 两个调用方。成功后从信封读 `undo.deadline` 填内存记录。

**单槽跨存储**：若新的可撤销写发往的存储不同于 `UNDO_STORE`，且旧记录未到期，先调旧存储的 `--undo --discard --owner $$`，再记新的。这样本实例在全套件范围内始终只有一个可撤销的副本，`z` 不会变成多级撤销。

### `z` 键

- 在列表按键分发里绑定 `z | Z) undo_last ;;`，任何视图都生效。
- `undo_last`：
  1. `UNDO_STORE` 为空或 `SECONDS >= UNDO_END` → 提示 `S_UNDO_NONE`，返回；
  2. 调 `"$PLAYLIST_BIN"` 或 `"$PLAY_BIN"` 的 `--undo --owner $$ -j`；
  3. 退出 0：取消 `UNDO_STOP_PENDING`，清空内存记录，按信封刷新视图（见下），提示 `S_UNDO_DONE`；
  4. 退出 4：清空内存记录，按 reason 提示（`undo_stale` 要明确说「列表已被别处修改，未撤销」），**不刷新、不猜**；
  5. 其他退出码：保留内存记录（锁超时可以重试），提示失败原因。
- **刷新视图**：
  - 歌单：撤销的是 `--rename` 且屏幕上是信封的 `from`（改名后的新名）时，先把 `PLAYLIST_NAME` / `QUERY_LABEL` 改回信封的 `name`，然后照下一种情形处理——改名之后 `PLAYLIST_NAME` 已是新名，只按 `name` 比对会认不出屏幕上的列表，标题停在一个已不存在的名字上。若当前是 `LIST_SOURCE=playlist` 且显示的正是信封里的 `name`，`reload_playlist` 后把 `selected` 设为信封的 `index`（夹到 `NUM_ENTRIES-1` 以内），**再**按 `selected` 重算 `page_index`；若当前在搜索视图且撤销的是 `--del`，或是把列表删空的那次 `--rm`（删空后 TUI 已回到搜索视图），`open_playlist` 重新打开该列表，`--rm` 的情形再把光标放到信封的 `index`；其他视图只提示，不跳转。
  - 队列：`apply_player_record`；当前在队列视图时再 `reload_queue`，其他视图不跳转。
- 光标只用信封给出的位置，不用 TUI 自己记的下标：列表可能已被别处修改，只有所有者命令知道恢复到了哪里。

### 提示的生命周期与刷新

- 现有规则是提示在下一次按键时被 `read_nav_input` 清掉。撤销提示改为：`display_menu` 在 `SECONDS < UNDO_END` 时，总在提示位上画撤销提示——提示位为空时画 `UNDO_LABEL` + `S_UNDO_HINT`，已有普通提示时把 `S_UNDO_HINT` 接在它后面。按键仍会清掉普通提示，撤销提示照画。
- **为什么是「接在后面」而不是「提示位空时才画」**：可撤销写的那一帧，提示位几乎总是被占着——`d` / `D` / `R` / `a` 成功时各自写了一条成功提示，删空时 `open_playlist` 写了 `S_PL_EMPTY`。只在空位上画，撤销提示要等到下一次按键才出现，恰好错过用户最可能想撤销的那一刻。两者并排，**提示可见 ⇔ `z` 有效**才从第一帧起成立。可撤销写成功时不再写自己的成功提示：`UNDO_LABEL` 已经说了做了什么（「已移出 → 列表名」），再写一条是同一句话说两遍。
- `read_nav_input` 的 `-t 1` 刷新条件加上 `((UNDO_END > 0))`，与 `PREF_DIRTY`、`IMAGE_DIRTY` 并列，保证没有播放、没有按键时到期那一帧也会重画。
- **到期判定放在主循环每一轮的开头，不放在 `nav_tick`**：`nav_tick` 只在读键超时时才跑，连续按键（按住 `j`）时一次也不跑，推迟的停播就会拖到用户停手为止。每一轮开头 `((UNDO_END > 0 && SECONDS >= UNDO_END)) && undo_forget`，按键与超时两条路都经过这里，而且只是一次算术比较。阻塞的提示（`a` 的选择器、`R` / `n` 的输入）期间主循环不转，停播推迟到提示返回后的第一轮——这时撤销早已过期，用户正在输入，延迟停播的那几秒无害，不为它在阻塞读里另开时钟。
- 副本文件不在到期时删：它由所有者命令惰性判定为过期，由退出时的 discard 或下一次写覆盖。

### 推迟的停播（规则 7）

- `delete_from_playlist`：删除前 `focused_is_playing` 为真时，不再立即 `stop_current_playback`，改为置 `UNDO_STOP_PENDING=1`。
- `delete_current_playlist`：同理（列表内有在播曲目时）。
- 宽限期内按 `Enter` 播别的：`play_selected` 本来就会先 `stop_current_playback`，这时顺手清掉 `UNDO_STOP_PENDING`（只清停播，不清撤销记录：撤销仍可做，只是那一首已经不在播了）。
- 宽限期内又做了一次可撤销写：见「内存记录」的失效规则，挂着的停播当场执行。
- 宽限期内退出：`q` 本来就停播；`Q`（保留播放退出）让已删除的那一首继续播完——这是用户明确选择的「让它继续播」，不额外处理。

### 删除的确认

- `delete_from_playlist`：删掉 `layout_cols` / `truncate_disp` / 两行 `printf` 与 `confirm_key "$S_PL_RM_CONFIRM"`；`focused_index` 与 `focused_is_playing` 保留。
- `delete_current_playlist`：删掉标题 `printf` 与 `confirm_key "$S_PL_DEL_CONFIRM"`。
- `queue_clear`：删掉标题那几行与 `confirm_key "$S_Q_CLEAR_CONFIRM"`。
- `reload_playlist` 与 `browse_playlists` 里的 `S_PL_EMPTY_DEL_CONFIRM` 及其 `--del` 调用：删除，行为见「空歌单：保留文件，只删确认」。
- 以上全部删完后 `confirm_key` 没有调用方，连同 `S_PL_RM_HEAD`、`S_PL_RM_CONFIRM`、`S_PL_DEL_HEAD`、`S_PL_DEL_CONFIRM`、`S_PL_EMPTY_DEL_CONFIRM`、`S_Q_CLEAR_CONFIRM`（中英两套）一起删除。之后 TUI 里唯一中断界面、占住输入的只剩 `prompt_name`（真的要输入文字）。

### 退出

`cleanup_on_exit` 中，若 `UNDO_STORE` 非空，调该存储的 `--undo --discard --owner $$`（最多一次 fork，不遍历两个存储）。放在偏好写回之后、停播之前。

### 新增字符串（中英）

`S_UNDO_HINT`（「z 撤销」/「z to undo」）、`S_UNDO_DONE`（「已撤销」/「Undone」）、`S_UNDO_NONE`（「无可撤销」/「nothing to undo」）、`S_UNDO_STALE`（「已被别处修改，未撤销」/「changed elsewhere, not undone」）。`z` 进键位提示的 core 一级，所有视图都显示。

---

## 边界工况对照

| 原稿问题或工况 | 由哪条规则消除 |
|---|---|
| `open_playlist` 里清缓冲，被 `reload_playlist` 立即清掉 | TUI 没有需要「清空」的缓冲；副本在磁盘，失效由截止时间与核对决定 |
| 副本先于 `--rm` 写入，删失败后 `z` 造成重复 | 规则 1：副本与正文在同一锁内，正文失败则副本不符，撤销被拒 |
| 按名字比对撤销目标（容器视图同名、`R` 改名） | 规则 3：核对的是对象内容，不是视图里的名字 |
| `--add` 复活被别人删除或改名的列表 | 规则 3：对象「不存在」与副本的修改后内容不符 → `undo_stale` |
| 删到在播行，停播不可撤销 | 规则 7：停播推迟到截止时间 |
| 恢复出来的不是原记录（重复 url、`added_at` 被改写） | 规则 2：写回的是修改前的原文字节，不经过 `read_items` |
| 提示消失而缓冲仍有效，很久后按 `z` 恢复了忘掉的删除 | 规则 8 + 提示生命周期：提示可见 ⇔ `z` 有效，最长 3 秒 |
| 别处在 `d` 与 `z` 之间改了列表，下标过时 | 规则 3：内容不符 → `undo_stale`，不做夹取、不猜位置 |
| `z` 后光标落到别的行或列表外 | 光标取信封的 `index`，再重算 `page_index` |
| `--add` 失败时缓冲已清，无法重试 | `undo_last` 只在退出 0 或 4 时清内存记录 |
| 队列跨曲目边界后撤销导致重播 | 规则 3：`pos` 已变 → `undo_stale` |
| 队列锁尽力而为（`|| true`） | 规则 1：带 `--owner` 的写与 `--undo` 路径锁超时即退出 4；其余调用不变 |
| `ting` 被 `kill -9`，副本残留 | 规则 5：下次任意调用清理死 owner 的副本 |
| 两个 `ting` 实例、agent 互相撤销 | 规则 4：副本按 owner 分槽；agent 不带 `--owner` 不留副本 |
| 连续多次 `d` 后按 `z` | 单槽：只撤销最后一次，提示里写明是哪一首 |
| 写成功那一帧提示位被成功提示或 `S_PL_EMPTY` 占着，看不到撤销提示 | 撤销提示接在普通提示后面，从第一帧起可见 |
| 连续按键时 `nav_tick` 不跑，推迟的停播过期不执行 | 到期判定在主循环每一轮开头，用 `$SECONDS` 比较 |
| 宽限期内又做了一次可撤销写，旧撤销作废而停播仍挂着 | `undo_forget`：记录失效（非 `z` 成功）时挂着的停播当场执行 |
| `R` 之后 `z`，屏幕标题停在新名上 | 撤销信封带 `from`，TUI 认出屏幕上的列表并改回原名 |

---

## 实施步骤与里程碑

### Milestone 1：`t-playlist` 铁律落地

1. 解析 `--owner` / `--undo` / `--discard`，按「CLI 契约增量」加门控；`--index` 的现有门不动。
2. 实现副本写入（锁内：读修改前 → 写副本目录 → 写正文）、`--undo` 的核对与写回、`--discard`、每次运行时的死 owner 清理。
3. 四个动词接入：`--rm`、`--del`、`--rename`（两个对象，沿用现有锁顺序）、`--add`（含新建列表）。
4. `--rm` 删最后一项的行为不变（保留 count 0 的文件），只是同样留副本。
5. `tests/contract.sh --offline` 新增（全部驱动真实 `t-playlist`，owner 用测试 shell 的 `$$`，它在整个测试期间存活）：
   - 四个动词各自 `--owner $$` 写 → `--undo --owner $$` → `--show` 与写之前逐字节一致；
   - 不带 `--owner`：信封无 `undo` 字段，随后 `--undo --owner $$` 退出 4 `undo_none`；
   - 写后用另一次不带 owner 的 `--add` 改动同一列表 → `--undo` 退出 4 `undo_stale`，列表保持改动后的样子；
   - `--del` 后用同名 `--add` 重建 → `--undo` 退出 4 `undo_stale`；
   - 过期：写后轮询 `--undo`，直到返回 `undo_expired`，上限 5 秒（轮询真实返回值，不 `sleep 3`）；这一项放在独立的后台用例里，与其他离线检查并行，不拉长串行耗时；
   - 死 owner：`sh -c 'echo $$'` 取一个已退出的 pid 作 owner 写 → 任意一次 `--ls` 之后副本目录消失 → `--undo` 退出 4 `undo_none`；
   - 门控：`--owner` 非整数、`--owner` 用在 `--show` 上、`--undo` 不带 `--owner`、`--discard` 不带 `--undo`，各退出 1；
   - `--discard` 幂等：无副本时返回 0；
   - 删最后一项：`--rm` 后 `--show` 仍退出 0 且 count 0；`--undo` 后恢复原样。

### Milestone 2：`t-play` 队列铁律落地

1. 同一套参数与门控；`--enqueue`、`--queue-rm`、`--queue-clear` 接入。
2. `queue_append`、`queue_edit`、`queue_clear_tail` 各加一个「严格」参数：为真时 `lock_queue_state` 超时即返回失败，调用方退出 4 `locked`；为假时保持现在的 `|| true`。只有带 `--owner` 的 `--enqueue` / `--queue-rm` / `--queue-clear` 与 `--undo` 传真；`--queue-mv`、`--queue-jump`、不带 `--owner` 的调用、以及播放器自己的 `queue_advance_from` / `queue_bump` 一律不变（其他路径的尽力而为行为本计划不动，另议）。不带 `--owner` 时行为不变，由现有 `tests/playback.sh` 的队列用例原样通过来证明，不另造占锁场景。
3. 副本随播放器消失：`rm_player_files` 一并删除以该播放器为对象的副本。
4. `tests/playback.sh` 新增（真实 detached 播放器）：`--queue-rm` 后 `--undo` 恢复原位；跨一次 `--next` 后 `--undo` 退出 4 `undo_stale`；`--queue-clear` 后 `--undo` 恢复全部待播；`--stop` 后副本消失。

### Milestone 3：TUI

1. 内存记录、所有调用点加 `--owner $$`、单槽跨存储的 discard。
2. `undo_last` 与 `z` 键；视图刷新与光标。
3. 提示生命周期、刷新条件、`nav_tick` 到期处理、推迟停播。
4. 删除确认与 `confirm_key` 及其字符串；更新 `tests/contract.sh` 里把 `confirm_key` 列为「非主循环读取方」的两处注释。
5. 退出时 discard。
6. tmux 驱动用例（`tests/drive.sh` 与 `tests/contract.sh` 在线部分）。歌单必须用真实命令建出（真实搜索 `-j | t-playlist --add`），不预置文件；每一步都轮询帧上的信号：
   - 打开歌单 → 焦点移到第 2 首 → `d` → 帧上第 2 首已变、出现撤销提示、且没有 `y/N` → `z` → 第 2 首回到原位、光标在它上面；
   - `d` → 等撤销提示从帧上消失 → `z` → 提示「无可撤销」，列表不变；
   - 在播行 `d` → 宽限期内播放条仍在 → `z` → 播放条始终未消失；另一轮不按 `z` → 播放条在提示消失时一同消失；
   - `D` → 回到搜索 → `z` → 列表重新打开；
   - `R` 改名 → `z` → 标题回到原名，`--ls` 里只有原名；
   - 单曲歌单 `d` → 回到搜索、帧上无 `y/N`、有空列表提示与撤销提示 → `z` → 列表重新打开且那一首在；另一轮不按 `z` → `b` 的选择器里该列表仍在、显示 0 首；
   - `q` 退出后状态目录下该 owner 的副本目录不存在。

### Milestone 4：文档闭环

1. `ARCH-cli-contract.md`：`--owner` / `--undo` / `--discard` 进「门模型」；新 reason 进 reason 说明。
2. `ARCH-player.md`「两个持久存储」与队列部分：副本布局、锁内顺序、核对、死 owner 清理、为什么 `t-history` 不纳入。
3. `ARCH-tui.md`：删除「**`d` 是唯一一个破坏性的键，所以它是唯一一个先问的键**」整条（含 `confirm_key` 段）；写入「可撤销取代预先确认」、提示可见 ⇔ 撤销有效、推迟停播。
4. `ARCHITECTURE.md`「设计决定（按模块与接口）」：记入撤销铁律这一跨模块决定（why，不抄规则条文）。
5. 源码注释：`queue_remove` 的「No confirmation, unlike `d`」、`queue_clear` 的「the only queue key whose effect the user cannot undo」按新事实改写。
6. `USER_MANUAL.md`：键位表加 `z`，删去三处确认的描述。
7. `ROADMAP.md`：删除本条目；`t-history --clear` 不纳入记为明确的 NO（重开条件：`t-history` 放弃无锁追加）。
8. 蒸馏完成后 `git rm docs/PLAN-undo.md`。

---

## 风险与硬性红线

| 风险点 | 严重级 | 控制措施 |
|---|---|---|
| bash 3.2 兼容 | 阻断 | 内存记录全部是标量；副本目录用普通文件，不用关联数组；空数组展开沿用 `${arr[@]+"${arr[@]}"}` |
| 契约破坏 | 阻断 | 全部新增；不带 `--owner` 时所有动词的行为与信封逐字节不变，由离线用例断言 |
| 锁内多写一份副本拖慢写操作 | 中 | 副本是对象原文的一次拷贝，歌单与队列文件都是 KB 级；`--add` 的热路径仍是 `read_items` 那次 jq |
| 退出时多一次 fork | 低 | 只在 `UNDO_STORE` 非空时调用，最多一次 |
| 清理死 owner 误删活副本 | 中 | 只删 `kill -0` 失败的 owner；同 uid 下 `kill -0` 对活进程必然成功 |
| 临时文件污染 | 高 | 副本只在状态目录与 `$TMPDIR/ting-<uid>/` 下；测试只在 `tmp/` 与隔离的 `UT_STATE_DIR` 下 |
| 推迟停播期间用户以为已删除的歌还在播 | 低 | 撤销提示同时可见，说明这是宽限期 |
