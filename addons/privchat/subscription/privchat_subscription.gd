# privchat_subscription.gd — 频道订阅原语(privchat-sdk subscribe/publish 的
# Godot 封装)。
#
# 职责只有订阅这一件事:
#   - subscribe/unsubscribe:带票据的订阅生命周期
#   - 记住频道与票据,重连(→ Authenticated)后自动重订阅
#   - 按频道过滤服务端广播并原样转发(含 topic)
#   - close():排空在途请求后安全释放
#
# 去重不在本层:privchat-sdk 已按 (channel_id, server_message_id) 去重
# (ROOM_CHANNEL_SPEC §P1-05,窗口 256),重复帧不会进入事件流;无 id 的
# 状态帧(如 presence_changed)由 SDK 单独消化。本层再去重既冗余,又会
# 误吞那些"每帧都要应用"的状态帧。
#
# 本类不认识任何业务语义(不知道频道里跑的是聊天、对局还是通知);
# 谁订阅什么频道、载荷怎么解释,全由调用方决定。
class_name PrivchatSubscription
extends Node

## 服务端广播(已按频道过滤;去重由 privchat-sdk 完成)。
## payload_text 为 UTF-8 文本视图,原始字节在 payload_bytes;
## topic 由服务端标注,调用方可据此分流(空字符串表示未标注)。
signal message_received(payload_text: String, payload_bytes: PackedByteArray,
		topic: String, publisher: String, server_message_id: int, timestamp: int)
## 重连后自动重订阅的结果;失败(如票据过期)由调用方重新签票再 subscribe。
signal resubscribed(ok: bool, error: String)
## 服务端定向推给本用户的 Channel Transfer(app→user,`POST /api/service/transfer/send`)。
## 与 message_received(Room 广播,人人可见)相对:这是只发给你的 PRIVATE 事件。
## payload_text 是 UTF-8 解码;二进制负载用 payload_bytes。
signal transfer_received(route: String, payload_text: String, payload_bytes: PackedByteArray,
		request_id: String)

## privchat-sdk 的 Room 频道类型(见 spec ROOM_CHANNEL_SPEC)。
const ROOM_CHANNEL_TYPE := 2

var client: PrivchatClient = null
var channel_id: int = 0
var channel_type: int = ROOM_CHANNEL_TYPE

var _ticket := ""
var _resubscribing := false    # 重订阅 in-flight 闸门(状态抖动不叠加)


func setup(p_client: PrivchatClient) -> void:
	client = p_client
	if not client.sdk_event.is_connected(_on_sdk_event):
		client.sdk_event.connect(_on_sdk_event)
	if not client.connection_state_changed.is_connected(_on_connection_state):
		client.connection_state_changed.connect(_on_connection_state)


## 安全释放:切场景时用 `await sub.close()` 代替 queue_free(),
## 否则在途 await 的协程永远无法恢复(GDScriptFunctionState 泄漏)。
func close(timeout_ms: int = 5000) -> void:
	if client != null:
		if client.sdk_event.is_connected(_on_sdk_event):
			client.sdk_event.disconnect(_on_sdk_event)
		if client.connection_state_changed.is_connected(_on_connection_state):
			client.connection_state_changed.disconnect(_on_connection_state)
		var deadline := Time.get_ticks_msec() + timeout_ms
		while client.inflight_count() > 0 and Time.get_ticks_msec() < deadline:
			await get_tree().process_frame
	queue_free()


# --- 订阅生命周期 -----------------------------------------------------------

func subscribe(p_channel_id: int, ticket: String,
		p_channel_type: int = ROOM_CHANNEL_TYPE) -> Dictionary:
	if client == null:
		return { "ok": false, "data": null, "error": "setup(client) not called" }
	var resp: Dictionary = await client.subscribe_channel(
			p_channel_id, p_channel_type, ticket)
	if resp.ok:
		channel_id = p_channel_id
		channel_type = p_channel_type
		_ticket = ticket
	return resp


func unsubscribe() -> Dictionary:
	if channel_id == 0:
		return { "ok": true, "data": null, "error": "" }
	var resp: Dictionary = await client.unsubscribe_channel(channel_id, channel_type)
	channel_id = 0
	_ticket = ""
	return resp


func is_subscribed() -> bool:
	return channel_id != 0


## 重连完成(→ Authenticated)后自动重订阅;状态抖动时只保留一次 in-flight。
func _on_connection_state(_from_state: String, to_state: String) -> void:
	if to_state != "Authenticated" or channel_id == 0 or _resubscribing:
		return
	_resubscribing = true
	var target := channel_id
	var resp: Dictionary = await client.subscribe_channel(target, channel_type, _ticket)
	# await 期间调用方可能已释放本节点。
	if not is_instance_valid(self):
		return
	_resubscribing = false
	# 返回前若已 unsubscribe,结果作废。
	if channel_id == target:
		resubscribed.emit(resp.ok, str(resp.get("error", "")))


# --- 事件分发 ---------------------------------------------------------------

func _on_sdk_event(_seq: int, _ts: int, kind: String, event: Dictionary) -> void:
	if kind == "TransferReceived":
		_on_transfer_received(event.get("event", {}).get("TransferReceived", {}))
		return
	if kind != "SubscriptionMessageReceived":
		return
	var body = event.get("event", {}).get("SubscriptionMessageReceived", {})
	if typeof(body) != TYPE_DICTIONARY:
		return
	if int(body.get("channel_id", -1)) != channel_id:
		return
	var server_message_id: int = int(body.get("server_message_id", 0) \
			if body.get("server_message_id") != null else 0)
	var bytes := PackedByteArray()
	for b in body.get("payload", []):
		bytes.append(int(b))
	message_received.emit(bytes.get_string_from_utf8(), bytes,
			str(body.get("topic", "") if body.get("topic") != null else ""),
			str(body.get("publisher", "")), server_message_id,
			int(body.get("timestamp", 0)))


func _on_transfer_received(body) -> void:
	if typeof(body) != TYPE_DICTIONARY or int(body.get("channel_id", -1)) != channel_id:
		return
	var bytes := PackedByteArray()
	for b in body.get("body", []):
		bytes.append(int(b))
	transfer_received.emit(str(body.get("route", "")), bytes.get_string_from_utf8(), bytes,
			str(body.get("request_id", "")))
