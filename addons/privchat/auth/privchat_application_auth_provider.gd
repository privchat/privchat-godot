# privchat_application_auth_provider.gd — 默认 token provider(模式 B)。
#
# 把"新 access token 从哪来"实现为**可替换的 adapter**,而不是
# PrivchatClient 的核心职责:core 只做恢复编排(single-flight、代际保护、
# 重新 authenticate),token 来源由 provider 决定。
#
#   addon core
#   ├── PrivchatClient(AuthCoordinator:编排)
#   └── auth providers
#       ├── PrivchatApplicationAuthProvider  ← 本文件(privchat-application
#       │                                       member 模块,平台标准账号体系)
#       └── 自定义 provider(模式 C:业务后台自有 token 体系)
#
# 自定义 provider 只需提供同签名的 Callable:
#   func(refresh_token: String, device_id: String) -> Dictionary
#     返回 { ok, data: { user_id, access_token, refresh_token, device_id },
#            error, terminal }
#
# token 只在内存中传递,不落日志(本类任何分支都不打印 token)。
class_name PrivchatApplicationAuthProvider
extends RefCounted

var auth: PrivchatPlatformAuthClient = null


func _init(p_auth: PrivchatPlatformAuthClient) -> void:
	auth = p_auth


## token_provider 契约实现。
##
## 只有 member 模块**明确拒绝**(应用错误码)才是终态——refresh token 失效或被撤销,
## 调用方不应重试。传输错误、非 JSON 响应、服务端内部错误(code 4)都是暂时的:
## 一次 2 秒的网络抖动不该把手里还有效 refresh token 的用户踢回登录页。
func refresh(refresh_token_value: String, device_id: String) -> Dictionary:
	if auth == null:
		return { "ok": false, "data": {}, "error": "auth client unavailable", "terminal": false }
	var resp: Dictionary = await auth.refresh_token(refresh_token_value, device_id)
	if not resp.get("ok", false):
		var error := str(resp.get("error", "refresh failed"))
		return { "ok": false, "data": {}, "error": error, "terminal": _is_terminal(error) }
	return { "ok": true, "data": resp.get("data", {}), "error": "", "terminal": false }


## PrivchatPlatformAuthClient 把应用层拒绝格式化为 "application code=N: msg";其余
## 字符串都是传输层/解析层错误。code 4 是 neton 的内部错误,也按暂时处理。
static func _is_terminal(error: String) -> bool:
	if not error.begins_with("application code="):
		return false
	var code := int(error.substr("application code=".length()).split(":")[0])
	return code != 0 and code != 4 and code < 500
