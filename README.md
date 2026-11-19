# 🎵 Lazer Bilibili Music Plugin (哔哩哔哩插件)

把 **B 站当作曲库**的 [Lazer](https://github.com/chuxuehaocai/Lazer) Lua 插件：搜索、播放、歌词、收藏夹、排行榜、热门、相关推荐、UP 主投稿、评论、扫码 / Cookie 登录。

纯 Lua 实现，无原生依赖，打包体积约 **22 KB**，运行在 Lazer 的隔离 Lua 插件沙箱里。

---

## ✨ 特性

- **扫码 / Cookie 双登录**：插件登录框点扫码 → B 站 App 确认即完成登录，登录态自动持久化；Cookie 粘贴作兜底。
- **搜索（WBI 签名）**：视频与 UP 主双桶检索，`w_rid` / `wts` 按官方 WBI 规则实时签名。
- **音频流**：`playurl` 自动选最高音质，可指定 `original` / `flac`；每路响应都带 `Referer`，裸请求必 403。
- **歌词**：以视频自带的 `ai-zh` 字幕为主源（与视频同源、时间轴零误差），返回逐行 `lines[]` 交宿主合成；`lrclib` 仅作兜底。
- **发现**：首页热门、全站排行、相关推荐、UP 主投稿（自动翻页读全）、评论区。
- **收藏**：本人收藏夹、默认收藏夹喜欢列表、加/取消喜欢（`csrf=bili_jct`）。
- **错误归一**：上游错误码统一映射成宿主可读状态，失败只回状态码，不泄露响应正文 / Cookie / 签名 URL。

---

## 📦 安装

### 方式一：Release ZIP

1. 打开本仓库的 [Releases](../../releases)，下载最新的 `community.bilibili.music.zip`。
2. Lazer → 设置 → 插件管理 → **导入 ZIP 插件**，选择该文件（**不要解压后改目录结构**，ZIP 根目录必须是 `manifest.json`）。
3. 列表出现「哔哩哔哩」并启用；首次联网会弹出网络授权，需要允许。
4. 在播放器音源切换列表选择「哔哩哔哩」。

### 方式二：本地构建

```bash
node tools/build.js        # 产出 dist/community.bilibili.music.zip + SHA-256
```

---

## 🔑 登录

| 方式 | 步骤 |
| :--- | :--- |
| **扫码**（推荐） | 登录框点扫码 → 用哔哩哔哩 App 扫二维码 → 在 App 里确认。扫码成功后 `poll` 的 `Set-Cookie` 会下发全套登录态，插件自动保存。 |
| **Cookie**（兜底） | 浏览器登录 `www.bilibili.com` → 开发者工具复制完整 Cookie（必须含 `SESSDATA` 与 `bili_jct`）→ 粘贴进登录框。 |

> 扫码报「不支持的二维码」时，先**重新打开登录页生成新码**（`qrcode_key` 有时效，复用旧码必然失败），再试 Cookie 登录。

---

## 🧩 操作契约

插件入口返回 `call(operation, args)`，实现了 Lazer v2.0.210 提供的以下操作：

| 分类 | 操作 |
| :--- | :--- |
| 元信息 | `describe` |
| 登录 | `qrKey` / `qrUrl` / `qrCheck`（800/801/802/803） / `loginCookie` / `session` / `logout` |
| 曲库 | `search` / `song` / `stream` / `lyrics` / `homeFeed` / `charts` / `recommendations` / `comments` |
| 歌单 | `playlists` / `playlistSongs` / `favorites` / `setFavorite` / `artist` / `artistSongs` / `artistAlbums` |

错误码归一：`-101/-400/401/301/302 → 40 → HTTP 401`；`-352 → 40 → 401`（提示登录）；`-412/412 → 429`（风控限流）；未知 op 返回结构化 `error` 而不崩。

---

## 🛠 源码结构

```text
manifest.json        id / provider / 能力 / 网络白名单
main.lua             操作路由、错误归一、media 规则
bili/util.lua        纯文本切分、时长解析、标题清洗（无 % 模式类、无 #string）
bili/store.lua       持久化 Cookie + 内存 session / QR 态
bili/http.lua        host.http 包装：UA / Referer、buvid、set-cookie 吸收、错误映射
bili/wbi.lua         WBI salt 缓存与签名（w_rid = md5(query + salt)，注入 wts）
bili/models.lua      响应 → 客户端模型映射
bili/auth.lua        session / 扫码 / Cookie 登录 / logout
bili/catalog.lua     搜索、详情、歌单、发现、评论、封面回填、分页聚合
bili/stream.lua      playurl → 音质选择 + Referer 头
bili/lyrics.lua      ai-zh 字幕三步主源 → lines[]，lrclib 兜底
```

实现中遇到的关键宿主约束（残版 Lua 5.3、250 000 指令预算、只有 14 个 host API）与踩坑结论，见 [docs/implementation.md](docs/implementation.md)。

---

## ✅ 测试

离线契约测试共 **20 个 test**：用 `LuaPluginRuntime` 加载真实的 `manifest.json` + `.lua`，把确定性 JSON fixture 从 `httpHandler` 喂进去，全程不联网。

```bash
# 本仓库没有 pubspec.yaml，借 Lazer 源码树的 flutter 环境跑：
cp test/plugin_contract_test.dart <Lazer>/test/plugin_contract_test.dart
cd <Lazer>
PLUGIN_ROOT=/path/to/lazer-plugin-bilibili flutter test test/plugin_contract_test.dart
```

覆盖：`describe`、WBI 签名搜索、详情、音质选择与 `Referer`、字幕歌词 `lines[]`、扫码纯 URL 与 `803`、收藏夹默认夹标记、`setFavorite` 的 csrf、四个发现 op、UP 投稿 100 行聚合与 `length→durationMs`、`-352/-412` 错误映射、收藏夹封面回退、指令预算门、未知 op 结构化错误。

---

## ⚠️ 已知限制

- 只取音频流（`m4s`），不含视频画面；音质靠 `quality` 参数，v2.0.210 无插件设置页扩展点。
- 歌词主源依赖登录态；匿名时歌词不可用、UP 主页提示登录。8 小时以上的合集只取前 1200 行。
- UP 投稿与收藏夹在插件内自动翻页，首次打开需数秒；之后走宿主缓存。
- 高频访问可能触发 B 站风控（`-412`），插件返回结构化错误，不自动重试。
- 搜索页仍是 4 个 tab，其中专辑 / 歌单为空——B 站没有对应「专辑」层，收成 2 tab 需要改宿主 UI。
- 宿主 401 的统一文案是「请检查用户名和密码」，用于扫码场景略别扭，文案在宿主内写死。

---

## 🔒 隐私

`Cookie` / `SESSDATA` 仅保存在插件的 `lua_plugin_data` 存储沙箱，用于维持登录态。所有失败只返回状态码，不包含响应正文、Cookie 或签名 URL。

---

## 💖 鸣谢与参考来源

- [chuxuehaocai/Lazer](https://github.com/chuxuehaocai/Lazer) —— 宿主。插件的 `manifest` 契约、host API 集合、`lines[]` 歌词协议、错误码语义全部以它的实际行为为准。
- [licpp/BiliMusic-Desktop](https://github.com/licpp/BiliMusic-Desktop) —— **B 站接口与 WBI 签名的参考实现**。本插件的接口路径、参数与签名规则对照本项目（Tauri + Rust）的实现重写；插件是独立的 Lua 代码，不含其源码。
- [SocialSisterYi/bilibili-API-collect](https://github.com/SocialSisterYi/bilibili-API-collect) —— B 站 Web 接口的公开文档，用于核对 WBI 与登录流程。

---

## 📄 许可证

本项目遵循 MIT 协议开源，见 [LICENSE](LICENSE)。仅供技术学习与交流；音频内容版权归哔哩哔哩及相应版权方所有。
