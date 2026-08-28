# chat_service.gd — 面向 UI 的 IM 会话服务(单会话上下文)。
#
# 职责:把 PrivchatClient 的低层 awaitable + sdk_event 流,收敛成一个
# 频道视角的聊天 API:打开会话(local-first 历史)、上滑翻页、发送、已读、
# 未读数、会话列表;事件按当前频道过滤后以强类型信号发出。
#
# 用法:
#   var chat := PrivchatChatService.new()
#   add_child(chat)
#   chat.setup(client)
#   var page := await chat.open(channel_id, 1)
#   chat.message_received.connect(_on_message)
class_name PrivchatChatService
extends Node

## 当前会话收到新消息(已从本地时间线取到完整 StoredMessage)。
signal message_received(message: Dictionary)
## 当前会话内本端消息投递状态变化(status: 0=queued/1=sent/2=delivered...)。
signal send_status_changed(message_id: int, status: int, server_message_id: int)
## Room 广播(已按 server_message_id 去重)。
signal room_message(payload_text: String, publisher: String, server_message_id: int)
## 当前会话未读数变化(收到新消息 / mark_read 之后)。
signal unread_changed(channel_id: int, count: int)
## 重连后自动重订阅 Room 的结果;失败(如 ticket 过期)由业务重新签票再 join。
signal room_rejoined(ok: bool, error: String)

# 去重集合封顶(spec §7.1):超限批量淘汰最旧,超长在线不无界增长。
const SEEN_CAP := 4096
const SEEN_EVICT := 1024

var client: PrivchatClient = null
var channel_id: int = 0
var channel_type: int = 1
var room_channel_id: int:
	get: return _sub.channel_id if _sub != null else 0

var _sub: PrivchatSubscription = null   # Room 订阅原语(懒建)
var _seen_timeline := {}       # "channel:message_id" -> true


func setup(p_client: PrivchatClient) -> void:
	client = p_client
	if not client.sdk_event.is_connected(_on_sdk_event):
		client.sdk_event.connect(_on_sdk_event)


## 安全释放:切场景/退出会话时用 `await chat.close()` 代替 queue_free()。
## 直接释放会让在途 await 的协程永远无法恢复(GDScriptFunctionState 泄漏);
## 这里先断开信号、排空在途请求,再释放节点。
func close(timeout_ms: int = 5000) -> void:
	if client != null:
		if client.sdk_event.is_connected(_on_sdk_event):
			client.sdk_event.disconnect(_on_sdk_event)
		var deadline := Time.get_ticks_msec() + timeout_ms
		while client.inflight_count() > 0 and Time.get_ticks_msec() < deadline:
			await get_tree().process_frame
	queue_free()


# --- 会话生命周期 -----------------------------------------------------------

## 打开会话:本地为渲染真源,本地为空时 SDK 补一次最新窗口(SDK-HISTORY-7)。
## 返回 { ok, error, messages, has_more_before, fetched_from_server }。
func open(p_channel_id: int, p_channel_type: int, limit: int = 50) -> Dictionary:
	channel_id = p_channel_id
	channel_type = p_channel_type
	return await client.open_conversation(channel_id, channel_type, limit)


## 上滑加载更早历史;has_more_before=false 即到顶(SDK 持久化水位)。
func load_older(before_server_message_id: int, limit: int = 50) -> Dictionary:
	return await client.load_older_history(channel_id, channel_type,
			before_server_message_id, limit)


## queue-first 发送;投递进度经 send_status_changed 信号到达。
func send_text(content: String) -> Dictionary:
	return await client.send_text(channel_id, channel_type, content)


## 已读推进到 read_pts;成功后刷新并广播未读数。
func mark_read(read_pts: int) -> Dictionary:
	var resp: Dictionary = await client.mark_read_to_pts(channel_id, read_pts)
	if resp.ok:
		var unread: Dictionary = await client.get_channel_unread_count(channel_id, channel_type)
		if unread.ok:
			unread_changed.emit(channel_id, unread.count)
	return resp


func unread_count() -> Dictionary:
	return await client.get_channel_unread_count(channel_id, channel_type)


## 会话列表(已按 top 优先、last_msg_timestamp 降序排序;条目带 unread_count)。
func channel_list(limit: int = 50, offset: int = 0) -> Dictionary:
	return await client.list_channels(limit, offset)


# --- 频道订阅(委托给通用订阅原语)-------------------------------------------
# Room 订阅本身与"聊天"无关,统一由 PrivchatSubscription 承担:
# 订阅生命周期、重连自动重订阅、按 server_message_id 去重都在那里实现。

func join_room(p_room_channel_id: int, ticket: String) -> Dictionary:
	return await _ensure_sub().subscribe(p_room_channel_id, ticket)


func leave_room() -> Dictionary:
	if _sub == null:
		return { "ok": true, "error": "", "data": null }
	return await _sub.unsubscribe()


func _ensure_sub() -> PrivchatSubscription:
	if _sub == null:
		_sub = PrivchatSubscription.new()
		add_child(_sub)
		_sub.setup(client)
		_sub.message_received.connect(_on_subscription_message)
		_sub.resubscribed.connect(func(ok, err): room_rejoined.emit(ok, err))
	return _sub


func _on_subscription_message(payload_text: String, _bytes: PackedByteArray,
		publisher: String, server_message_id: int, _timestamp: int) -> void:
	room_message.emit(payload_text, publisher, server_message_id)


# --- 事件分发 ---------------------------------------------------------------

func _on_sdk_event(_seq: int, _ts: int, kind: String, event: Dictionary) -> void:
	match kind:
		"TimelineUpdated":
			_handle_timeline(event)
		"MessageSendStatusChanged":
			_handle_send_status(event)


func _handle_timeline(event: Dictionary) -> void:
	var body := _event_body(event, "TimelineUpdated")
	if int(body.get("channel_id", -1)) != channel_id:
		return
	# 只把「新消息落库」转成 message_received;sync/回执等 reason 不重复弹消息。
	if str(body.get("reason", "")) != "realtime_message":
		return
	var message_id: int = int(body.get("message_id", 0))
	if message_id <= 0:
		return
	var key := "%d:%d" % [channel_id, message_id]
	if _seen_timeline.has(key):
		return
	_remember(_seen_timeline, key)
	var resp: Dictionary = await client.get_message_by_id(message_id)
	# await 期间宿主可能已切场景释放本节点。
	if not is_instance_valid(self):
		return
	if resp.ok and typeof(resp.data) == TYPE_DICTIONARY:
		message_received.emit(resp.data)
	var unread: Dictionary = await client.get_channel_unread_count(channel_id, channel_type)
	if unread.ok:
		unread_changed.emit(channel_id, unread.count)


func _handle_send_status(event: Dictionary) -> void:
	var body := _event_body(event, "MessageSendStatusChanged")
	if body.is_empty():
		return
	send_status_changed.emit(int(body.get("message_id", 0)),
			int(body.get("status", 0)),
			int(body.get("server_message_id", 0) if body.get("server_message_id") != null else 0))


## 记入去重集合,超限批量淘汰最旧(Godot Dictionary 保持插入序)。
func _remember(seen: Dictionary, key) -> void:
	seen[key] = true
	if seen.size() > SEEN_CAP:
		var keys := seen.keys()
		for i in range(SEEN_EVICT):
			seen.erase(keys[i])


## 外部标签枚举:{"event":{"Kind":{...}}};unit 变体是 {"event":"Kind"}。
func _event_body(event: Dictionary, kind: String) -> Dictionary:
	var ev = event.get("event", {})
	if typeof(ev) != TYPE_DICTIONARY:
		return {}
	var body = ev.get(kind, {})
	return body if typeof(body) == TYPE_DICTIONARY else {}
