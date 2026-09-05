# platform_auth_client.gd
#
# Thin HTTP helper for privchat-application's `auth` controller
# (PLATFORM account mode). GDScript port of privchat-cocos
# src/auth/platform-auth-client.ts — same endpoints, same envelope:
#
#   GET  {base_url}/config/bootstrap    → { gateways, auth: { registerModes, ... } }
#   POST {base_url}/auth/send-sms-code  { mobile, scene: 1 }
#   POST {base_url}/auth/sms-login      { mobile, smsCode, device }
#   POST {base_url}/auth/register       { mode: USERNAME_PASSWORD, username, password, nickname?, inviteCode?, device }
#   POST {base_url}/auth/login-username { username, password, device }
#   POST {base_url}/auth/refresh-token  { refreshToken, deviceId }
#
# Which of PHONE_SMS / USERNAME_PASSWORD a deployment accepts is **server
# configuration** (privchat.conf [auth], MEMBER_INVITE_CODE_SPEC §5.0): read
# it from fetch_bootstrap() and render the login form from it — never
# hard-code a mode in the client.
# Envelope: { code: 0, message, data }. The returned accessToken is
# server-signed and works for both HTTP and the IM layer; pass it to
# PrivchatClient.authenticate(user_id, access_token, device_id).
class_name PrivchatPlatformAuthClient
extends Node

const SMS_SCENE_LOGIN := 1
const DEFAULT_TIMEOUT_MS := 15000

## Application route-group root, e.g. "http://127.0.0.1:8080/app".
var base_url: String = "http://127.0.0.1:8080/app"


func _ready() -> void:
	base_url = base_url.trim_suffix("/")


const MODE_PHONE_SMS := "PHONE_SMS"
const MODE_USERNAME_PASSWORD := "USERNAME_PASSWORD"


## GET /config/bootstrap (anonymous). Returns { ok, error, data } where data is
## { gateways: Array, features: Dictionary, legal: Dictionary, config_version: String,
##   register_modes: Array[String], default_register_mode: String,
##   invite_code_required: bool, nickname_required: bool }.
## Missing `auth` block (older application) → PHONE_SMS only, the historical default.
func fetch_bootstrap() -> Dictionary:
	var resp := await _http_get("/config/bootstrap")
	if not resp.ok:
		return resp
	var data: Dictionary = resp.data
	var auth: Dictionary = data.get("auth", {}) if typeof(data.get("auth")) == TYPE_DICTIONARY else {}
	var modes: Array = []
	for m in auth.get("registerModes", [MODE_PHONE_SMS]):
		modes.append(str(m).to_upper())
	if modes.is_empty():
		modes = [MODE_PHONE_SMS]
	return { "ok": true, "error": "", "data": {
		"gateways": data.get("gateways", []),
		"features": data.get("features", {}),
		"legal": data.get("legal", {}),
		"config_version": str(data.get("configVersion", "")),
		"register_modes": modes,
		"default_register_mode": str(auth.get("defaultRegisterMode", modes[0])).to_upper(),
		"invite_code_required": bool(auth.get("inviteCodeRequired", false)),
		"nickname_required": bool(auth.get("nicknameRequired", false)),
	} }


## POST /auth/register (mode USERNAME_PASSWORD). Same return shape as login_with_sms.
## username 3-32 chars, password 8-128 (server validation).
func register_with_username(username: String, password: String, device: Dictionary,
		nickname: String = "", invite_code: String = "") -> Dictionary:
	var body := {
		"mode": MODE_USERNAME_PASSWORD,
		"username": username,
		"password": password,
		"device": device,
	}
	if not nickname.is_empty():
		body["nickname"] = nickname
	if not invite_code.is_empty():
		body["inviteCode"] = invite_code
	var resp := await _post("/auth/register", body)
	if not resp.ok:
		return resp
	var login := _normalize_login_response(resp.data)
	if login.is_empty():
		return { "ok": false, "error": "invalid register response: missing user_id/accessToken/refreshToken", "data": {} }
	return { "ok": true, "error": "", "data": login }


## POST /auth/login-username. Same return shape as login_with_sms.
func login_with_username(username: String, password: String, device: Dictionary) -> Dictionary:
	var resp := await _post("/auth/login-username", {
		"username": username,
		"password": password,
		"device": device,
	})
	if not resp.ok:
		return resp
	var login := _normalize_login_response(resp.data)
	if login.is_empty():
		return { "ok": false, "error": "invalid login response: missing user_id/accessToken/refreshToken", "data": {} }
	return { "ok": true, "error": "", "data": login }


## POST /auth/send-sms-code. Returns { ok, error }.
func send_sms_code(mobile: String) -> Dictionary:
	var resp := await _post("/auth/send-sms-code", {
		"mobile": mobile,
		"scene": SMS_SCENE_LOGIN,
	})
	if not resp.ok:
		return resp
	return { "ok": true, "error": "" }


## POST /auth/sms-login. Returns { ok, error, data } where data is the
## normalized LoginResponse: user_id / access_token / refresh_token /
## device_id (+ optional expires fields).
func login_with_sms(mobile: String, sms_code: String, device: Dictionary) -> Dictionary:
	var resp := await _post("/auth/sms-login", {
		"mobile": mobile,
		"smsCode": sms_code,
		"device": device,
	})
	if not resp.ok:
		return resp
	var data: Dictionary = resp.data
	var login := _normalize_login_response(data)
	if login.is_empty():
		return { "ok": false, "error": "invalid login response: missing user_id/accessToken/refreshToken", "data": {} }
	return { "ok": true, "error": "", "data": login }


## POST /auth/refresh-token. Same return shape as login_with_sms.
func refresh_token(refresh_token_value: String, device_id: String) -> Dictionary:
	var resp := await _post("/auth/refresh-token", {
		"refreshToken": refresh_token_value,
		"deviceId": device_id,
	})
	if not resp.ok:
		return resp
	var login := _normalize_login_response(resp.data)
	if login.is_empty():
		return { "ok": false, "error": "invalid refresh response: missing user_id/accessToken/refreshToken", "data": {} }
	if login.refresh_token.is_empty():
		login.refresh_token = refresh_token_value
	return { "ok": true, "error": "", "data": login }


## Default device descriptor for this machine (sms-login `device` field).
## device_id 必须是 UUID 格式（server 校验），首次生成后持久化到 user://。
static func default_device_info() -> Dictionary:
	var device_id := _load_or_create_device_id()
	return {
		"deviceId": device_id,
		"deviceName": OS.get_model_name(),
		"platform": OS.get_name().to_lower(),
		"deviceModel": OS.get_model_name(),
		"osVersion": OS.get_version(),
		"appVersion": "0.1.0",
	}


static func _load_or_create_device_id() -> String:
	var path := "user://privchat_device_id"
	if FileAccess.file_exists(path):
		var f := FileAccess.open(path, FileAccess.READ)
		if f != null:
			var stored := f.get_as_text().strip_edges()
			f.close()
			if not stored.is_empty():
				return stored
	var id := _random_uuid_v4()
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f != null:
		f.store_string(id)
		f.close()
	return id


static func _random_uuid_v4() -> String:
	var bytes := Crypto.new().generate_random_bytes(16)
	bytes[6] = (bytes[6] & 0x0f) | 0x40   # version 4
	bytes[8] = (bytes[8] & 0x3f) | 0x80   # variant 10
	var hex := ""
	for b in bytes:
		hex += "%02x" % b
	return "%s-%s-%s-%s-%s" % [
		hex.substr(0, 8), hex.substr(8, 4), hex.substr(12, 4),
		hex.substr(16, 4), hex.substr(20, 12)]


# ---------------------------------------------------------------------------
# internals
# ---------------------------------------------------------------------------

func _post(path: String, body: Dictionary) -> Dictionary:
	return await _request(path, HTTPClient.METHOD_POST, JSON.stringify(body))


func _http_get(path: String) -> Dictionary:
	return await _request(path, HTTPClient.METHOD_GET, "")


func _request(path: String, method: int, payload: String) -> Dictionary:
	var url := base_url + path
	var http := HTTPRequest.new()
	http.timeout = DEFAULT_TIMEOUT_MS / 1000.0
	add_child(http)
	var err := http.request(url, ["Content-Type: application/json"], method, payload)
	if err != OK:
		http.queue_free()
		return { "ok": false, "error": "http request failed: %s" % error_string(err), "data": {} }
	var result: Array = await http.request_completed
	http.queue_free()
	var http_result: int = result[0]
	var response_code: int = result[1]
	var response_body: PackedByteArray = result[3]
	if http_result != HTTPRequest.RESULT_SUCCESS:
		return { "ok": false, "error": "http transport error: %d" % http_result, "data": {} }

	var envelope = JSON.parse_string(response_body.get_string_from_utf8())
	if typeof(envelope) != TYPE_DICTIONARY:
		return { "ok": false, "error": "non-JSON response from %s (http %d)" % [path, response_code], "data": {} }
	var code: int = int(envelope.get("code", -1))
	if code != 0:
		var message: String = str(envelope.get("message", "code=%d" % code))
		return { "ok": false, "error": "application code=%d: %s" % [code, message], "data": {} }
	return { "ok": true, "error": "", "data": envelope.get("data", {}) }


# Accepts camelCase or snake_case wire fields (mirrors cocos normalizer).
func _normalize_login_response(data: Dictionary) -> Dictionary:
	if data.is_empty():
		return {}
	var user_id: int = int(data.get("userId", data.get("user_id", -1)))
	var access_token: String = str(data.get("accessToken", data.get("access_token", "")))
	var refresh_token_value: String = str(data.get("refreshToken", data.get("refresh_token", "")))
	var device_id: String = str(data.get("deviceId", data.get("device_id", "")))
	if user_id < 0 or access_token.is_empty() or refresh_token_value.is_empty():
		return {}
	return {
		"user_id": user_id,
		"access_token": access_token,
		"refresh_token": refresh_token_value,
		"device_id": device_id,
		"expires_in": data.get("expiresIn", data.get("expires_in", null)),
		"refresh_expires_in": data.get("refreshExpiresIn", data.get("refresh_expires_in", null)),
	}
