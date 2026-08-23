// privchat_native_client.cpp
#include "privchat_native_client.h"

#include <godot_cpp/classes/json.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

namespace godot {

namespace {

std::string to_std(const String &s) {
    CharString utf8 = s.utf8();
    return std::string(utf8.get_data(), utf8.length());
}

constexpr double EVENT_POLL_INTERVAL = 0.05; // seconds
constexpr uint64_t EVENT_POLL_BATCH = 200;

} // namespace

PrivchatNativeClient::PrivchatNativeClient() {
    // 必须显式开启，否则收不到 NOTIFICATION_PROCESS（drain/轮询全部失效）。
    set_process(true);
}

PrivchatNativeClient::~PrivchatNativeClient() {
    shutdown();
}

void PrivchatNativeClient::_notification(int p_what) {
    switch (p_what) {
        case NOTIFICATION_PROCESS: {
            drain_results();
            poll_events();
        } break;
        case NOTIFICATION_PREDELETE:
        case NOTIFICATION_EXIT_TREE: {
            shutdown();
        } break;
    }
}

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------

bool PrivchatNativeClient::initialize(const String &config_json) {
    std::lock_guard<std::mutex> lock(client_mutex);
    if (initialized) {
        return true;
    }
    PrivchatCapiClient *c = privchat_capi_client_create(config_json.utf8().get_data());
    if (c == nullptr) {
        const char *err = privchat_capi_last_error();
        UtilityFunctions::push_error("[privchat] client create failed: ",
                err ? String::utf8(err) : String("unknown error"));
        return false;
    }
    client = c;
    event_cursor.store(0);
    stop_requested.store(false);
    worker_running.store(true);
    worker = std::thread(&PrivchatNativeClient::worker_loop, this);
    initialized = true;
    UtilityFunctions::print("[privchat] native client initialized");
    return true;
}

void PrivchatNativeClient::shutdown() {
    // Stop the worker first so no task is mid-call when the client is freed.
    if (worker_running.exchange(false)) {
        {
            std::lock_guard<std::mutex> lock(queue_mutex);
            stop_requested.store(true);
        }
        queue_cv.notify_all();
        if (worker.joinable()) {
            worker.join();
        }
    }
    std::lock_guard<std::mutex> lock(client_mutex);
    if (client != nullptr) {
        privchat_capi_client_destroy(client);
        client = nullptr;
    }
    initialized = false;
}

bool PrivchatNativeClient::is_initialized() const {
    return initialized;
}

// ---------------------------------------------------------------------------
// Task queue / worker
// ---------------------------------------------------------------------------

uint64_t PrivchatNativeClient::enqueue_task(Task task) {
    task.request_id = next_request_id.fetch_add(1);
    {
        std::lock_guard<std::mutex> lock(queue_mutex);
        task_queue.push_back(std::move(task));
    }
    queue_cv.notify_one();
    return task.request_id;
}

void PrivchatNativeClient::worker_loop() {
    while (true) {
        Task task;
        {
            std::unique_lock<std::mutex> lock(queue_mutex);
            queue_cv.wait(lock, [this] {
                return stop_requested.load() || !task_queue.empty();
            });
            if (task_queue.empty()) {
                if (stop_requested.load()) {
                    return;
                }
                continue;
            }
            task = std::move(task_queue.front());
            task_queue.pop_front();
        }
        run_task(task);
    }
}

std::string PrivchatNativeClient::last_error_or(const char *fallback) {
    const char *err = privchat_capi_last_error();
    return err ? std::string(err) : std::string(fallback);
}

PrivchatNativeClient::TaskResult PrivchatNativeClient::make_error(const Task &task, const char *fallback) {
    TaskResult r;
    r.request_id = task.request_id;
    r.kind = task.kind;
    r.ok = false;
    r.code = PRIVCHAT_CAPI_ERR_INVALID_ARG;
    r.error = last_error_or(fallback);
    return r;
}

void PrivchatNativeClient::push_result(TaskResult result) {
    std::lock_guard<std::mutex> lock(result_mutex);
    result_queue.push_back(std::move(result));
}

void PrivchatNativeClient::run_task(const Task &task) {
    PrivchatCapiClient *c = nullptr;
    {
        std::lock_guard<std::mutex> lock(client_mutex);
        c = client;
    }
    if (c == nullptr) {
        push_result(make_error(task, "client not initialized"));
        return;
    }
    const uint64_t timeout_ms = task.u64_b > 0 ? task.u64_b : 10000;

    TaskResult r;
    r.request_id = task.request_id;
    r.kind = task.kind;

    switch (task.kind) {
        case TaskKind::Authenticate: {
            r.code = privchat_capi_authenticate(c, task.u64_a, task.str_a.c_str(),
                    task.str_b.c_str(), timeout_ms);
            r.ok = r.code == PRIVCHAT_CAPI_OK;
            if (!r.ok) {
                r.error = last_error_or("authenticate failed");
            }
        } break;

        case TaskKind::Connect: {
            r.code = privchat_capi_connect(c, timeout_ms);
            r.ok = r.code == PRIVCHAT_CAPI_OK;
            if (!r.ok) {
                r.error = last_error_or("connect failed");
            }
        } break;

        case TaskKind::Disconnect: {
            r.code = privchat_capi_disconnect(c, timeout_ms);
            r.ok = r.code == PRIVCHAT_CAPI_OK;
            if (!r.ok) {
                r.error = last_error_or("disconnect failed");
            }
        } break;

        case TaskKind::Shutdown: {
            r.code = privchat_capi_shutdown(c, timeout_ms);
            r.ok = r.code == PRIVCHAT_CAPI_OK;
            if (!r.ok) {
                r.error = last_error_or("shutdown failed");
            }
        } break;

        case TaskKind::Subscribe: {
            const char *token = task.str_a.empty() ? nullptr : task.str_a.c_str();
            r.code = privchat_capi_subscribe_channel(c, task.u64_a,
                    static_cast<uint8_t>(task.i64_a), token, timeout_ms);
            r.ok = r.code == PRIVCHAT_CAPI_OK;
            if (!r.ok) {
                r.error = last_error_or("subscribe failed");
            }
        } break;

        case TaskKind::Unsubscribe: {
            r.code = privchat_capi_unsubscribe_channel(c, task.u64_a,
                    static_cast<uint8_t>(task.i64_a), timeout_ms);
            r.ok = r.code == PRIVCHAT_CAPI_OK;
            if (!r.ok) {
                r.error = last_error_or("unsubscribe failed");
            }
        } break;

        case TaskKind::SendText: {
            // Slots: u64_a=channel_id, i64_a=channel_type, u64_b=from_uid,
            // str_a=content, str_b=timeout_ms.
            const uint64_t send_timeout = task.str_b.empty() ? 10000 : strtoull(task.str_b.c_str(), nullptr, 10);
            uint64_t message_id = 0;
            r.code = privchat_capi_send_text_message(c, task.u64_a,
                    static_cast<int32_t>(task.i64_a), task.u64_b,
                    task.str_a.c_str(), send_timeout, &message_id);
            r.ok = r.code == PRIVCHAT_CAPI_OK;
            r.message_id = message_id;
            if (!r.ok) {
                r.error = last_error_or("send failed");
            }
        } break;

        case TaskKind::Transfer: {
            char *out = privchat_capi_transfer(c, task.u64_a, task.str_a.c_str(),
                    task.str_b.c_str(), timeout_ms);
            if (out != nullptr) {
                r.ok = true;
                r.payload = out;
                privchat_capi_free_string(out);
            } else {
                r.ok = false;
                r.error = last_error_or("transfer failed");
            }
        } break;

        case TaskKind::RpcCall: {
            char *out = privchat_capi_rpc_call(c, task.str_a.c_str(), task.str_b.c_str(), timeout_ms);
            if (out != nullptr) {
                r.ok = true;
                r.payload = out;
                privchat_capi_free_string(out);
            } else {
                r.ok = false;
                r.error = last_error_or("rpc failed");
            }
        } break;

        case TaskKind::SyncChannel: {
            uint64_t applied = 0;
            r.code = privchat_capi_sync_channel(c, task.u64_a,
                    static_cast<int32_t>(task.i64_a), timeout_ms, &applied);
            r.ok = r.code == PRIVCHAT_CAPI_OK;
            r.message_id = applied; // reuse slot for applied count
            if (!r.ok) {
                r.error = last_error_or("sync_channel failed");
            }
        } break;

        case TaskKind::GetMessageById: {
            char *out = privchat_capi_get_message_by_id(c, task.u64_a, timeout_ms);
            if (out != nullptr) {
                r.ok = true;
                r.payload = out;
                privchat_capi_free_string(out);
            } else {
                r.ok = false;
                r.error = last_error_or("get_message_by_id failed");
            }
        } break;

        case TaskKind::BootstrapSync: {
            r.code = privchat_capi_run_bootstrap_sync(c, timeout_ms);
            r.ok = r.code == PRIVCHAT_CAPI_OK;
            if (!r.ok) {
                r.error = last_error_or("run_bootstrap_sync failed");
            }
        } break;
    }
    push_result(std::move(r));
}

// ---------------------------------------------------------------------------
// Main-thread drain + event polling
// ---------------------------------------------------------------------------

void PrivchatNativeClient::drain_results() {
    std::deque<TaskResult> pending;
    {
        std::lock_guard<std::mutex> lock(result_mutex);
        pending.swap(result_queue);
    }
    for (const TaskResult &r : pending) {
        emit_signal("request_completed", (int64_t)r.request_id, (int64_t)r.kind,
                r.ok, String::utf8(r.payload.c_str()), String::utf8(r.error.c_str()));
        if (r.kind == TaskKind::SendText) {
            emit_signal("message_sent", (int64_t)r.request_id, r.ok,
                    (int64_t)r.message_id, String::utf8(r.error.c_str()));
        }
    }
}

void PrivchatNativeClient::poll_events() {
    if (!initialized) {
        return;
    }
    poll_accumulator += get_process_delta_time();
    if (poll_accumulator < EVENT_POLL_INTERVAL) {
        return;
    }
    poll_accumulator = 0.0;

    PrivchatCapiClient *c = nullptr;
    {
        std::lock_guard<std::mutex> lock(client_mutex);
        c = client;
    }
    if (c == nullptr) {
        return;
    }
    // Unfiltered poll: the SDK's timeline_events_since drops events outside
    // its timeline/network filter sets (e.g. SubscriptionMessageReceived for
    // Room broadcasts), so we poll the full stream and let GDScript match kinds.
    char *raw = privchat_capi_events_since(c, event_cursor.load(), EVENT_POLL_BATCH);
    if (raw == nullptr) {
        return;
    }
    String json_text = String::utf8(raw);
    privchat_capi_free_string(raw);

    Variant parsed = JSON::parse_string(json_text);
    if (parsed.get_type() != Variant::ARRAY) {
        return;
    }
    Array events = parsed;
    for (int i = 0; i < events.size(); ++i) {
        if (events[i].get_type() != Variant::DICTIONARY) {
            continue;
        }
        Dictionary seq_event = events[i];
        int64_t sequence_id = seq_event.get("sequence_id", 0);
        int64_t timestamp_ms = seq_event.get("timestamp_ms", 0);
        Variant event_variant = seq_event.get("event", Dictionary());

        String kind = "unknown";
        if (event_variant.get_type() == Variant::DICTIONARY) {
            Dictionary event_dict = event_variant;
            Array keys = event_dict.keys();
            if (!keys.is_empty()) {
                kind = keys[0];
            }
            if (kind == "ConnectionStateChanged") {
                Dictionary payload = event_dict.get("ConnectionStateChanged", Dictionary());
                emit_signal("connection_state_changed",
                        payload.get("from", ""), payload.get("to", ""));
            }
        }
        if (sequence_id > (int64_t)event_cursor.load()) {
            event_cursor.store((uint64_t)sequence_id);
        }
        String event_json;
        {
            // Re-serialize the single sequenced event for GDScript consumers.
            Variant single = seq_event;
            event_json = JSON::stringify(single);
        }
        emit_signal("sdk_event", sequence_id, timestamp_ms, kind, event_json);
    }
}

// ---------------------------------------------------------------------------
// GDScript-facing async API
// ---------------------------------------------------------------------------

uint64_t PrivchatNativeClient::authenticate(uint64_t user_id, const String &token,
        const String &device_id, int64_t timeout_ms) {
    Task t;
    t.kind = TaskKind::Authenticate;
    t.u64_a = user_id;
    t.str_a = to_std(token);
    t.str_b = to_std(device_id);
    t.u64_b = (uint64_t)timeout_ms;
    return enqueue_task(std::move(t));
}

uint64_t PrivchatNativeClient::connect_async(int64_t timeout_ms) {
    Task t;
    t.kind = TaskKind::Connect;
    t.u64_b = (uint64_t)timeout_ms;
    return enqueue_task(std::move(t));
}

uint64_t PrivchatNativeClient::disconnect_async(int64_t timeout_ms) {
    Task t;
    t.kind = TaskKind::Disconnect;
    t.u64_b = (uint64_t)timeout_ms;
    return enqueue_task(std::move(t));
}

uint64_t PrivchatNativeClient::run_bootstrap_sync(int64_t timeout_ms) {
    Task t;
    t.kind = TaskKind::BootstrapSync;
    t.u64_b = (uint64_t)timeout_ms;
    return enqueue_task(std::move(t));
}

uint64_t PrivchatNativeClient::subscribe_channel(uint64_t channel_id, int64_t channel_type,
        const String &token, int64_t timeout_ms) {
    Task t;
    t.kind = TaskKind::Subscribe;
    t.u64_a = channel_id;
    t.i64_a = channel_type;
    t.str_a = to_std(token);
    t.u64_b = (uint64_t)timeout_ms;
    return enqueue_task(std::move(t));
}

uint64_t PrivchatNativeClient::unsubscribe_channel(uint64_t channel_id, int64_t channel_type,
        int64_t timeout_ms) {
    Task t;
    t.kind = TaskKind::Unsubscribe;
    t.u64_a = channel_id;
    t.i64_a = channel_type;
    t.u64_b = (uint64_t)timeout_ms;
    return enqueue_task(std::move(t));
}

uint64_t PrivchatNativeClient::send_text_message(uint64_t channel_id, int64_t channel_type,
        uint64_t from_uid, const String &content, int64_t timeout_ms) {
    Task t;
    t.kind = TaskKind::SendText;
    t.u64_a = channel_id;
    t.i64_a = channel_type;
    t.u64_b = from_uid;
    t.str_a = to_std(content);
    t.str_b = std::to_string(timeout_ms);
    return enqueue_task(std::move(t));
}

uint64_t PrivchatNativeClient::transfer(uint64_t channel_id, const String &route,
        const String &body, int64_t timeout_ms) {
    Task t;
    t.kind = TaskKind::Transfer;
    t.u64_a = channel_id;
    t.str_a = to_std(route);
    t.str_b = to_std(body);
    t.u64_b = (uint64_t)timeout_ms;
    return enqueue_task(std::move(t));
}

uint64_t PrivchatNativeClient::rpc_call(const String &route, const String &body_json,
        int64_t timeout_ms) {
    Task t;
    t.kind = TaskKind::RpcCall;
    t.str_a = to_std(route);
    t.str_b = to_std(body_json);
    t.u64_b = (uint64_t)timeout_ms;
    return enqueue_task(std::move(t));
}

uint64_t PrivchatNativeClient::sync_channel(uint64_t channel_id, int64_t channel_type,
        int64_t timeout_ms) {
    Task t;
    t.kind = TaskKind::SyncChannel;
    t.u64_a = channel_id;
    t.i64_a = channel_type;
    t.u64_b = (uint64_t)timeout_ms;
    return enqueue_task(std::move(t));
}

uint64_t PrivchatNativeClient::get_message_by_id(uint64_t message_id, int64_t timeout_ms) {
    Task t;
    t.kind = TaskKind::GetMessageById;
    t.u64_a = message_id;
    t.u64_b = (uint64_t)timeout_ms;
    return enqueue_task(std::move(t));
}

// ---------------------------------------------------------------------------
// Sync getters (short blocking calls)
// ---------------------------------------------------------------------------

String PrivchatNativeClient::connection_state_sync(int64_t timeout_ms) {
    PrivchatCapiClient *c = nullptr;
    {
        std::lock_guard<std::mutex> lock(client_mutex);
        c = client;
    }
    if (c == nullptr) {
        return "";
    }
    char *out = privchat_capi_connection_state(c, (uint64_t)timeout_ms);
    if (out == nullptr) {
        return "";
    }
    String result = String::utf8(out);
    privchat_capi_free_string(out);
    // c-api returns a JSON-encoded string ("\"Authenticated\""); unwrap it.
    Variant parsed = JSON::parse_string(result);
    return parsed.get_type() == Variant::STRING ? String(parsed) : result;
}

String PrivchatNativeClient::session_snapshot_sync(int64_t timeout_ms) {
    PrivchatCapiClient *c = nullptr;
    {
        std::lock_guard<std::mutex> lock(client_mutex);
        c = client;
    }
    if (c == nullptr) {
        return "";
    }
    char *out = privchat_capi_session_snapshot(c, (uint64_t)timeout_ms);
    if (out == nullptr) {
        return "";
    }
    String result = String::utf8(out);
    privchat_capi_free_string(out);
    return result;
}

String PrivchatNativeClient::recent_events_sync(int64_t limit) {
    PrivchatCapiClient *c = nullptr;
    {
        std::lock_guard<std::mutex> lock(client_mutex);
        c = client;
    }
    if (c == nullptr) {
        return "[]";
    }
    char *out = privchat_capi_recent_events(c, (uint64_t)limit);
    if (out == nullptr) {
        return "[]";
    }
    String result = String::utf8(out);
    privchat_capi_free_string(out);
    return result;
}

// ---------------------------------------------------------------------------
// Bindings
// ---------------------------------------------------------------------------

void PrivchatNativeClient::_bind_methods() {
    ClassDB::bind_method(D_METHOD("initialize", "config_json"), &PrivchatNativeClient::initialize);
    ClassDB::bind_method(D_METHOD("shutdown"), &PrivchatNativeClient::shutdown);
    ClassDB::bind_method(D_METHOD("is_initialized"), &PrivchatNativeClient::is_initialized);

    ClassDB::bind_method(D_METHOD("authenticate", "user_id", "token", "device_id", "timeout_ms"),
            &PrivchatNativeClient::authenticate, DEFVAL((int64_t)15000));
    ClassDB::bind_method(D_METHOD("connect_async", "timeout_ms"),
            &PrivchatNativeClient::connect_async, DEFVAL((int64_t)15000));
    ClassDB::bind_method(D_METHOD("disconnect_async", "timeout_ms"),
            &PrivchatNativeClient::disconnect_async, DEFVAL((int64_t)10000));
    ClassDB::bind_method(D_METHOD("run_bootstrap_sync", "timeout_ms"),
            &PrivchatNativeClient::run_bootstrap_sync, DEFVAL((int64_t)30000));
    ClassDB::bind_method(D_METHOD("subscribe_channel", "channel_id", "channel_type", "token", "timeout_ms"),
            &PrivchatNativeClient::subscribe_channel, DEFVAL(String()), DEFVAL((int64_t)10000));
    ClassDB::bind_method(D_METHOD("unsubscribe_channel", "channel_id", "channel_type", "timeout_ms"),
            &PrivchatNativeClient::unsubscribe_channel, DEFVAL((int64_t)10000));
    ClassDB::bind_method(D_METHOD("send_text_message", "channel_id", "channel_type", "from_uid", "content", "timeout_ms"),
            &PrivchatNativeClient::send_text_message, DEFVAL((int64_t)10000));
    ClassDB::bind_method(D_METHOD("transfer", "channel_id", "route", "body", "timeout_ms"),
            &PrivchatNativeClient::transfer, DEFVAL((int64_t)8000));
    ClassDB::bind_method(D_METHOD("rpc_call", "route", "body_json", "timeout_ms"),
            &PrivchatNativeClient::rpc_call, DEFVAL((int64_t)8000));
    ClassDB::bind_method(D_METHOD("sync_channel", "channel_id", "channel_type", "timeout_ms"),
            &PrivchatNativeClient::sync_channel, DEFVAL((int64_t)15000));
    ClassDB::bind_method(D_METHOD("get_message_by_id", "message_id", "timeout_ms"),
            &PrivchatNativeClient::get_message_by_id, DEFVAL((int64_t)8000));

    ClassDB::bind_method(D_METHOD("connection_state_sync", "timeout_ms"),
            &PrivchatNativeClient::connection_state_sync, DEFVAL((int64_t)2000));
    ClassDB::bind_method(D_METHOD("session_snapshot_sync", "timeout_ms"),
            &PrivchatNativeClient::session_snapshot_sync, DEFVAL((int64_t)2000));
    ClassDB::bind_method(D_METHOD("recent_events_sync", "limit"),
            &PrivchatNativeClient::recent_events_sync, DEFVAL((int64_t)50));

    ADD_SIGNAL(MethodInfo("request_completed",
            PropertyInfo(Variant::INT, "request_id"),
            PropertyInfo(Variant::INT, "kind"),
            PropertyInfo(Variant::BOOL, "ok"),
            PropertyInfo(Variant::STRING, "payload"),
            PropertyInfo(Variant::STRING, "error")));
    ADD_SIGNAL(MethodInfo("message_sent",
            PropertyInfo(Variant::INT, "request_id"),
            PropertyInfo(Variant::BOOL, "ok"),
            PropertyInfo(Variant::INT, "message_id"),
            PropertyInfo(Variant::STRING, "error")));
    ADD_SIGNAL(MethodInfo("sdk_event",
            PropertyInfo(Variant::INT, "sequence_id"),
            PropertyInfo(Variant::INT, "timestamp_ms"),
            PropertyInfo(Variant::STRING, "kind"),
            PropertyInfo(Variant::STRING, "event_json")));
    ADD_SIGNAL(MethodInfo("connection_state_changed",
            PropertyInfo(Variant::STRING, "from_state"),
            PropertyInfo(Variant::STRING, "to_state")));
}

} // namespace godot
