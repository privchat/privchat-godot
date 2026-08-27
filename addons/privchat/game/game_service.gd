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

const ROOM_CHANNEL_TYPE := 2

var client: PrivchatClient = null
var game_channel_id: int = 0

var _next_request_id: int = 1
var _seen_event_ids := {}      # server_message_id -> true


func setup(p_client: PrivchatClient) -> void:
	client = p_client
	if not client.sdk_event.is_connected(_on_sdk_event):
		client.sdk_event.connect(_on_sdk_event)


# --- 频道生命周期 -----------------------------------------------------------

func join(channel_id: int, ticket: String) -> Dictionary:
	var resp: Dictionary = await client.subscribe_channel(
			channel_id, ROOM_CHANNEL_TYPE, ticket)
	if resp.ok:
		game_channel_id = channel_id
	return resp


func leave() -> Dictionary:
	if game_channel_id == 0:
		return { "ok": true, "error": "", "payload": "" }
	var resp: Dictionary = await client.unsubscribe_channel(
			game_channel_id, ROOM_CHANNEL_TYPE)
	game_channel_id = 0
	_seen_event_ids.clear()
	return resp


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
			game_channel_id, route, JSON.stringify(body), timeout_ms)
	return _parse_transfer(resp, request_id)


## 全局 RPC 透传(名字避开 Node 内建 rpc())。返回 { ok, data: Dictionary, error }。
func call_rpc(route: String, body: Dictionary = {}, timeout_ms: int = 8000) -> Dictionary:
	var resp: Dictionary = await client.rpc_call(route, JSON.stringify(body), timeout_ms)
	var out := { "ok": resp.ok, "data": {}, "error": resp.get("error", "") }
	if resp.ok and not String(resp.payload).is_empty():
		var parsed = JSON.parse_string(resp.payload)
		if typeof(parsed) == TYPE_DICTIONARY:
			out.data = parsed
	return out


## transfer 回包:{"request_id","channel_id","code","message","data"};
## data 为 UTF-8 时是字符串(通常是 JSON 文本),否则是字节数组。
func _parse_transfer(resp: Dictionary, request_id: int) -> Dictionary:
	var out := { "ok": false, "code": -1, "data": {}, "error": resp.get("error", ""),
			"request_id": request_id }
	if not resp.ok:
		return out
	var envelope = JSON.parse_string(resp.payload)
	if typeof(envelope) != TYPE_DICTIONARY:
		out.error = "bad transfer envelope: %s" % str(resp.payload)
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

func _on_sdk_event(_seq: int, _ts: int, kind: String, event_json: String) -> void:
	if kind != "SubscriptionMessageReceived":
		return
	var parsed = JSON.parse_string(event_json)
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	var body = parsed.get("event", {}).get("SubscriptionMessageReceived", {})
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
	var bytes := PackedByteArray()
	for b in body.get("payload", []):
		bytes.append(int(b))
	game_event.emit(bytes.get_string_from_utf8(), bytes,
			str(body.get("publisher", "")), server_message_id,
			int(body.get("timestamp", 0)))
