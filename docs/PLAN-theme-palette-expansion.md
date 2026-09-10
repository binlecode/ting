# PLAN-theme-palette-expansion —— 主题调色板扩容与多语义色彩系统重塑

> **Status**: 草案 (Draft) · 架构与完整实施规约就绪，准备实施  
> **Priority**: P2（视觉表现力与终端个性化重大升级）  
> **Target Branch**: main  
> **Roadmap 关联**: 人机交互面（TUI）质感升级专项，解决主题高度同质化与单色相偏执问题  
> **Governing Docs**: [`docs/ARCH-tui.md`](ARCH-tui.md)「唯一视图的渲染」「主题与色彩」、[`docs/ARCHITECTURE.md`](ARCHITECTURE.md)「人机面」、[`docs/ARCH-cli-contract.md`](ARCH-cli-contract.md)「配置面」  
> **Verification**: `tests/contract.sh` 主题自反性门禁测试、`tests/drive.sh` 13 主题无缝轮换测试、`bash -n shell/uting`、`shellcheck`

---

## 1. 现状问题与设计根因审计 (Problem Audit)

### 1.1 现状硬伤：主题高度同质化（“千人一面”）
目前 `shell/uting` 内置的合法主题集合（行 750 `THEME_NAMES`）为：
```text
minimal  mono  catppuccin  tokyonight  nord  gruvbox  onedark  custom
```
除去纯黑白的 `mono` 和自定占位 `custom`，在 6 个内置彩色主题中：
- `minimal`：青/蓝（ANSI 36/34）
- `tokyonight`：暴风蓝 (`#7aa2f7` / `122;162;247`)
- `nord`：冰霜蓝 (`#88c0d0` / `136;192;208`)
- `onedark`：经典蓝 (`#61afef` / `97;175;239`)
- 仅有 `catppuccin`（紫）和 `gruvbox`（土橙）不是蓝色。
用户在按 `t` 键轮换主题时，连续 4 个主题均为高度近似的冷蓝/青色，缺乏实质色彩跳跃，风格极度单一。

### 1.2 架构根因：“单色相偏执（Single-Hue Obsession）”
查阅 `shell/uting:944-960` 及 `docs/ARCH-tui.md`，此前版本为避免“主题非绿色时播放状态显示绿色导致撞色”，执行了一次极端的单色化收敛：
- **全面废除了第二色相**：彻底删除了 `C_GREEN` 与 `C_YELLOW` 变量；
- **全屏强行统一为单一变量 `C_CYAN`**：播放状态、暂停状态、进度条轨道、光标指示、按键高亮全部共用同一个 `C_CYAN`；
- 导致全屏 95% 为灰白普通文本，仅剩 5% 的零星单色高亮，界面极其扁平、缺乏层次感与呼吸感。

---

## 2. 核心架构与边界原则 (Non-Negotiable Invariants)

在进行色彩系统全面升级时，必须绝对恪守以下技术红线：

1. **bash 3.2 兼容性（无关联数组查找）**：
   - 严禁引入 bash 4+ 的关联数组（`declare -A`）；
   - 主题多角色色彩派发统一走 `case "$THEME:$BG"` 的高效纯函数分支计算，零多余子进程 fork，零性能开销。
2. **三级色彩优雅降级（Graceful Degradation）**：
   - **Level 1 (TrueColor 24-bit)**：当检测到 `COLORTERM=truecolor` 或 `24bit` 时，精确发射官方 24 位 RGB 转义码（`\033[38;2;R;G;Bm` 与 `\033[48;2;R;G;Bm`）；
   - **Level 2 (ANSI-16 Fallback)**：老旧终端或不支持 TrueColor 时，精准回退至精选的最佳 ANSI-16 颜色索引（31-36），确保色彩不丢失、不变乱码；
   - **Level 3 (NO_COLOR / `--color never` / 非 TTY)**：严格静默，所有色彩变量自动清空为 `""`，仅保留字形属性（`bold`/`dim`）与反色，坚守 Unix 环境规范。
3. **自反性契约严格对齐（The Contract Lockstep）**：
   - `THEME_NAMES`、`usage()` 中的 `--theme` 参数说明行、`usage()` 中的 `YT_THEME=` 说明行，必须与 `tests/contract.sh:1540-1549` 的门禁测试保持 100% 逐字对应，确保自动化测试绝对不红。

---

## 3. 主题矩阵扩容规格 (13 大主题全家桶)

引入现代开发者生态中最受推崇的 6 个顶级主题，形成涵盖**冷蓝、哥特紫粉、自然森绿、水墨东方、复古暖金、高对比代码高亮**的完备风格矩阵：

### 3.1 全主题色卡与官方 Hex 对齐表

| 主题名称 (`THEME`) | 视觉风格 | 主色调 Accent (暗/浅) | 播放态 Play (绿) | 暂停态 Pause (黄) | 次要色 Muted (灰) | ANSI-16 (暗/浅) |
|---|---|---|---|---|---|---|
| **`minimal`** | 终端原生极简 | 系统原生 Cyan / Blue | ANSI 32 (绿) | ANSI 33 (黄) | ANSI 37 (暗白) | `36` / `34` |
| **`mono`** | 纯粹黑白灰度 | 无色相 (纯靠 Bold) | 无色相 (Bold) | 无色相 (Dim) | 无色相 (Dim) | `1` (Bold) |
| **`catppuccin`** | 柔和粉紫马卡龙 | `#cba6f7` / `#8839ef` | `#a6e3a1` / `#40a02b` | `#f9e2af` / `#df8e1d` | `#6c7086` / `#9ca0b0` | `35` / `35` |
| **`tokyonight`** | 暴风霓虹深蓝 | `#7aa2f7` / `#2e7de9` | `#9ece6a` / `#587539` | `#e0af68` / `#8c6c3e` | `#565f89` / `#848cb5` | `34` / `34` |
| **`nord`** | 极地冰霜冷蓝 | `#88c0d0` / `#5e81ac` | `#a3be8c` / `#8fbcbb` | `#ebcb8b` / `#d08770` | `#4c566a` / `#d8dee9` | `36` / `36` |
| **`onedark`** | 经典 Atom 蓝 | `#61afef` / `#4078f2` | `#98c379` / `#50a14f` | `#e5c07b` / `#c18401` | `#5c6370` / `#a0a1a7` | `34` / `34` |
| **`gruvbox`** | 复古大地暖橙 | `#d65d0e` / `#af3a03` | `#b8bb26` / `#79740e` | `#fabd2f` / `#b57614` | `#928374` / `#7c6f64` | `33` / `31` |
| **`dracula`** ✦ | 暗夜哥特高饱和 | `#bd93f9` / `#6272a4` | `#50fa7b` / `#50fa7b` | `#f1fa8c` / `#ffb86c` | `#6272a4` / `#44475a` | `35` / `35` |
| **`rosepine`** ✦ | 优雅独立玫瑰粉 | `#ebbcba` / `#b4637a` | `#31748f` / `#286983` | `#f6c177` / `#ea9d34` | `#6e6a86` / `#908caa` | `35` / `35` |
| **`everforest`** ✦| 护眼温润自然绿 | `#a7c080` / `#8da101` | `#83c092` / `#35a77c` | `#e69875` / `#f57d00` | `#859289` / `#7fbbb3` | `32` / `32` |
| **`kanagawa`** ✦ | 浮世绘东方水墨 | `#e46876` / `#76946a` | `#76946a` / `#6f894e` | `#e6c384` / `#c4746e` | `#727169` / `#a6a69c` | `31` / `32` |
| **`solarized`** ✦ | 经典光能冷暖双模 | `#2aa198` / `#b58900` | `#859900` / `#859900` | `#b58900` / `#cb4b16` | `#657b83` / `#93a1a1` | `36` / `33` |
| **`monokai`** ✦ | 活力代码高亮黄 | `#e6db74` / `#e6db74` | `#a6e22e` / `#a6e22e` | `#fd971f` / `#fd971f` | `#75715e` / `#75715e` | `33` / `33` |
| **`custom`** | 自由用户定义 | `UT_ACCENT` 指定 | 自动协调 | 自动协调 | 自动协调 | 由输入语法指定 |

*(注：带 ✦ 为本计划全新加入的顶级现代主题)*

---

## 4. 语义色彩角色架构设计 (Semantic Roles System)

彻底打破全屏只有 `C_CYAN` 的限制，建立六维语义角色：

```bash
# 核心语义色彩变量（在 set_theme 中统一派发，无色模式下全自动置空）
C_RESET       # 属性重置 (\033[0m)
C_BOLD        # 加粗高亮 (\033[1m)
C_DIM         # 次要灰度 (\033[2m)
C_ACCENT      # 主强调色（光标条 ▎、当前焦点曲名、进度条已播高光）
C_PLAY        # 播放中活跃色（▶ 状态图标、PLAYING 胶囊）
C_PAUSE       # 暂停/警示色（❚❚ 状态图标、PAUSED 胶囊、30s 试听）
C_MUTED       # 弱化轨道色（全宽进度条未播细线、时间刻度、滚动条滑道）
C_BG_SURF     # 选中行微光底色（TrueColor 下极淡暗底 \033[48;2;...m）
```

---

## 5. 详细实施规格 (Implementation Spec)

### 5.1 常量与门控更新 (`shell/uting`)

#### 1. 扩展 `THEME_NAMES`（行 750）
```bash
THEME_NAMES="minimal mono catppuccin tokyonight nord gruvbox onedark dracula rosepine everforest kanagawa solarized monokai custom"
```

#### 2. 更新 `usage()` 描述文本（行 534–536 与行 612）
精确保持契约闭环，防止 `tests/contract.sh` 报错：
```bash
# 行 534:
  --theme NAME  Palette: minimal (default) | mono | catppuccin | tokyonight | nord
                | gruvbox | onedark | dracula | rosepine | everforest | kanagawa
                | solarized | monokai | custom. Every theme = signature accent,
                play/pause semantic roles and gray hierarchy; mono = gray hierarchy
                only, no hue. Community themes emit 24-bit color when
                COLORTERM=truecolor, else ANSI-16 fallbacks. custom takes its accent
                from UT_ACCENT (below) and is minimal when that is unset.

# 行 612:
  YT_THEME=minimal|mono|catppuccin|tokyonight|nord|gruvbox|onedark|dracula|rosepine|everforest|kanagawa|solarized|monokai|custom
```

#### 3. 更新 `config` 默认轮换列表（行 96）
```bash
UT_THEME_CYCLE=minimal catppuccin tokyonight nord gruvbox onedark dracula rosepine everforest kanagawa solarized monokai mono
```

### 5.2 调色板引擎升级 (`set_theme`)

修改 `shell/uting:1050-1080`：
为 13 个主题分别注入精确的 RGB 24 位色与 ANSI 16 回退代码：

```bash
set_theme() {
    local acc_r acc_g acc_b a16
    local play_r play_g play_b play_16
    local pause_r pause_g pause_b pause_16
    local bg_r=0 bg_g=0 bg_b=0 has_bg=0

    case "$THEME" in
    minimal)
        accent_minimal
        if ((COLORS_ON)); then
            C_PLAY=$'\033[32m'; C_PAUSE=$'\033[33m'; C_MUTED=$'\033[2m'
        fi
        ;;
    mono)
        C_CYAN=''; C_MARK=$'\033[1m'; C_PLAY=$'\033[1m'; C_PAUSE=$'\033[2m'; C_MUTED=$'\033[2m'
        ;;
    custom)
        local spec="${UT_ACCENT:-}"
        [[ "$BG" == light && -n "${UT_ACCENT_LIGHT:-}" ]] && spec="${UT_ACCENT_LIGHT:-}"
        if [[ -n "$spec" ]]; then
            accent_from_spec "$spec"
        else
            accent_minimal
        fi
        if ((COLORS_ON)); then
            C_PLAY=$'\033[32m'; C_PAUSE=$'\033[33m'; C_MUTED=$'\033[2m'
        fi
        ;;
    catppuccin | tokyonight | nord | gruvbox | onedark | dracula | rosepine | everforest | kanagawa | solarized | monokai)
        case "$THEME:$BG" in
        catppuccin:dark)
            acc_r=203; acc_g=166; acc_b=247; a16=35
            play_r=166; play_g=227; play_b=161; play_16=32
            pause_r=249; pause_g=226; pause_b=175; pause_16=33
            bg_r=30; bg_g=30; bg_b=46; has_bg=1 ;;
        catppuccin:light)
            acc_r=136; acc_g=57;  acc_b=239; a16=35
            play_r=64;  play_g=160; play_b=43;  play_16=32
            pause_r=223; pause_g=142; pause_b=29; pause_16=33 ;;
        tokyonight:dark)
            acc_r=122; acc_g=162; acc_b=247; a16=34
            play_r=158; play_g=206; play_b=106; play_16=32
            pause_r=224; pause_g=175; pause_b=104; pause_16=33
            bg_r=26; bg_g=27; bg_b=38; has_bg=1 ;;
        tokyonight:light)
            acc_r=46;  acc_g=125; acc_b=233; a16=34
            play_r=88;  play_g=117; play_b=57;  play_16=32
            pause_r=140; pause_g=108; pause_b=62; pause_16=33 ;;
        nord:dark)
            acc_r=136; acc_g=192; acc_b=208; a16=36
            play_r=163; play_g=190; play_b=140; play_16=32
            pause_r=235; pause_g=203; pause_b=139; pause_16=33
            bg_r=46; bg_g=52; bg_b=64; has_bg=1 ;;
        nord:light)
            acc_r=94;  acc_g=129; acc_b=172; a16=36
            play_r=143; play_g=188; play_b=187; play_16=32
            pause_r=208; pause_g=135; pause_b=112; pause_16=33 ;;
        gruvbox:dark)
            acc_r=214; acc_g=93;  acc_b=14;  a16=33
            play_r=184; play_g=187; play_b=38;  play_16=32
            pause_r=250; pause_g=189; pause_b=47;  pause_16=33
            bg_r=40; bg_g=40; bg_b=40; has_bg=1 ;;
        gruvbox:light)
            acc_r=175; acc_g=58;  acc_b=3;   a16=31
            play_r=121; play_g=116; play_b=14;  play_16=32
            pause_r=181; pause_g=118; pause_b=20;  pause_16=33 ;;
        onedark:dark)
            acc_r=97;  acc_g=175; acc_b=239; a16=34
            play_r=152; play_g=195; play_b=121; play_16=32
            pause_r=229; pause_g=192; pause_b=123; pause_16=33
            bg_r=40; bg_g=44; bg_b=52; has_bg=1 ;;
        onedark:light)
            acc_r=64;  acc_g=120; acc_b=242; a16=34
            play_r=80;  play_g=161; play_b=79;  play_16=32
            pause_r=193; pause_g=132; pause_b=1;   pause_16=33 ;;
        dracula:dark | dracula:light)
            acc_r=189; acc_g=147; acc_b=249; a16=35
            play_r=80;  play_g=250; play_b=123; play_16=32
            pause_r=241; pause_g=250; pause_b=140; pause_16=33
            bg_r=40; bg_g=42; bg_b=54; has_bg=1 ;;
        rosepine:dark)
            acc_r=235; acc_g=188; acc_b=186; a16=35
            play_r=49;  play_g=116; play_b=143; play_16=36
            pause_r=246; pause_g=193; pause_b=119; pause_16=33
            bg_r=31; bg_g=29; bg_b=46; has_bg=1 ;;
        rosepine:light)
            acc_r=180; acc_g=99;  acc_b=122; a16=35
            play_r=40;  play_g=105; play_b=131; play_16=36
            pause_r=234; pause_g=157; pause_b=52;  pause_16=33 ;;
        everforest:dark)
            acc_r=167; acc_g=192; acc_b=128; a16=32
            play_r=131; play_g=192; play_b=146; play_16=36
            pause_r=230; pause_g=152; pause_b=117; pause_16=33
            bg_r=45; bg_g=53; bg_b=59; has_bg=1 ;;
        everforest:light)
            acc_r=141; acc_g=161; acc_b=1;   a16=32
            play_r=53;  play_g=167; play_b=124; play_16=36
            pause_r=245; pause_g=125; pause_b=0;   pause_16=33 ;;
        kanagawa:dark)
            acc_r=228; acc_g=104; acc_b=118; a16=31
            play_r=118; play_g=148; play_b=106; play_16=32
            pause_r=230; pause_g=195; pause_b=132; pause_16=33
            bg_r=31; bg_g=31; bg_b=40; has_bg=1 ;;
        kanagawa:light)
            acc_r=200; acc_g=64;  acc_b=83;  a16=31
            play_r=111; play_g=137; play_b=78;  play_16=32
            pause_r=196; pause_g=116; pause_b=110; pause_16=33 ;;
        solarized:dark | solarized:light)
            acc_r=42;  acc_g=161; acc_b=152; a16=36
            play_r=133; play_g=153; play_b=0;   play_16=32
            pause_r=181; pause_g=137; pause_b=0;   pause_16=33
            [[ "$BG" == dark ]] && { bg_r=7; bg_g=54; bg_b=66; has_bg=1; } ;;
        monokai:dark | monokai:light)
            acc_r=230; acc_g=219; acc_b=116; a16=33
            play_r=166; play_g=226; play_b=46;  play_16=32
            pause_r=253; pause_g=151; pause_b=31;  pause_16=33
            bg_r=39; bg_g=40; bg_b=34; has_bg=1 ;;
        esac

        if ((COLORTERM_TC)); then
            printf -v C_CYAN '\033[38;2;%d;%d;%dm' "$acc_r" "$acc_g" "$acc_b"
            printf -v C_MARK '\033[1;38;2;%d;%d;%dm' "$acc_r" "$acc_g" "$acc_b"
            printf -v C_PLAY '\033[38;2;%d;%d;%dm' "$play_r" "$play_g" "$play_b"
            printf -v C_PAUSE '\033[38;2;%d;%d;%dm' "$pause_r" "$pause_g" "$pause_b"
            if ((has_bg)); then
                printf -v C_BG_SURF '\033[48;2;%d;%d;%dm' "$bg_r" "$bg_g" "$bg_b"
            else
                C_BG_SURF=''
            fi
        else
            C_CYAN=$'\033['"$a16"m
            C_MARK=$'\033[1;'"$a16"m
            C_PLAY=$'\033['"$play_16"m
            C_PAUSE=$'\033['"$pause_16"m
            C_BG_SURF=''
        fi
        ;;
    esac
}
```

### 5.3 渲染调用点联动

1. **Now Playing 状态图标与徽章**：
   - 播放中（Playing）：使用 `${C_PLAY}▶${C_RESET}`；
   - 暂停中（Paused）：使用 `${C_PAUSE}❚❚${C_RESET}`；
2. **进度分割线**：
   - 已播轨道采用 `${C_CYAN}`；
   - 游标点采用 `${C_BOLD}${C_CYAN}●${C_RESET}`；
   - 未播轨道采用 `${C_DIM}─${C_RESET}`；
3. **列表选中行**：
   - 行首竖线强调条输出 `${C_CYAN}▎ ${C_RESET}`；
   - 当 `C_BG_SURF` 非空时，行内文本附加该背景色，脱离刺眼的粗暴反白。

---

## 6. 验证矩阵与回归判据

### 6.1 契约自反性测试（必须一枪过）
运行 `tests/contract.sh`：
- 确保 `usage()'s --theme list == the gate's` 测试项完全通过（门禁、参数、帮助字符串 100% 吻合）；
- 确保 `usage()'s YT_THEME list == the gate's` 测试项完全通过。

### 6.2 实时循环切换验证
运行 `tests/drive.sh`：
- 连续按 13 次 `t` 键，遍历所有 13 个主题，验证每一个主题生效时屏幕色彩平滑切换，无报错、无闪退、无配置写回异常。

### 6.3 静态分析与无损保障
- `bash -n shell/uting` 语法检查全绿；
- `shellcheck --severity=warning shell/uting` 保持原 16 处误报基线，净增 0。
