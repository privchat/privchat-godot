// privchat_native_client.h
//
// Godot-side wrapper of privchat-sdk-c-api. Threading model:
// - All blocking SDK calls run on a dedicated worker thread (task queue).
// - Results and polled SDK events are marshalled back to the main thread
//   via a mutex-guarded result queue drained in _process(), then emitted
//   as signals. JSON strings cross every boundary; no SDK types leak into
//   GDScript.
#pragma once

#include <godot_cpp/classes/node.hpp>

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <deque>
#include <mutex>
#include <string>
#include <thread>

#include "privchat_sdk_c_api.h"

namespace godot {

class PrivchatNativeClient : public Node {
    GDCLASS(PrivchatNativeClient, Node)

public:
    enum class TaskKind {
        Authenticate,
        Connect,
        Disconnect,
        Shutdown,
        Subscribe,
        Unsubscribe,
        SendText,
        Transfer,
        RpcCall,
        SyncChannel,
        GetMessageById,
        BootstrapSync,
    };

    struct Task {
        uint64_t request_id = 0;
        TaskKind kind = TaskKind::Connect;
        // Argument slots used per-kind (strings/ints kept as plain fields).
        uint64_t u64_a = 0;
        uint64_t u64_b = 0;
        int64_t i64_a = 0;
        std::string str_a;
        std::string str_b;
        std::string str_c;
    };

    struct TaskResult {
        uint64_t request_id = 0;
        TaskKind kind = TaskKind::Connect;
        bool ok = false;
        int32_t code = 0;
        std::string payload; // JSON result when applicable
        std::string error;
        uint64_t message_id = 0; // send_text local message id
    };

private:
    PrivchatCapiClient *client = nullptr;
    std::mutex client_mutex; // guards create/destroy of `client`

    std::thread worker;
    std::atomic<bool> worker_running{ false };
    std::atomic<bool> stop_requested{ false };
    std::mutex queue_mutex;
    std::condition_variable queue_cv;
    std::deque<Task> task_queue;

    std::mutex result_mutex;
    std::deque<TaskResult> result_queue;

    std::atomic<uint64_t> next_request_id{ 1 };
    std::atomic<uint64_t> event_cursor{ 0 };
    double poll_accumulator = 0.0;
    bool initialized = false;

    void worker_loop();
    void run_task(const Task &task);
    TaskResult make_error(const Task &task, const char *fallback);
    void push_result(TaskResult result);
    void drain_results();
    void poll_events();
    uint64_t enqueue_task(Task task);
    std::string last_error_or(const char *fallback);

protected:
    static void _bind_methods();
    void _notification(int p_what);

public:
    // --- lifecycle -----------------------------------------------------
    // config_json: serialized PrivchatConfig (see privchat_sdk_c_api.h).
    bool initialize(const String &config_json);
    void shutdown();
    bool is_initialized() const;

    // --- async operations (results via signals) ------------------------
    uint64_t authenticate(uint64_t user_id, const String &token, const String &device_id, int64_t timeout_ms);
    uint64_t connect_async(int64_t timeout_ms);
    uint64_t disconnect_async(int64_t timeout_ms);
    uint64_t run_bootstrap_sync(int64_t timeout_ms);
    uint64_t subscribe_channel(uint64_t channel_id, int64_t channel_type, const String &token, int64_t timeout_ms);
    uint64_t unsubscribe_channel(uint64_t channel_id, int64_t channel_type, int64_t timeout_ms);
    uint64_t send_text_message(uint64_t channel_id, int64_t channel_type, uint64_t from_uid, const String &content, int64_t timeout_ms);
    uint64_t transfer(uint64_t channel_id, const String &route, const String &body, int64_t timeout_ms);
    uint64_t rpc_call(const String &route, const String &body_json, int64_t timeout_ms);
    uint64_t sync_channel(uint64_t channel_id, int64_t channel_type, int64_t timeout_ms);
    uint64_t get_message_by_id(uint64_t message_id, int64_t timeout_ms);

    // --- sync getters (short blocking calls, main-thread safe) ---------
    String connection_state_sync(int64_t timeout_ms);
    String session_snapshot_sync(int64_t timeout_ms);
    String recent_events_sync(int64_t limit);

    PrivchatNativeClient();
    ~PrivchatNativeClient();
};

} // namespace godot
