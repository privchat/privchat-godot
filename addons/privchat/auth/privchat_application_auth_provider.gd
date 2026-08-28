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


## token_provider 契约实现。member 模块拒绝刷新 = refresh token 失效或
## 被撤销 → 终态,调用方不应重试。
func refresh(refresh_token_value: String, device_id: String) -> Dictionary:
	if auth == null:
		return { "ok": false, "data": {}, "error": "auth client unavailable", "terminal": true }
	var resp: Dictionary = await auth.refresh_token(refresh_token_value, device_id)
	if not resp.get("ok", false):
		return { "ok": false, "data": {}, "error": str(resp.get("error", "refresh failed")),
				"terminal": true }
	return { "ok": true, "data": resp.get("data", {}), "error": "", "terminal": false }
