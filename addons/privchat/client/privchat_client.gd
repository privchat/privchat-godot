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
## 登录态不可自愈(ForcedLogout):宿主须清理登录态并回登录页。
signal session_expired(code: int, message: String, source: String)
## access token 需刷新(AccessTokenRefreshNeeded)。默认已由本类自动接管
## (single-flight refresh → authenticate);宿主一般只需监听 auth_recovered。
signal token_refresh_needed(code: int, message: String)
## 一次 token 恢复流程的结果(刷新 + 重新 authenticate)。
signal auth_recovered(ok: bool, error: String)
## 会话终结、必须回登录页:refresh token 失效/被撤销,或服务端强制登出。
## 发出前登录态已清理;**不会**再自动重试,避免无限刷新循环。
signal logout_required(code: int, reason: String)

# TaskKind ordinals — must match PrivchatNativeClient::TaskKind.
const KIND_AUTHENTICATE := 0
const KIND_CONNECT := 1
const KIND_DISCONNECT := 2
const KIND_SHUTDOWN := 3
const KIND_SUBSCRIBE := 4
const KIND_UNSUBSCRIBE := 5
const KIND_SEND_TEXT := 6
const KIND_TRANSFER := 7
const KIND_TRANSFER_BYTES := 19
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
## 由 login() 保存;宿主自管 token 时也可直接赋值。SDK 层永不上送它,
## 只交给 token_provider(见下)——契约见 spec TOKEN_REFRESH_SPEC §3。
var refresh_token_value: String = ""

## Token 来源 adapter(可替换)。签名:
##   func(refresh_token: String, device_id: String) -> Dictionary
##   返回 { ok, data: { user_id, access_token, refresh_token }, error, terminal }
## 留空时用默认的 PrivchatApplicationAuthProvider(模式 B,平台 member 模块)。
## 模式 C(业务后台自有 token 体系)由宿主赋值覆盖 —— core 只做编排,
## 不把任何一条 refresh 路径写死为核心职责。
var token_provider: Callable = Callable()

var _default_provider: PrivchatApplicationAuthProvider = null

var _refreshing := false           # single-flight 闸门
var _auth_generation: int = 0      # 登录代际:旧刷新结果不得覆盖新会话
var _logout_broadcast := false     # 同一代际内 logout_required 只广播一次

var _results: Dictionary = {}      # request_id -> result Dictionary
var _abandoned: Dictionary = {}    # request_id -> true(已超时,结果迟到即丢弃)
var _inflight: int = 0             # 在途 await 数(供服务安全释放前排空)


## 当前在途请求数。宿主/服务在释放前可据此排空,避免协程状态泄漏。
func inflight_count() -> int:
	return _inflight


## 未 start() 就调用时的统一失败返回:降级为错误,不得崩溃。
func _not_started() -> Dictionary:
	return { "ok": false, "data": null, "error": "client not started (call start() first)" }


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
	refresh_token_value = str(data.get("refresh_token", ""))
	_auth_generation += 1   # 新会话:此前在途的刷新结果作废
	return { "ok": true, "error": "", "user_id": logged_in_user_id }


func send_sms_code(mobile: String) -> Dictionary:
	return await _ensure_auth().send_sms_code(mobile)


# ---------------------------------------------------------------------------
# Token 生命周期(契约见 spec TOKEN_REFRESH_SPEC)
#
# 状态机:
#   idle --token_refresh_needed/refresh_now()--> refreshing
#   refreshing --provider ok--> authenticate --ok--> idle(emit auth_recovered(true))
#   refreshing --provider terminal--> cleared(emit logout_required,不再重试)
#   refreshing --provider transient--> idle(emit auth_recovered(false),等下次事件)
#   任意状态 --ForcedLogout--> cleared(emit logout_required)
#
# 边界:SDK 不持业务 token 策略。本类只做编排(single-flight、代际保护、
# 重新 authenticate);新 token 从 token_provider 取,默认走内置的
# privchat-application member 刷新,模式 C 由宿主覆盖。
# ---------------------------------------------------------------------------

## 需要服务端的操作在刷新期间统一等待,避免每个调用方各自记得加 gate。
## 返回非空字符串表示应以该错误直接失败。
## connect/authenticate 不走本 gate:它们是恢复流程本身,gate 会死锁。
func _gate_network(timeout_ms: int = 10000) -> String:
	if not _refreshing:
		return ""
	var settled := await await_auth_ready(timeout_ms)
	if not settled:
		return "AUTH_REFRESHING"
	if logged_in_user_id < 0:
		return "NO_SESSION"
	return ""


## 是否正在刷新。刷新期间本地读(local-first)照常可用,不做全局阻塞 ——
## 阻塞会违反 spec §7.1 的离线可用契约。
func is_refreshing() -> bool:
	return _refreshing


## 等待刷新结束(仅供需要串行化的调用方);未在刷新时立即返回。
func await_auth_ready(timeout_ms: int = 15000) -> bool:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while _refreshing and Time.get_ticks_msec() < deadline:
		if not is_inside_tree():
			return false
		await get_tree().process_frame
	return not _refreshing


## 主动触发一次 token 恢复(收到 10002、或宿主自行判定过期时调用)。
## single-flight:并发调用只会真正刷新一次,其余等待同一结果。
## 返回 { ok, error, terminal }。
func refresh_now() -> Dictionary:
	if _refreshing:
		var settled := await await_auth_ready()
		return { "ok": settled and logged_in_user_id >= 0, "error": "", "terminal": false }
	if native == null:
		return { "ok": false, "error": "client not started", "terminal": false }
	# 会话已清理:直接告知调用方,不再广播退出(否则多个界面会重复跳登录页)。
	if logged_in_user_id < 0 and refresh_token_value.is_empty():
		return { "ok": false, "error": "NO_SESSION", "terminal": true }

	_refreshing = true
	var generation := _auth_generation
	var device_id := logged_in_device_id
	var result := await _run_refresh(generation, device_id)
	# 代际变化 = 期间发生了登出/重新登录,旧结果一律作废,不得覆盖新会话。
	if _auth_generation != generation:
		_refreshing = false
		return { "ok": false, "error": "superseded by a newer session", "terminal": false }
	_refreshing = false

	if result.terminal:
		_clear_session()
		_broadcast_logout(int(result.get("code", 0)), str(result.error))
	else:
		auth_recovered.emit(result.ok, str(result.error))
	return result


func _run_refresh(generation: int, device_id: String) -> Dictionary:
	if refresh_token_value.is_empty() and not token_provider.is_valid():
		return { "ok": false, "error": "no refresh token and no token_provider", "terminal": true }

	var provider := token_provider if token_provider.is_valid() else _ensure_default_provider()
	var provided: Dictionary = await provider.call(refresh_token_value, device_id)

	if not provided.get("ok", false):
		return { "ok": false, "error": str(provided.get("error", "refresh failed")),
				"terminal": bool(provided.get("terminal", false)) }
	# 刷新期间会话已被替换/登出。
	if _auth_generation != generation:
		return { "ok": false, "error": "superseded", "terminal": false }

	var data: Dictionary = provided.get("data", {})
	var new_access := str(data.get("access_token", ""))
	if new_access.is_empty():
		return { "ok": false, "error": "provider returned no access_token", "terminal": true }
	if not str(data.get("refresh_token", "")).is_empty():
		refresh_token_value = str(data.refresh_token)   # rotation

	# 契约(TOKEN_REFRESH_SPEC §3.1.1):SDK 已把 transport 拉回 Connected,
	# 这里**只能** authenticate;再调 connect() 会用旧 token 触发死循环。
	var uid := int(data.get("user_id", logged_in_user_id))
	var auth_resp: Dictionary = await authenticate(uid, new_access,
			str(data.get("device_id", device_id)) if not str(data.get("device_id", "")).is_empty() else device_id)
	if not auth_resp.ok:
		return { "ok": false, "error": "re-authenticate: " + str(auth_resp.error), "terminal": false }
	return { "ok": true, "error": "", "terminal": false }


## 清理登录态(终态失败/强制登出)。不触碰 native 连接,由宿主决定去留。
## refresh_token 在此清除:登出、换账号、代际变化都会走到这里。
## 默认 provider(模式 B)。core 与它之间只有 Callable 契约,可整体替换。
func _ensure_default_provider() -> Callable:
	if _default_provider == null:
		_default_provider = PrivchatApplicationAuthProvider.new(_ensure_auth())
	return _default_provider.refresh


func _clear_session() -> void:
	_auth_generation += 1
	logged_in_user_id = -1
	logged_in_device_id = ""
	refresh_token_value = ""


## 同一代际内只广播一次,避免多个界面重复跳登录页。
func _broadcast_logout(code: int, reason: String) -> void:
	if _logout_broadcast:
		return
	_logout_broadcast = true
	logout_required.emit(code, reason)


## 宿主主动登出:推进代际,让在途刷新结果失效。
func forget_session() -> void:
	_clear_session()


# ---------------------------------------------------------------------------
# awaitable native operations (return { ok, data, error })
# data: 已解析的 Dictionary / Array / null,永远不是 JSON 字符串
# ---------------------------------------------------------------------------

func authenticate(user_id: int, access_token: String, device_id: String,
		timeout_ms: int = 15000) -> Dictionary:
	if native == null:
		return _not_started()
	var rid: int = native.authenticate(user_id, access_token, device_id, timeout_ms)
	var result: Dictionary = await _await_request(rid, timeout_ms)
	if result.ok:
		# 记住身份:send_text 等以此作 from_uid,漏记会导致用 -1 发信。
		logged_in_user_id = user_id
		logged_in_device_id = device_id
		_logout_broadcast = false   # 新会话:允许下一次终态再广播
	return result


func connect_im(timeout_ms: int = 15000) -> Dictionary:
	if native == null:
		return _not_started()
	var rid: int = native.connect_async(timeout_ms)
	return await _await_request(rid, timeout_ms)


func disconnect_im(timeout_ms: int = 10000) -> Dictionary:
	if native == null:
		return _not_started()
	var rid: int = native.disconnect_async(timeout_ms)
	return await _await_request(rid, timeout_ms)


## Bootstrap sync gate：authenticate+connect 后、任何本地优先操作
## （发消息等）之前必须完成，对标 TS SDK 的 bootstrapChannels。
func bootstrap_sync(timeout_ms: int = 30000) -> Dictionary:
	if native == null:
		return _not_started()
	var rid: int = native.run_bootstrap_sync(timeout_ms)
	return await _await_request(rid, timeout_ms)


func subscribe_channel(channel_id: int, channel_type: int, token: String = "",
		timeout_ms: int = 10000) -> Dictionary:
	if native == null:
		return _not_started()
	var gate := await _gate_network()
	if not gate.is_empty():
		return { "ok": false, "data": null, "error": gate }
	var rid: int = native.subscribe_channel(channel_id, channel_type, token, timeout_ms)
	return await _await_request(rid, timeout_ms)


func unsubscribe_channel(channel_id: int, channel_type: int,
		timeout_ms: int = 10000) -> Dictionary:
	if native == null:
		return _not_started()
	var gate := await _gate_network()
	if not gate.is_empty():
		return { "ok": false, "data": null, "error": gate }
	var rid: int = native.unsubscribe_channel(channel_id, channel_type, timeout_ms)
	return await _await_request(rid, timeout_ms)


## Queue-first text send; resolves when the local message is enqueued.
## Delivery progress arrives via sdk_event (MessageSendStatusChanged).
func send_text(channel_id: int, channel_type: int, content: String,
		timeout_ms: int = 10000) -> Dictionary:
	if native == null:
		return _not_started()
	var rid: int = native.send_text_message(channel_id, channel_type,
			logged_in_user_id, content, timeout_ms)
	return await _await_request(rid, timeout_ms)


## Channel Transfer。body 是 Dictionary;返回 { ok, data, error },
## data 为 transfer 信封 {"request_id","channel_id","code","message","data"}。
func transfer(channel_id: int, route: String, body: Dictionary,
		timeout_ms: int = 8000) -> Dictionary:
	if native == null:
		return _not_started()
	var gate := await _gate_network()
	if not gate.is_empty():
		return { "ok": false, "data": null, "error": gate }
	var rid: int = native.transfer(channel_id, route, body, timeout_ms)
	return await _await_request(rid, timeout_ms)


## 二进制 Channel Transfer:body/返回都是 PackedByteArray,可承载
## FlatBuffers/Protobuf 等含内嵌 NUL 的负载(字符串版 transfer 做不到)。
## 返回 { ok, code, data: PackedByteArray, error };ok 表示信封 code == 0。
func transfer_bytes(channel_id: int, route: String, body: PackedByteArray,
		timeout_ms: int = 8000) -> Dictionary:
	if native == null:
		return _not_started()
	var gate := await _gate_network()
	if not gate.is_empty():
		return { "ok": false, "code": -1, "data": PackedByteArray(), "error": gate }
	var rid: int = native.transfer_bytes(channel_id, route, body, timeout_ms)
	var result: Dictionary = await _await_request(rid, timeout_ms)
	var envelope: Dictionary = result.data if typeof(result.data) == TYPE_DICTIONARY else {}
	return {
		"ok": result.ok,
		"code": int(envelope.get("code", -1)),
		"data": envelope.get("data", PackedByteArray()),
		"error": str(result.get("error", "")),
	}


## 全局 RPC。body 是 Dictionary;返回 { ok, data, error },data 为服务端响应对象。
func rpc_call(route: String, body: Dictionary, timeout_ms: int = 8000) -> Dictionary:
	if native == null:
		return _not_started()
	var gate := await _gate_network()
	if not gate.is_empty():
		return { "ok": false, "data": null, "error": gate }
	var rid: int = native.rpc_call(route, body, timeout_ms)
	return await _await_request(rid, timeout_ms)


func sync_channel(channel_id: int, channel_type: int, timeout_ms: int = 15000) -> Dictionary:
	if native == null:
		return _not_started()
	var gate := await _gate_network()
	if not gate.is_empty():
		return { "ok": false, "data": null, "error": gate }
	var rid: int = native.sync_channel(channel_id, channel_type, timeout_ms)
	return await _await_request(rid, timeout_ms)


## 返回 { ok, data: StoredMessage Dictionary | null, error }。
func get_message_by_id(message_id: int, timeout_ms: int = 8000) -> Dictionary:
	if native == null:
		return _not_started()
	var rid: int = native.get_message_by_id(message_id, timeout_ms)
	return await _await_request(rid, timeout_ms)


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
	if native == null:
		return _not_started()
	var rid: int = native.open_conversation(channel_id, channel_type, limit, timeout_ms)
	return _page_view(await _await_request(rid, timeout_ms))


## 上滑加载更早历史(SDK-HISTORY-5);has_more_before=false 即到顶(跨会话持久化)。
func load_older_history(channel_id: int, channel_type: int,
		before_server_message_id: int, limit: int = 50,
		timeout_ms: int = 10000) -> Dictionary:
	if native == null:
		return _not_started()
	var rid: int = native.load_older_history(channel_id, channel_type,
			before_server_message_id, limit, timeout_ms)
	return _page_view(await _await_request(rid, timeout_ms))


## 纯本地分页读(不触网)。返回 { ok, error, messages: Array }。
func list_messages(channel_id: int, channel_type: int, limit: int = 50,
		offset: int = 0, timeout_ms: int = 8000) -> Dictionary:
	if native == null:
		return _not_started()
	var rid: int = native.list_messages(channel_id, channel_type, limit, offset, timeout_ms)
	var result: Dictionary = await _await_request(rid, timeout_ms)
	result.messages = result.data if typeof(result.data) == TYPE_ARRAY else []
	return result


## 本地会话列表;条目自带 unread_count/top/mute/last_msg_timestamp/last_msg_content。
## 返回 { ok, error, channels: Array }(已按 top 优先、last_msg_timestamp 降序排序)。
func list_channels(limit: int = 50, offset: int = 0, timeout_ms: int = 8000) -> Dictionary:
	if native == null:
		return _not_started()
	var rid: int = native.list_channels(limit, offset, timeout_ms)
	var result: Dictionary = await _await_request(rid, timeout_ms)
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
	if native == null:
		return _not_started()
	var rid: int = native.mark_read_to_pts(channel_id, read_pts, timeout_ms)
	var result: Dictionary = await _await_request(rid, timeout_ms)
	result.last_read_pts = _data_int(result, "last_read_pts")
	return result


## 单频道未读数(本地)。返回 { ok, error, count: int }。
func get_channel_unread_count(channel_id: int, channel_type: int,
		timeout_ms: int = 8000) -> Dictionary:
	if native == null:
		return _not_started()
	var rid: int = native.get_channel_unread_count(channel_id, channel_type, timeout_ms)
	var result: Dictionary = await _await_request(rid, timeout_ms)
	result.count = _data_int(result, "count")
	return result


## 全局未读角标(本地)。返回 { ok, error, count: int }。
func get_total_unread_count(exclude_muted: bool = false,
		timeout_ms: int = 8000) -> Dictionary:
	if native == null:
		return _not_started()
	var rid: int = native.get_total_unread_count(exclude_muted, timeout_ms)
	var result: Dictionary = await _await_request(rid, timeout_ms)
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


## 每次 await 带硬超时护栏(timeout_ms + 5s 宽限):native 永不应答时
## 返回失败而不是永久挂起。超时的 rid 记入 _abandoned,迟到结果直接丢弃,
## 否则 _results 会无限增长。
func _await_request(rid: int, timeout_ms: int = 30000) -> Dictionary:
	_inflight += 1
	var result := await _await_request_inner(rid, timeout_ms)
	_inflight -= 1
	return result


func _await_request_inner(rid: int, timeout_ms: int) -> Dictionary:
	var deadline := Time.get_ticks_msec() + timeout_ms + 5000
	while not _results.has(rid):
		if Time.get_ticks_msec() > deadline:
			# native 若彻底失联,结果永不到达,标记也无人清除 —— 故封顶。
			if _abandoned.size() > 1024:
				_abandoned.clear()
			_abandoned[rid] = true
			return { "ok": false, "data": null, "error": "request timeout (rid=%d)" % rid }
		# 节点已被移出场景树(宿主切场景/释放)时不再等待,避免 get_tree() 为 null。
		if not is_inside_tree():
			return { "ok": false, "data": null, "error": "client detached while awaiting" }
		await get_tree().process_frame
	var result: Dictionary = _results[rid]
	_results.erase(rid)
	return result


func _on_request_completed(request_id: int, kind: int, ok: bool,
		data, error: String) -> void:
	if _abandoned.has(request_id):
		# 请求早已超时返回,丢弃迟到结果。SendText 随后还会发 message_sent,
		# 标记留给它清除;其余类型到此为止,就地清除。
		if kind != KIND_SEND_TEXT:
			_abandoned.erase(request_id)
		return
	_results[request_id] = { "ok": ok, "data": data, "error": error }


func _on_sdk_event(sequence_id: int, timestamp_ms: int, kind: String,
		event: Dictionary) -> void:
	# 生命周期事件升级为强类型信号(spec GODOT_SDK_SPEC §7.1)。
	match kind:
		"ForcedLogout":
			var body: Dictionary = event.get("event", {}).get("ForcedLogout", {})
			# 终态:清会话、推进代际(作废在途刷新),不再重试。
			_clear_session()
			session_expired.emit(int(body.get("code", 0)),
					str(body.get("message", "")), str(body.get("source", "")))
			_broadcast_logout(int(body.get("code", 0)), str(body.get("message", "")))
		"AccessTokenRefreshNeeded":
			var body: Dictionary = event.get("event", {}).get("AccessTokenRefreshNeeded", {})
			token_refresh_needed.emit(int(body.get("code", 0)),
					str(body.get("message", "")))
			# 自动接管恢复流程(single-flight;重复事件不会叠加刷新)。
			refresh_now()
	sdk_event.emit(sequence_id, timestamp_ms, kind, event)


func _on_connection_state_changed(from_state: String, to_state: String) -> void:
	connection_state_changed.emit(from_state, to_state)


func _on_message_sent(request_id: int, ok: bool, message_id: int, error: String) -> void:
	# SendText 结果以本信号为准（native 先发 request_completed 再发本信号，
	# 这里覆盖补齐 message_id，否则 send_text 的 await 永远拿不到结果）。
	if _abandoned.erase(request_id) == false:
		_results[request_id] = { "ok": ok, "data": null, "error": error,
				"message_id": message_id }
	message_sent.emit(request_id, ok, message_id, error)
