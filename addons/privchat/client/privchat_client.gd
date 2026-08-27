# privchat_client.gd
#
# GDScript facade over the PrivchatNativeClient GDExtension. Owns the
# native client + platform auth client, exposes awaitable methods and
# forwarded signals.
#
# 序列化边界:JSON 字符串只存在于 native ↔ C ABI 一线(在 C++ 里
# stringify/parse 各一次)。本层及以上出入参、信号、返回值全部是
# Dictionary / Array / 标量 —— GDScript 不接触 JSON 文本。
class_name PrivchatClient
extends Node

## SDK 事件(event 为已解析的 SequencedSdkEvent Dictionary)。
signal sdk_event(sequence_id: int, timestamp_ms: int, kind: String, event: Dictionary)
signal connection_state_changed(from_state: String, to_state: String)
signal message_sent(request_id: int, ok: bool, message_id: int, error: String)

# TaskKind ordinals — must match PrivchatNativeClient::TaskKind.
const KIND_AUTHENTICATE := 0
const KIND_CONNECT := 1
const KIND_DISCONNECT := 2
const KIND_SHUTDOWN := 3
const KIND_SUBSCRIBE := 4
const KIND_UNSUBSCRIBE := 5
const KIND_SEND_TEXT := 6
const KIND_TRANSFER := 7
const KIND_RPC_CALL := 8
const KIND_SYNC_CHANNEL := 9
const KIND_GET_MESSAGE_BY_ID := 10
const KIND_BOOTSTRAP_SYNC := 11
const KIND_OPEN_CONVERSATION := 12
const KIND_LOAD_OLDER_HISTORY := 13
const KIND_LIST_MESSAGES := 14
const KIND_LIST_CHANNELS := 15
const KIND_MARK_READ_TO_PTS := 16
const KIND_CHANNEL_UNREAD := 17
const KIND_TOTAL_UNREAD := 18

## IM server endpoint. Local dev default matches privchat-sdk's own default.
var server_host: String = "127.0.0.1"
var server_port: int = 9001
## "Tcp" | "Quic" | "WebSocket"
var transport: String = "Tcp"
var use_tls: bool = false
var ws_path: String = "/"
var connection_timeout_secs: int = 10
## Local SDK data dir (SQLite etc.); user:// is globalized before use.
var data_dir: String = "user://privchat-data"
## privchat-application route-group root (auth / game HTTP APIs).
var application_base_url: String = "http://127.0.0.1:8080/app"

var native: Node = null            # PrivchatNativeClient (GDExtension class)
var auth: PrivchatPlatformAuthClient = null

var logged_in_user_id: int = -1
var logged_in_device_id: String = ""

var _results: Dictionary = {}      # request_id -> result Dictionary


func _ready() -> void:
	_ensure_auth()


func _ensure_auth() -> PrivchatPlatformAuthClient:
	# Lazy init so await chains work even before _ready() runs.
	if auth == null:
		auth = PrivchatPlatformAuthClient.new()
		auth.base_url = application_base_url
		add_child(auth)
	return auth


## Create the native SDK client. Must be called before authenticate.
func start() -> bool:
	if native != null:
		return true
	native = ClassDB.instantiate("PrivchatNativeClient")
	if native == null:
		push_error("[privchat] PrivchatNativeClient class not found — is the GDExtension loaded?")
		return false
	add_child(native)
	native.sdk_event.connect(_on_sdk_event)
	native.connection_state_changed.connect(_on_connection_state_changed)
	native.message_sent.connect(_on_message_sent)
	native.request_completed.connect(_on_request_completed)

	var config := {
		"endpoints": [{
			"protocol": transport,
			"host": server_host,
			"port": server_port,
			"path": ws_path if transport == "WebSocket" else null,
			"use_tls": use_tls,
		}],
		"connection_timeout_secs": connection_timeout_secs,
		"data_dir": ProjectSettings.globalize_path(data_dir),
	}
	var ok: bool = native.initialize(config)
	if not ok:
		push_error("[privchat] native initialize failed")
	return ok


func stop() -> void:
	if native != null:
		native.shutdown()


## Full platform login: sms-login HTTP -> authenticate -> connect.
## Returns { ok, error, user_id }.
func login(mobile: String, sms_code: String) -> Dictionary:
	if not await _ensure_started():
		return { "ok": false, "error": "native client init failed", "user_id": -1 }

	var device := PrivchatPlatformAuthClient.default_device_info()
	var login_resp: Dictionary = await _ensure_auth().login_with_sms(mobile, sms_code, device)
	if not login_resp.ok:
		return { "ok": false, "error": login_resp.error, "user_id": -1 }
	var data: Dictionary = login_resp.data

	var auth_result: Dictionary = await authenticate(
			int(data.user_id), data.access_token, data.device_id)
	if not auth_result.ok:
		return { "ok": false, "error": "authenticate: " + auth_result.error, "user_id": int(data.user_id) }

	var connect_result: Dictionary = await connect_im()
	if not connect_result.ok:
		return { "ok": false, "error": "connect: " + connect_result.error, "user_id": int(data.user_id) }

	# 本地优先门禁（对标 TS SDK 登录后的 bootstrapChannels）：
	# 未完成前 send/create 等本地操作会被 SDK 拒绝。
	var bootstrap_result: Dictionary = await bootstrap_sync()
	if not bootstrap_result.ok:
		return { "ok": false, "error": "bootstrap: " + bootstrap_result.error, "user_id": int(data.user_id) }

	logged_in_user_id = int(data.user_id)
	logged_in_device_id = data.device_id
	return { "ok": true, "error": "", "user_id": logged_in_user_id }


func send_sms_code(mobile: String) -> Dictionary:
	return await _ensure_auth().send_sms_code(mobile)


# ---------------------------------------------------------------------------
# awaitable native operations (return { ok, data, error })
# data: 已解析的 Dictionary / Array / null,永远不是 JSON 字符串
# ---------------------------------------------------------------------------

func authenticate(user_id: int, access_token: String, device_id: String,
		timeout_ms: int = 15000) -> Dictionary:
	var rid: int = native.authenticate(user_id, access_token, device_id, timeout_ms)
	return await _await_request(rid)


func connect_im(timeout_ms: int = 15000) -> Dictionary:
	var rid: int = native.connect_async(timeout_ms)
	return await _await_request(rid)


func disconnect_im(timeout_ms: int = 10000) -> Dictionary:
	var rid: int = native.disconnect_async(timeout_ms)
	return await _await_request(rid)


## Bootstrap sync gate：authenticate+connect 后、任何本地优先操作
## （发消息等）之前必须完成，对标 TS SDK 的 bootstrapChannels。
func bootstrap_sync(timeout_ms: int = 30000) -> Dictionary:
	var rid: int = native.run_bootstrap_sync(timeout_ms)
	return await _await_request(rid)


func subscribe_channel(channel_id: int, channel_type: int, token: String = "",
		timeout_ms: int = 10000) -> Dictionary:
	var rid: int = native.subscribe_channel(channel_id, channel_type, token, timeout_ms)
	return await _await_request(rid)


func unsubscribe_channel(channel_id: int, channel_type: int,
		timeout_ms: int = 10000) -> Dictionary:
	var rid: int = native.unsubscribe_channel(channel_id, channel_type, timeout_ms)
	return await _await_request(rid)


## Queue-first text send; resolves when the local message is enqueued.
## Delivery progress arrives via sdk_event (MessageSendStatusChanged).
func send_text(channel_id: int, channel_type: int, content: String,
		timeout_ms: int = 10000) -> Dictionary:
	var rid: int = native.send_text_message(channel_id, channel_type,
			logged_in_user_id, content, timeout_ms)
	return await _await_request(rid)


## Channel Transfer。body 是 Dictionary;返回 { ok, data, error },
## data 为 transfer 信封 {"request_id","channel_id","code","message","data"}。
func transfer(channel_id: int, route: String, body: Dictionary,
		timeout_ms: int = 8000) -> Dictionary:
	var rid: int = native.transfer(channel_id, route, body, timeout_ms)
	return await _await_request(rid)


## 全局 RPC。body 是 Dictionary;返回 { ok, data, error },data 为服务端响应对象。
func rpc_call(route: String, body: Dictionary, timeout_ms: int = 8000) -> Dictionary:
	var rid: int = native.rpc_call(route, body, timeout_ms)
	return await _await_request(rid)


func sync_channel(channel_id: int, channel_type: int, timeout_ms: int = 15000) -> Dictionary:
	var rid: int = native.sync_channel(channel_id, channel_type, timeout_ms)
	return await _await_request(rid)


## 返回 { ok, data: StoredMessage Dictionary | null, error }。
func get_message_by_id(message_id: int, timeout_ms: int = 8000) -> Dictionary:
	var rid: int = native.get_message_by_id(message_id, timeout_ms)
	return await _await_request(rid)


## Direct-channel helper mirroring privchat-sdk-ffi
## get_or_create_direct_channel: rpc + one-shot channel sync.
func get_or_create_direct_channel(peer_user_id: int) -> Dictionary:
	var resp: Dictionary = await rpc_call("channel/direct/get_or_create", {
		"target_user_id": peer_user_id,
		"source": null,
		"source_id": null,
		"user_id": 0,
	})
	if not resp.ok:
		return resp
	if typeof(resp.data) != TYPE_DICTIONARY or not resp.data.has("channel_id"):
		return { "ok": false, "data": resp.data, "error": "unexpected direct-channel response" }
	var channel_id: int = int(resp.data.channel_id)
	var sync_result: Dictionary = await sync_channel(channel_id, 1)
	if not sync_result.ok:
		return sync_result
	return { "ok": true, "data": resp.data, "error": "", "channel_id": channel_id }


# ---------------------------------------------------------------------------
# conversation history / channel list / read state (local-first)
# ---------------------------------------------------------------------------

## 打开会话(SDK-HISTORY-7):本地为渲染真源,本地为空补一次最新窗口。
## 返回 { ok, error, messages: Array(显示序 DESC), has_more_before, fetched_from_server }。
func open_conversation(channel_id: int, channel_type: int, limit: int = 50,
		timeout_ms: int = 10000) -> Dictionary:
	var rid: int = native.open_conversation(channel_id, channel_type, limit, timeout_ms)
	return _page_view(await _await_request(rid))


## 上滑加载更早历史(SDK-HISTORY-5);has_more_before=false 即到顶(跨会话持久化)。
func load_older_history(channel_id: int, channel_type: int,
		before_server_message_id: int, limit: int = 50,
		timeout_ms: int = 10000) -> Dictionary:
	var rid: int = native.load_older_history(channel_id, channel_type,
			before_server_message_id, limit, timeout_ms)
	return _page_view(await _await_request(rid))


## 纯本地分页读(不触网)。返回 { ok, error, messages: Array }。
func list_messages(channel_id: int, channel_type: int, limit: int = 50,
		offset: int = 0, timeout_ms: int = 8000) -> Dictionary:
	var rid: int = native.list_messages(channel_id, channel_type, limit, offset, timeout_ms)
	var result: Dictionary = await _await_request(rid)
	result.messages = result.data if typeof(result.data) == TYPE_ARRAY else []
	return result


## 本地会话列表;条目自带 unread_count/top/mute/last_msg_timestamp/last_msg_content。
## 返回 { ok, error, channels: Array }(已按 top 优先、last_msg_timestamp 降序排序)。
func list_channels(limit: int = 50, offset: int = 0, timeout_ms: int = 8000) -> Dictionary:
	var rid: int = native.list_channels(limit, offset, timeout_ms)
	var result: Dictionary = await _await_request(rid)
	var channels: Array = result.data if typeof(result.data) == TYPE_ARRAY else []
	channels.sort_custom(func(a, b):
		if int(a.get("top", 0)) != int(b.get("top", 0)):
			return int(a.get("top", 0)) > int(b.get("top", 0))
		return int(a.get("last_msg_timestamp", 0)) > int(b.get("last_msg_timestamp", 0)))
	result.channels = channels
	return result


## 已读游标推进:RPC 上报 + 本地投影。返回 { ok, error, last_read_pts: int }。
func mark_read_to_pts(channel_id: int, read_pts: int,
		timeout_ms: int = 8000) -> Dictionary:
	var rid: int = native.mark_read_to_pts(channel_id, read_pts, timeout_ms)
	var result: Dictionary = await _await_request(rid)
	result.last_read_pts = _data_int(result, "last_read_pts")
	return result


## 单频道未读数(本地)。返回 { ok, error, count: int }。
func get_channel_unread_count(channel_id: int, channel_type: int,
		timeout_ms: int = 8000) -> Dictionary:
	var rid: int = native.get_channel_unread_count(channel_id, channel_type, timeout_ms)
	var result: Dictionary = await _await_request(rid)
	result.count = _data_int(result, "count")
	return result


## 全局未读角标(本地)。返回 { ok, error, count: int }。
func get_total_unread_count(exclude_muted: bool = false,
		timeout_ms: int = 8000) -> Dictionary:
	var rid: int = native.get_total_unread_count(exclude_muted, timeout_ms)
	var result: Dictionary = await _await_request(rid)
	result.count = _data_int(result, "count")
	return result


# --- sync getters -----------------------------------------------------------

func connection_state(timeout_ms: int = 2000) -> String:
	if native == null:
		return ""
	return native.connection_state_sync(timeout_ms)


func session_snapshot(timeout_ms: int = 2000) -> Dictionary:
	if native == null:
		return {}
	return native.session_snapshot_sync(timeout_ms)


func recent_events(limit: int = 50) -> Array:
	if native == null:
		return []
	return native.recent_events_sync(limit)


# ---------------------------------------------------------------------------
# internals
# ---------------------------------------------------------------------------

func _ensure_started() -> bool:
	if native != null:
		return true
	return start()


## { messages, has_more_before, fetched_from_server } 分页视图。
func _page_view(result: Dictionary) -> Dictionary:
	var page: Dictionary = result.data if typeof(result.data) == TYPE_DICTIONARY else {}
	result.messages = page.get("messages", [])
	result.has_more_before = bool(page.get("has_more_before", false))
	result.fetched_from_server = bool(page.get("fetched_from_server", false))
	return result


func _data_int(result: Dictionary, key: String) -> int:
	if typeof(result.data) == TYPE_DICTIONARY:
		return int(result.data.get(key, 0))
	return 0


func _await_request(rid: int) -> Dictionary:
	while not _results.has(rid):
		await get_tree().process_frame
	var result: Dictionary = _results[rid]
	_results.erase(rid)
	return result


func _on_request_completed(request_id: int, _kind: int, ok: bool,
		data, error: String) -> void:
	_results[request_id] = { "ok": ok, "data": data, "error": error }


func _on_sdk_event(sequence_id: int, timestamp_ms: int, kind: String,
		event: Dictionary) -> void:
	sdk_event.emit(sequence_id, timestamp_ms, kind, event)


func _on_connection_state_changed(from_state: String, to_state: String) -> void:
	connection_state_changed.emit(from_state, to_state)


func _on_message_sent(request_id: int, ok: bool, message_id: int, error: String) -> void:
	# SendText 结果以本信号为准（native 先发 request_completed 再发本信号，
	# 这里覆盖补齐 message_id，否则 send_text 的 await 永远拿不到结果）。
	_results[request_id] = { "ok": ok, "data": null, "error": error,
			"message_id": message_id }
	message_sent.emit(request_id, ok, message_id, error)
