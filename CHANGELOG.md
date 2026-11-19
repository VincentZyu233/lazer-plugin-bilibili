# 📦 哔哩哔哩插件更新日志 (CHANGELOG)

本文件记录 `community.bilibili.music`（哔哩哔哩 Lua 插件）的版本演进。

---

## 🚀 v0.1.0 (2026-11-18) - 首个公开版本

### ✨ 能力

- **扫码 / Cookie 双登录**：`qrKey` → `qrUrl` → `qrCheck` 全链路；`poll` 返回 `code=0` 时从 `Set-Cookie` 吸收全套登录态并持久化，扫码即登录，无需手动复制 Cookie。Cookie 粘贴作兜底。
- **WBI 签名搜索**：`w_rid = md5(query + salt)`，salt 按 MIX 表取前 32 位；`/x/space/wbi/arc/search` 强制注入 `wts`。视频与 UP 主双桶检索。
- **音频流**：`playurl` 自动选最高音质，支持 `original` / `flac`；每路响应带 `Referer`（裸请求必 403）。
- **歌词**：站内 `ai-zh` 字幕三步主源（`view` → `player/wbi/v2` → 字幕 CDN），返回逐行 `lines[]` 交宿主合成时间轴；`lrclib` 作为带时长闸门的兜底。
- **发现与收藏**：首页热门、全站排行、相关推荐、UP 主投稿、评论；收藏夹、夹内曲目、红心同步。
- **分页聚合**：宿主问 100 行就给 100 行，短页判末页、最多 6 跳。

### 🐛 缺陷修复（均在真机复现后修复）

- **二维码渲染成废码**：`qrUrl` 原返回 Lua table，发行版宿主把 table 桥接成非 Map 对象后走 `toString()`，编码进二维码的是整个 table 字符串，B 站 App 判「不支持的二维码」。改为返回纯 URL 字符串，并补 `from=main_web`。
- **UP 主页「资料加载失败」**：两个独立原因——WBI 缺 `wts` 必返 `412`；`artist` / `artistAlbums` 两个 op 未实现被宿主判 unsupported。分别补签名注入与 op 实现。
- **评论正文为空**：`/x/v2/reply` 的 `content` 是对象，正文在 `content.message`；原实现当字符串取，拿到 table 后 `tostring` 成空串。改为先判类型再回退。
- **UP「全部歌曲」无时长**：`vlist` 的时长字段是 `length`（`"MM:SS"` 字符串），没有 `duration`。统一回退链补 `length`，并修掉「秒数先乘 1000 又乘一次」的重复换算。
- **收藏夹封面灰色占位**：`fav/folder/created/list-all` 返回的 folder 没有 cover 字段。改为回退第一个视频的封面，取不到则返回 nil 不编造。
- **歌词 0 命中**：原方案用裸标题查第三方曲库，6 个真实曲目全空。改用站内字幕主源后 6/6 命中且均在 1 秒内。

### ⚙️ 宿主适配

- 针对残版 Lua 5.3：不用 `#s`、不用 `%d/%s` 模式类、不用捕获组、不用函数式 `gsub`；全部改 `string.len` + 纯文本 `find(s, pat, 1, true)` + `[0-9]` 字符集。
- 针对 250 000 指令预算：歌词不在 Lua 内拼 LRC，只回结构化 `lines[]`；字幕闸门 1200 行。
- 仅使用 v2.0.210 提供的 14 个 host API。
- 列表型 op 严格返回纯数组表，不夹带分页字段（否则宿主桥接成 Map 直接 `invalid payload`）。

### ✅ 验证

- 离线契约测试 **20/20 全绿**：`describe`、WBI 签名搜索、详情、音质选择与 `Referer`、字幕歌词 `lines[]`、扫码纯 URL 与 `803`、收藏夹默认夹标记、`setFavorite` csrf、四个发现 op、UP 投稿 100 行聚合与 `length→durationMs`、`-352/-412` 映射、封面回退、指令预算门、未知 op 结构化错误。
- 真机 GUI 走通：扫码登录、搜索起播、歌词显示、收藏夹封面、UP 投稿时长、评论正文。
- ZIP 12 文件，根目录 `manifest.json`，约 22 KB。

### ⚠️ 已知限制

- 只取音频流（`m4s`），不含视频画面；音质靠 `quality` 参数，v2.0.210 无插件设置页扩展点。
- 歌词主源与 UP 投稿需登录态；8 小时以上合集截断 1200 行。
- 搜索页仍是 4 tab，专辑 / 歌单为空（B 站无对应数据层）。
- 风控 `-412` 返回结构化错误，不自动重试。
