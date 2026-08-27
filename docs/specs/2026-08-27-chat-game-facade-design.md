# chat/ + game/ Facade 里程碑设计

> ⚠️ 过程文档(里程碑设计快照,已实施完毕)。常青权威 spec 见
> `privchat-docs/spec/04-client/GODOT_SDK_SPEC.md`(SSOT);两者冲突时以后者为准。

日期:2026-08-27
状态:已与用户确认方向(通用游戏传输层 + 游戏内聊天;未读数纳入;无搜索/撤回/置顶/附件)
范围:privchat-sdk(c-api)、privchat-godot、privchat-godot-demo 三仓库

## 背景与目标

privchat-godot 的 `addons/privchat/chat/` 与 `game/` 目前是空目录。本里程碑将其填实,
为 Menghuan(梦幻西游类回合制)客户端提供:游戏内聊天(世界/队伍频道 + 私聊,含未读
数与会话列表)和通用游戏数据传输(指令 + 事件流)。

原则:
- **C ABI 只镜像 UniFFI 层已验证的函数,严格跟随 SDK 的 local-first / pts 架构**,
  不发明新语义(用户明确要求)。
- game/ 不绑定具体玩法:棋牌模块与将来的 Menghuan 战斗模块都在其上生长;
  Menghuan 战斗协议(battle_id/round/state_version)写在 Menghuan 仓库,不在本层。
- 明确不做:消息搜索、撤回、置顶、附件(游戏 MVP 不需要)。
- 当前 C ABI 不承诺最终稳定(原型验收标准);函数命名与 JSON 形状仍可在
  接入 Menghuan 前调整。

## 一、C ABI 新增(privchat-sdk-c-api,7 个函数)

全部沿用现有风格:opaque handle + 标量 + UTF-8 JSON 字符串,`timeout_ms=0` 表示默认
30s,错误走返回码 + `privchat_capi_last_error`。JSON 形状 = 对应 UniFFI View 结构的
serde 直出。

| C 函数 | 镜像的 UniFFI 方法 | 返回 |
|---|---|---|
| `privchat_capi_open_conversation(h, channel_id, channel_type, limit, timeout_ms)` | `open_conversation` | JSON `{messages:[StoredMessage], has_more_before, fetched_from_server}`;本地为渲染真源,本地为空补一次最新窗口,空会话返回空列表 |
| `privchat_capi_load_older_history(h, channel_id, channel_type, before_server_message_id, limit, timeout_ms)` | `load_older_history` | JSON `{messages, has_more_before}`;gap 水位由 SDK 持久化,`has_more_before=false` 即到顶 |
| `privchat_capi_list_messages(h, channel_id, channel_type, limit, offset, timeout_ms)` | `list_messages` | JSON `[StoredMessage]`;纯本地分页 |
| `privchat_capi_get_channel_list_entries(h, page, page_size, timeout_ms)` | `get_channel_list_entries` | JSON `[StoredChannel]`;自带 `unread_count/top/mute/last_msg_timestamp/last_msg_content`,UI 据此排序+角标 |
| `privchat_capi_mark_read_to_pts(h, channel_id, read_pts, timeout_ms, out_last_read_pts)` | `mark_read_to_pts` | RPC 上报 + 本地 read cursor 投影;out 参数返回服务端确认的 `last_read_pts` |
| `privchat_capi_get_channel_unread_count(h, channel_id, channel_type, timeout_ms, out_count)` | `get_channel_unread_count` | 单频道未读(进出会话时刷新) |
| `privchat_capi_get_total_unread_count(h, exclude_muted, timeout_ms, out_count)` | `get_total_unread_count` | 全局未读角标 |

配套:header 声明 + `header_declares_every_export` 清单 + offline 单测(NULL/无效参数
/空库路径)+ `capi_full` 示例扩展(见测试节)。

## 二、privchat-godot:native 层扩展

`PrivchatNativeClient` 新增 7 个 TaskKind(OpenConversation、LoadOlderHistory、
ListMessages、ChannelList、MarkReadToPts、ChannelUnread、TotalUnread),沿用现有
worker 线程模型:任务队列 → worker 阻塞调 C ABI → 结果队列 → `_process()` 泄水 →
signal。主线程零阻塞。GDScript 侧 `privchat_client.gd` 增加对应 KIND 常量与 awaitable
方法。

## 三、privchat-godot:chat/ 模块

`addons/privchat/chat/chat_service.gd`(Node,注入 PrivchatClient):

- `open(channel_id, channel_type, limit=50) -> {messages, has_more_before}`
- `load_older(before_server_message_id, limit=50)`
- `send_text(content) -> message_id`(沿用 queue-first 语义)
- `mark_read(read_pts)`、`unread_count()`
- `channel_list(page, page_size)`(排序:top 优先,再按 last_msg_timestamp 降序 ——
  与 StoredChannel 字段直接对应)
- 信号:`message_received(msg: Dictionary)`(按当前频道过滤 TimelineUpdated →
  get_message_by_id 取全文)、`send_status_changed(message_id, status)`、
  `unread_changed(channel_id, count)`
- Room 世界频道:`join_room(channel_id, ticket)` / `leave_room()`,
  广播以 `room_message(payload: PackedByteArray, publisher, server_message_id)` 发出

## 四、privchat-godot:game/ 模块(通用传输层)

`addons/privchat/game/game_service.gd`(不新增 C ABI):

- `join(channel_id, ticket)` / `leave()` — Room 订阅封装
- `send_command(route, payload: Dictionary, timeout_ms) -> Dictionary` — transfer 封装,
  自动注入自增 `request_id` 作幂等键,await 应答,超时/错误统一返回 `{ok, code, data, error}`
- `game_event(payload, server_message_id, timestamp)` 信号 — `SubscriptionMessageReceived`
  按频道分发,按 `server_message_id` 去重(重连重放防抖)
- `rpc(route, body) -> Dictionary` — 全局 RPC 透传(开局/结算等非频道操作)

## 五、privchat-godot-demo

- chat 场景改用 ChatService:进入显示历史(open_conversation)、上滑加载更早、
  发送、已读、菜单页会话列表带未读角标
- 新增 headless e2e:
  - `auto_chat_check.gd`:A→B 发若干条 → B open_conversation 校验历史与顺序 →
    B mark_read → 校验 unread 归零 → A 收 PeerReadPtsAdvanced(如事件可见)
  - `auto_game_check.gd`:join room → send_command 到 module-game 的
    GameTransferHandler 路由做指令回环(路由不可用则退化为服务端广播回环)→
    校验 game_event 去重与顺序
- 提交现存未提交改动(watchdog 修复、重建的 dylib)

## 六、测试与验收

```text
cargo test -p privchat-sdk-c-api      通过(含 7 个新函数 offline 测试)
capi_full                             EXAMPLE_OK(新增:发消息后 open_conversation
                                      校验历史、mark_read_to_pts 校验 last_read_pts、
                                      unread 先非零后归零)
auto_comm_check / auto_chat_check / auto_game_check   VERIFY_OK
退出无 ObjectDB 泄漏警告
共享服务端(privchat-server/-application)只读使用,不改动、不重启
```

## 七、非目标(本里程碑不做)

- 消息搜索、撤回、置顶、附件/媒体
- 事件/配置 JSON 的 schema_version(留待"稳定 ABI"批次,连同 cbindgen、
  cpp_smoke、跨平台构建)
- Menghuan 战斗协议与任何玩法逻辑
- typing 指示、群管理、好友关系(SDK 有,游戏 MVP 不需要)

## 实施顺序

1. c-api 7 函数 + 单测 + capi_full 扩展(先跑到 EXAMPLE_OK)
2. native TaskKind + privchat_client.gd 方法
3. chat_service.gd + auto_chat_check.gd(跑到 VERIFY_OK)
4. game_service.gd + auto_game_check.gd(跑到 VERIFY_OK)
5. demo UI 场景接入(chat 场景 + 菜单未读角标)
6. 三仓库分别提交
