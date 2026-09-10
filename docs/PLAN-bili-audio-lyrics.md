# PLAN-bili-audio-lyrics —— B 站音频区（`au` 号）的歌词动词

> **Status**: 草案（Draft）· **2026-09-10 按实测修正，尚未实施**
> **Priority**: P3（单点能力补齐；见「1.3 这条路的天花板」——收益比原稿估得低）
> **Target Branch**: main
> **Governing Docs**: [`docs/ARCH-engine.md`](ARCH-engine.md)「字幕（`--transcript`）」、[`docs/ARCH-cli-contract.md`](ARCH-cli-contract.md)「数据契约」「门模型」「退出码、TTY、依赖」
> **Verification**: `tests/contract.sh --offline`（门）+ 手跑真 `au` 号（信封）
> **Grounding**: 本文标「实测」的每一条都在 2026-09-10 用 `curl` 与 yt-dlp 2026.08.19 跑过，命令与样本写在原处

---

## 1. 现状、证据与天花板

### 1.1 契约缺口

三对引擎在 `--transcript` 上不对称：`yt-resolve` 有（字幕轨 + 语言优先链）、`ne-resolve` 有
（歌词，一次 GET），`bili-resolve` **完全没有**，且是**刻意声明的缺席** —— `shell/bili-resolve`
的参数解析里有一条专门的 arm 拦下 `--transcript | --subtitles | --sub-lang | --sub-langs`，
`-h` 里写着「There is no --transcript」，`tests/contract.sh` 有一条 `bili-resolve has no
--transcript` 在钉这件事。**这三处加上 ARCH 两份文档里的相应陈述，必须与实现同一次改动。**

### 1.2 外部证据（实测 2026-09-10）

yt-dlp 2026.08.19 的 `BilibiliAudioIE`（`extractor/bilibili.py`，类在 1952 行，歌词在 1998 行）
把音频区单曲的歌词作为一条字幕轨暴露：`song/info` 的 `.data.lyric` 非空时给
`subtitles: {origin: [{url: lyric}]}`。直接实测那个端点：

```sh
curl -sS --compressed -H 'User-Agent: …' -H 'Referer: https://www.bilibili.com/' \
  -G "https://www.bilibili.com/audio/music-service-c/web/song/info" --data-urlencode "sid=1003142"
```

| 观察 | 结论 |
|---|---|
| `.data.lyric` = `http://i0.hdslb.com/bfs/music/15648361161003142.lrc`，或**空字符串** | 它**永远是一个 URL 或空**，从不是内联文本 —— 原稿「若已是内联文本则直接使用」那一支是死代码 |
| 给出的是 `http://` | 取之前要升到 https（本仓所有 curl 都走 https） |
| `music-service-c` 无视 `Accept-Encoding` 一律回 gzip | 必须带 `--compressed`，否则拿到二进制 |
| 拉回来的 `.lrc`：58 行，**零个 `[mm:ss]` 时间戳**（第二个样本 au2441541，60 行，同样零个） | **这是本计划唯一真正的未决问题**，见 2.3 |
| au1003142 的歌词是**日文** | `lang` 只能是 `null`，见 2.2 |

### 1.3 这条路的天花板（实测，原稿没有量）

从 `am10624` 取 16 首里抽 7 首查 `.data.lyric`：**5 首为空**。也就是说这个动词最常见的答案是
一次 miss。它仍然值得做（一次 GET，无依赖新增），但「中高 ROI」是高估：**收益是"有歌词的那部分
能取到"，不是"B 站音频区有歌词了"**，`-h` 应当照实说。

### 1.4 与已落地的 `--items` 的关系

`--items`（容器动词）已于 2026-09-10 落地，三个引擎都有（ARCH-engine.md「容器（`--items`）」）。
两件事在 `bili-resolve` 里挨着，但**不共用文法**，这有实测依据：

- `--items` 的 `am` 句柄走 `normalize_container`，**没有**进 `normalize_target`。原因是实测
  `bili-resolve -j -- https://www.bilibili.com/audio/am10624` 今天答 `status:"ok"` 且
  `stream_urls: []` —— 把 `am` 放进主文法等于把这个空信封的入口开得更大。
- 而 `au` 是**单曲**：实测 `bili-resolve -j -- https://www.bilibili.com/audio/au2478206` 答
  `status:"ok"`、一条流、`id:"2478206"`、1.4s。所以 `au` 进 `normalize_target` 是安全的，本计划
  就该这么做 —— 它让 `au` 裸号在流解析、`--info` 和 `--transcript` 三处一致。

---

## 2. 设计规约（与既有契约对齐）

### 2.1 句柄：`au` 裸号进主文法

`shell/bili-resolve` 的 `normalize_target`（今为 438–464 行）加一条 arm，与 `av` 并列：

```bash
au[0-9]*)
    [[ "$t" =~ ^au[0-9]+$ ]] ||
        die "'$t' is not a Bilibili handle (expected a BV id, an av/au id, or a URL)"
    TARGET_URL="https://www.bilibili.com/audio/$t"
    ;;
```

`av` arm 的那句 die 文案同时改成上面这句（它现在说的是「BV id, an av id, or a URL」）。

**URL 形态不需要白名单改动**：URL 那一支只查 host，`bilibili.com/audio/au…` 今天就通过（实测）。
真正缺的是一个**取 au 号的函数** —— `target_id`（今为 515 行）只认 BV/av，所以 `--transcript`
分不出「这是音频区单曲」还是「这是视频」。照 `--items` 的 `container_id` 写一个 `audio_id`：
`/audio/au<digits>` 命中则返回数字，否则空。

### 2.2 `--transcript` 的分流与信封

- **句柄是视频（BV/av，或视频 URL）**：退 **1**，散文说明本站视频没有字幕轨、这个动词只对音频区
  单曲有意义。**在 `normalize_target` 之后判**，这样 host 门先答（`tests/contract.sh` 的
  `every read-only verb reaches the host gate` 对每个只读动词都读这个顺序）。
- **句柄是音频区单曲**：`resolve_transcript`。

**信封严格照既有两个引擎，不新造字段，不新造码**（原稿这里有三处与契约冲突，逐条订正）：

| 项 | 原稿 | 正确值 | 依据 |
|---|---|---|---|
| miss 的退出码 | `4` | **1** | `ne-resolve` 的 `transcript_fail` 与 `yt-resolve` 同款；`4` 是生命周期/存储码，引擎从不发 |
| miss 的 `reason` | `no_transcript` | **`no_subtitles_available`** | 共享枚举，另两个引擎已在发这一个 |
| `lang` | `"zh-Hans"` | **`null`** | 这个端点不标语言，且首个样本就是日文 —— 与 `ne-resolve` 同一条理由，`tests/contract.sh` 已在钉 ne 的 null |
| `text` 的连接符 | `\n` | **空格** | 两个引擎都是 `map(.text) \| join(" ")` |
| `is_auto` | `false` | `false` | 对：歌词是人贡献的 |

`-J` 必须比 `-j` **多**一个 `segments`（`[{start,duration,text}]`），这是既有 `--transcript -J`
的跨引擎形状，`tests/contract.sh` 有检查在读它。

### 2.3 未决问题：没有时间戳的"LRC"

实测的两份歌词文件**一行时间戳都没有**（1.2）。这一条推翻了原稿的两个前提：

- `sed 's/\[[0-9:.]*\]//g'` 无戳可剥；
- 照抄 `ne-resolve` 的 `JQ_LRC` 会**把有歌词的歌报成 miss** —— 它的 `lrc_segments` 以"行首有
  `[mm:ss]`"为成为 segment 的判据，零戳文件解出 0 段，于是走 `no_subtitles_available`。

于是要先定一件跨引擎的事：**当源不说时间时，`segment_count` 与 `-J` 的 `segments[].start` /
`duration` 是什么。** 三条路，各自的代价：

1. **两种形状都收**：行首有戳按戳解（与 ne 同），否则每个非空行一段、`start: null`、`duration: 0`。
   `-J` 的段记录里出现 `start: null` —— 这是**跨引擎信封的一次加宽**，另两个引擎从不发 null start。
2. **只发 `-j`，零戳文件不给 `segments`**：`-J` 与 `-j` 等价。代价是打破"`-J` 是 `-j` 的严格超集"。
3. **把非空行当段但不发 start**：`segments[]` 只有 `{text}`。同样是加宽，且更隐蔽。

**这条要先拍，再写代码**（CLAUDE.md 第一条）。倾向 1：它是唯一一个既不撒谎、又保住 `-J ⊃ -j` 的
选项，代价是让 `start: null` 成为契约的合法取值 —— 那需要在 ARCH-cli-contract.md「数据契约」写明。

### 2.4 门模型义务（照 ARCH-cli-contract.md「门模型」）

1. **`--transcript` 必须进 unknown-flag 那一行的清单**（今为 `-f -S --quality -j -J --info
   --parts --items --auth`）。那一行是 `tests/contract.sh` 的 `_ro_verb_has` 与 `uting` **唯一**
   的动词发现通道 —— 不加，两个只读动词循环一条 bili 用例都不会生成，功能对套件与 TUI 都不存在。
2. **`--sub-lang` / `--sub-langs` 仍然要拒**，且要有**自己的**文案。现有那条 arm 一并拦下了它们，
   删整条 arm 会把语言选择也放进来；本站一首歌一条歌词、无语言标记，与 `ne-resolve` 同一情形，
   照它的措辞写。`tests/contract.sh` 的 host 门循环正是从 flag 清单里**发现**这个伴随参数的，
   所以 `--sub-lang` 绝不能出现在那一行里。
3. `-f` / `-S` / `--quality` 撞 `--transcript` → 退 1，文案含 `does not apply to --transcript`
   （现有 `[[ -n "$FORMAT_FLAG" && "$ACTION" != "stream" ]]` 那一支已经这么答，无需新代码）。
4. 与 `--info` / `--parts` / `--items` / `--auth` 互斥 → 退 1（`--items` 落地时加的 `set_action`
   已经是这个形状，把 `transcript` 接进去即可）。
5. 依赖门惰性：`--transcript` 只要 `curl jq`，在 `require_deps yt-dlp jq` 之前分流 —— 与
   `--parts` / `--items` 同处。

### 2.5 取数与清洗

不跑 yt-dlp（它的 `song/info` 调用只为拼一条字幕轨 URL，而那正是我们自己一次 GET 就拿到的东西）：

1. `song/info?sid=<au>`：curl **带 `--compressed`**、带 UA 与 Referer；成功判据与本文件既有两个
   端点一致（curl 0 + HTTP 200 + body `code == 0`），失败走 `classify_view_error`；
2. `.data.lyric` 空或缺 → `no_subtitles_available`（退 1）；
3. 非空则**升 https** 后再 GET 一次；HTTP 200 且非空才算；
4. 解析按 2.3 拍的那条路；`chars` 是 `text` 的字符数，`segment_count` 是段数（与两个引擎同义）。

---

## 3. 验证矩阵

### 3.1 手跑（联网）

```sh
shell/bili-resolve --transcript -- BV1GJ411x7h7          # 1，散文说"视频没有字幕轨"
shell/bili-resolve --transcript -j -- au1003142           # 0，lang=null，text 非空（日文）
shell/bili-resolve --transcript -J -- au1003142 | jq -e '.segments|length>0'
shell/bili-resolve --transcript -j -- au2478206           # 1，no_subtitles_available（lyric 为空的那种）
shell/bili-resolve -j -- au1003142 | jq -e '.stream_urls|length>0'   # 裸 au 号进主文法之后
```

### 3.2 进 `tests/contract.sh`

- **改**：`bili-resolve has no --transcript` 这条要换掉 —— 换成「视频退 1 且文案说明只对音频区
  有效」，`--transcript` 的能力声明改由 unknown-flag 清单承担。986–994 行那段解释「缺失动词有两
  种报法」的注释也要跟着改，它举的例子就是 `bili-resolve --transcript`。
- **自动长高**：两个只读动词循环（`--info --transcript --parts --items`）会自动为 bili 生成
  `--transcript` 的格式标志与 host 门用例，floor 断言不动。
- **加**：`bili-resolve --sub-lang` 仍退 1，且**不**出现在 flag 清单里。
- 联网段加一条真 `au` 号的信封检查，与 `ne transcript envelope` 同款（`lang==null`）。

---

## 4. 落地时同步的文档与版本（CLAUDE.md 红线 6）

- `ARCH-engine.md`「字幕（`--transcript`）—— 一个动词，两种"字幕"，一个 `bili-resolve` 没有」：
  标题与整节要改 —— 它现在的论点是「B 站没有字幕轨，所以这个动词不存在」，落地后变成「视频没有，
  音频区有，所以这个动词只对 `au` 生效」；把 1.2 的实测表与 1.3 的覆盖率写进去（why 与 how，不抄
  字段清单）。「调用面」的示例块与被拒组合表各加一行。
- `ARCH-cli-contract.md`「命令规格」的动词面：`--transcript` 从「`yt-resolve` 与 `ne-resolve`」
  改成三个引擎，并注明 bili 侧只对音频区句柄生效；若 2.3 选了路 1，「数据契约」要写明
  `segments[].start` 可为 null。
- `ROADMAP.md`：删「B 站音频区（`au` 号）歌词管线打通」整条。
- `bili-resolve -h`：删「There is no --transcript」那段，写上新动词与它的限制（含 1.3 的实话）。
- **版本**：新动词是 CLI 契约的扩展 → 落地后**单独一次 commit** 做 SemVer minor bump，不与功能
  提交混杂（CLAUDE.md「环境与规范」）。
- 本文件蒸馏进 `ARCH-engine.md` 之后当场 `git rm`。
