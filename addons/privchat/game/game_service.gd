# game_service.gd — 通用游戏传输层(不绑定具体玩法)。
#
# 职责:在一个游戏频道(Room)上提供
#   - join/leave:带 ticket 的订阅生命周期
#   - send_command:Channel Transfer 指令封装,自动注入自增 request_id
#     作幂等键,统一返回 { ok, code, data, error }
#   - rpc:全局 RPC 透传(开局/结算等非频道操作)
#   - game_event 信号:服务端广播(SubscriptionMessageReceived)按频道分发,
#     按 server_message_id 去重(重连重放防抖)
#
# 棋牌模块与将来的 Menghuan 战斗模块都长在这层之上;战斗协议
# (battle_id/round/state_version)属于上层业务,不在本层。
class_name PrivchatGameService
extends Node

## 服务端游戏广播(已去重)。payload_text 为 UTF-8 文本(通常是 JSON,
## 上层自行 JSON.parse_string);raw payload 字节在 payload_bytes。
signal game_event(payload_text: String, payload_bytes: PackedByteArray,
		publisher: String, server_message_id: int, timestamp: int)
## 重连后自动重订阅游戏频道的结果;失败(如 ticket 过期)由业务重新签票再 join。
signal rejoined(ok: bool, error: String)

const ROOM_CHANNEL_TYPE := 2
# 去重集合封顶(spec §7.1)。
const SEEN_CAP := 4096
const SEEN_EVICT := 1024

var client: PrivchatClient = null
var game_channel_id: int = 0

var _ticket := ""
var _rejoining := false        # 重订阅 in-flight 闸门(状态抖动不叠加)
var _next_request_id: int = 1
var _seen_event_ids := {}      # server_message_id -> true


func setup(p_client: PrivchatClient) -> void:
	client = p_client
	if not client.sdk_event.is_connected(_on_sdk_event):
		client.sdk_event.connect(_on_sdk_event)
	if not client.connection_state_changed.is_connected(_on_connection_state):
		client.connection_state_changed.connect(_on_connection_state)


## 安全释放:切场景/离开牌桌时用 `await game.close()` 代替 queue_free()。
## 直接释放会让在途 await 的协程永远无法恢复(GDScriptFunctionState 泄漏)。
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


# --- 频道生命周期 -----------------------------------------------------------

func join(channel_id: int, ticket: String) -> Dictionary:
	var resp: Dictionary = await client.subscribe_channel(
			channel_id, ROOM_CHANNEL_TYPE, ticket)
	if resp.ok:
		game_channel_id = channel_id
		_ticket = ticket
	return resp


func leave() -> Dictionary:
	if game_channel_id == 0:
		return { "ok": true, "error": "", "data": null }
	var resp: Dictionary = await client.unsubscribe_channel(
			game_channel_id, ROOM_CHANNEL_TYPE)
	game_channel_id = 0
	_ticket = ""
	_seen_event_ids.clear()
	return resp


## 重连完成(→ Authenticated)后自动重订阅游戏频道(spec §7.1)。
## 状态抖动时只保留一次 in-flight 重订阅,避免订阅风暴。
func _on_connection_state(_from_state: String, to_state: String) -> void:
	if to_state != "Authenticated" or game_channel_id == 0 or _rejoining:
		return
	_rejoining = true
	var target := game_channel_id
	var resp: Dictionary = await client.subscribe_channel(
			target, ROOM_CHANNEL_TYPE, _ticket)
	if not is_instance_valid(self):
		return
	_rejoining = false
	if game_channel_id == target:
		rejoined.emit(resp.ok, str(resp.get("error", "")))


# --- 指令与 RPC -------------------------------------------------------------

## Channel Transfer 游戏指令。route 必须是 service/module/action 三段
## (如 "game/room/heartbeat");payload 自动注入 request_id 幂等键。
## 返回 { ok, code, data: Dictionary, error, request_id }。
func send_command(route: String, payload: Dictionary = {},
		timeout_ms: int = 8000) -> Dictionary:
	if game_channel_id == 0:
		return { "ok": false, "code": -1, "data": {}, "error": "not joined", "request_id": 0 }
	var request_id := _next_request_id
	_next_request_id += 1
	var body := payload.duplicate()
	body["request_id"] = request_id
	var resp: Dictionary = await client.transfer(
			game_channel_id, route, body, timeout_ms)
	return _parse_transfer(resp, request_id)


## 全局 RPC 透传(名字避开 Node 内建 rpc())。返回 { ok, data: Dictionary, error }。
func call_rpc(route: String, body: Dictionary = {}, timeout_ms: int = 8000) -> Dictionary:
	var resp: Dictionary = await client.rpc_call(route, body, timeout_ms)
	return {
		"ok": resp.ok,
		"data": resp.data if typeof(resp.data) == TYPE_DICTIONARY else {},
		"error": resp.get("error", ""),
	}


## transfer 信封:{"request_id","channel_id","code","message","data"}。
## 信封本身已由 native 层解析成 Dictionary;信封内的 data 是服务端业务
## 载荷 —— 协议层面是字节,UTF-8 JSON 时在这里解析成对象(本层是
## 载荷格式的收敛点,上层业务只见 Dictionary)。
func _parse_transfer(resp: Dictionary, request_id: int) -> Dictionary:
	var out := { "ok": false, "code": -1, "data": {}, "error": resp.get("error", ""),
			"request_id": request_id }
	if not resp.ok:
		return out
	var envelope = resp.data
	if typeof(envelope) != TYPE_DICTIONARY:
		out.error = "bad transfer envelope: %s" % str(envelope)
		return out
	out.code = int(envelope.get("code", -1))
	out.ok = out.code == 0
	if not out.ok:
		out.error = str(envelope.get("message", "transfer error"))
	var data = envelope.get("data", "")
	if typeof(data) == TYPE_STRING and not String(data).is_empty():
		var parsed = JSON.parse_string(data)
		if typeof(parsed) == TYPE_DICTIONARY:
			out.data = parsed
		else:
			out.data = { "raw": data }
	return out


# --- 事件分发 ---------------------------------------------------------------

func _on_sdk_event(_seq: int, _ts: int, kind: String, event: Dictionary) -> void:
	if kind != "SubscriptionMessageReceived":
		return
	var body = event.get("event", {}).get("SubscriptionMessageReceived", {})
	if typeof(body) != TYPE_DICTIONARY:
		return
	if int(body.get("channel_id", -1)) != game_channel_id:
		return
	var server_message_id: int = int(body.get("server_message_id", 0) \
			if body.get("server_message_id") != null else 0)
	if server_message_id != 0 and _seen_event_ids.has(server_message_id):
		return
	if server_message_id != 0:
		_seen_event_ids[server_message_id] = true
		if _seen_event_ids.size() > SEEN_CAP:
			var keys := _seen_event_ids.keys()
			for i in range(SEEN_EVICT):
				_seen_event_ids.erase(keys[i])
	var bytes := PackedByteArray()
	for b in body.get("payload", []):
		bytes.append(int(b))
	game_event.emit(bytes.get_string_from_utf8(), bytes,
			str(body.get("publisher", "")), server_message_id,
			int(body.get("timestamp", 0)))
