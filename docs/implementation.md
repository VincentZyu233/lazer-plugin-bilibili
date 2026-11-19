# 实现说明：宿主约束与踩坑记录

本文件记录把 B 站接口重写成 Lazer Lua 插件时，**实测**得到的宿主约束与由此产生的实现选择。所有结论都来自在真实发行版宿主里跑出来的行为，不是推测；遇到反直觉的地方都注明了成因。

---

## 1. Lua 运行时是残版 5.3

宿主用 `lua_dardo_plus` 解释 Lua，并裁掉了大量标准库与语法能力。

| 项目 | 实测行为 | 应对 |
| :--- | :--- | :--- |
| `io` / `os` / `package` / `debug` / `dofile` / `load` / `utf8` | 全部为 `nil` | 时间只能用 `host.now()`；无 `utf8.len` |
| `#s`（字符串长度运算符） | `attempt to get length of a string value` | 一律用 `string.len` |
| `%d` `%a` `%s` `%w` `%x` 等模式类 | 全部失效（返回 `nil`） | 用 `[0-9]` 这类字符集替代 |
| 捕获组 `(…)` 与 `%1` 反向引用 | 失效 | 不靠捕获组提取，改纯文本扫描 |
| `gsub` 第三参数为 function / table | 抛 `bad argument #3` | 只用字符串替换形式 |
| `find(s, pat, 1, true)` 纯文本模式 | 正常 | **主力解析手段** |

另有一条容易踩的：字符串在本运行时是 UTF-16 码元序列而非 UTF-8 字节，所以清洗一律按整段 `gsub` 处理，不做字节切片。中文字符的 `string.len` 结果等于字节数 / 3。

## 2. 指令预算 250 000 / 次调用

`invoke()` 通道每次调用有 250 000 条指令预算，超了抛 `408` 并**重建整个 Lua VM**（所有全局状态清零）。

- 逐行解析 300 行 LRC 就要 408 条指令量级，所以**不在 Lua 里拼 LRC 字符串**：歌词只返回结构化的 `lines[]`（`{text, startMs}`），时间轴由宿主合成。
- 搬运字幕能扛约 5 600 行；加 3 次 `gsub` 清洗后上限降到约 3 600 行，因此把字幕行数闸门定在 **1200 行**（3 倍余量）。

## 3. 只有 14 个 host API

v2.0.210 提供：`json_encode` / `json_decode` / `now` / `url_encode` / `random_hex` / `cookie_compact` / `cookie_field` / `cookie_merge` / `crypto` / `http` / `websocket` / `websocket_server` / `storage_get` / `storage_set`。

更新版本的源码树里出现的 `url_decode` / `log` / `sleep` / `timer` / `http_json` 等**不在**这个版本内，实现中一律不用。缺 `sleep` 意味着 412 风控只能返回错误让用户重试，不能自动退避。

`host.http` 的行为补充：

- 强制 HTTPS，非 https 直接 `Network permission denied`。
- 目标域必须精确匹配 `manifest.json` 的 `permissions.network`，或以 `*.` 开头的子域规则。
- `set-cookie` 需要自己从响应头读出来再合并（`http.absorb_set_cookie`），扫码登录正是靠这一步拿到登录态。

## 4. 返回值的类型桥接

Lua table 只有在键为连续整数 `1..N` 时才会被桥接成 Dart `List`；一旦混入字符串键，整张表变成 `Map`。宿主对列表型 op（`favorites` / `playlistSongs` / `artistSongs`）会做 `raw is! List` 检查，不满足即抛 `invalid payload`，界面整页报错。

所以列表型方法**必须返回纯数组表**，分页信息通过入参控制、不夹带在返回值里。

## 5. 三个真机才暴露的 bug

以下三个问题在离线测试里都过，只有真机才现形——记下来是因为它们的形态很有代表性。

### 5.1 扫码二维码渲染成废码

插件原本把二维码信息作为 Lua table 返回（`{hint=…, url=…}`）。宿主 2.0.300 的源码里有 `if (raw is Map)` 分支取 `raw['url']`，但**发行版 2.0.210 把 Lua table 桥接成非 Map 对象**，于是落到 `raw.toString()`，最终编码进二维码的是整个 table 的字符串，B 站 App 判「不支持的二维码」。

修复：`qr_url` 直接返回**纯 URL 字符串**。两个宿主流行版都走 `toString()`，行为一致。另外 `from` 参数必须补成 `main_web`，否则 App 侧同样判废码。

### 5.2 UP 主页「资料加载失败」

两个独立原因叠加：

- `/x/space/wbi/arc/search` 强制要求 `wts`，缺了必返 `412`。WBI 签名统一注入 `host.now()` 毫秒值即可。
- 宿主会调用 `artist` / `artistAlbums` 两个 op，早期实现没提供就直接报 unsupported。补齐后 `artist` 走 `/x/web-interface/card`，取不到时回退占位而不抛错。

### 5.3 评论正文为空

`/x/v2/reply` 的 `content` 是**对象**，正文在 `content.message`。早期代码把 `content` 当字符串取，拿到整个 table 再 `tostring` 成空串。修复时先判类型：table 取 `content.message`，字符串直接用，再回退 `item.message`。

对应的 fixture 也从「字符串」改成真实的嵌套对象结构——否则 fixture 会把 bug 掩盖成假阳性。

## 6. 歌词：为什么选站内字幕而不是第三方曲库

最初方案是用标题去 `lrclib` 精确检索，实测 6 个真实曲目**全部 0 命中**。三个叠加原因：

1. B 站标题是「歌手《曲名》+ 一堆频道后缀」的形态，直接送精确短语检索必然落空。
2. 即使清洗后命中，第三方曲库歌词与该视频的**时间轴也对不上**（曲库版时长与视频时长不同）。
3. 宿主会把空答复落盘成 `pureMusic:true` 的空壳并缓存，后续连插件都不会再调用。

改用视频自带的 `ai-zh` 字幕（`view` → `player/wbi/v2` → 字幕 CDN JSON 三步）：与视频同源，时间轴零误差，实测 6/6 命中且都在 1 秒内。`lrclib` 降级为极少数补充，且带时长闸门——对不上就干净返回空，不硬凑。

`/x/player/wbi/v2` 而不是 `/x/player/v2`：同一个 bvid 前者返回字幕列表，后者常常为空。

## 7. 时长字段：列表接口各不相同

不同接口给时长的字段名不一样，映射时必须逐条回退：

- `/x/web-interface/view` → `duration`（秒，数字）
- `/x/space/wbi/arc/search` 的 `vlist` → **`length`**（`"MM:SS"` 字符串），没有 `duration`
- 搜索/热门/排行 → `duration` 或 `length` 都可能出现

统一策略：`duration` → `length` → `duration_seconds` 依次回退，全部交给同一个 `parse_duration` 转毫秒。**不要**在拿到秒数后再乘一次 1000。

## 8. 收藏夹封面

`/x/v3/fav/folder/created/list-all` 返回的 folder **没有 cover 字段**（实测为空），只读 `cover`/`pic` 就只能画灰色占位符。修复：取不到时用 `/x/v3/fav/resource/list?ps=1&pn=1` 第一个视频的封面回填；资源列表本身为空则返回 nil，不编造。

## 9. 分页聚合

宿主问 100 行时，如果插件只给 50 行，宿主会判定为末页直接停住。`catalog.lua` 里的 `collect(load, limit, offset, cap, max_hops)` 聚合器负责：页内偏移、短页即末页、最多 6 跳。实测 684 条 UP 投稿 8 次调用读全，`offset` 越过总数后返回 0 行、`hasMore=false`。
