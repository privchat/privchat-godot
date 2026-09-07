// privchat_flatbuffers.h
//
// Generic, game-agnostic FlatBuffers codec for GDScript
// (privchat-docs spec 04-client/GODOT_FLATBUFFERS_CODEC_SPEC.md).
//
// Loads a binary schema (.bfbs) at runtime and converts Dictionary <->
// FlatBuffers by reflection. No business type ever appears here: the
// mmorpg (or any other) protocol lives in its own .fbs files, the game
// logic in GDScript. The transport (transfer_bytes, subscription payloads)
// is untouched — this class only turns bytes into Dictionaries and back.
#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/string.hpp>

#include <cstdint>
#include <memory>
#include <vector>

namespace reflection {
struct Schema;
}

namespace godot {

/// Immutable handle returned by PrivchatFlatBuffers::load_schema (spec §2).
/// Different schema versions coexist as different handles; nothing is
/// overwritten by name.
class PrivchatFlatBuffersSchema : public RefCounted {
    GDCLASS(PrivchatFlatBuffersSchema, RefCounted)

public:
    PrivchatFlatBuffersSchema();
    ~PrivchatFlatBuffersSchema() override;

    /// Fully qualified root/table names declared in the schema.
    PackedStringArray get_roots() const;
    /// file_identifier of the schema's root_type ("" when absent).
    String get_root_identifier() const;
    /// Fully qualified name of root_type ("" when absent).
    String get_root_type() const;
    /// sha256 hex of the .bfbs bytes; clients pin this (spec §7).
    String get_digest() const;

    // Internal (not bound): backing bytes and parsed view.
    bool _load(const PackedByteArray &bfbs, String &error);
    const reflection::Schema *schema() const { return schema_; }

protected:
    static void _bind_methods();

private:
    std::vector<uint8_t> bytes_;
    const reflection::Schema *schema_ = nullptr;
    String digest_;
};

class PrivchatFlatBuffers : public RefCounted {
    GDCLASS(PrivchatFlatBuffers, RefCounted)

public:
    /// { ok, error, schema: PrivchatFlatBuffersSchema }
    Dictionary load_schema(const PackedByteArray &bfbs);
    /// { ok, error, data: PackedByteArray }
    Dictionary encode(const Ref<PrivchatFlatBuffersSchema> &schema, const String &root, const Dictionary &value);
    /// { ok, error, data: Dictionary }. Always verifies (spec §3.6).
    Dictionary decode(const Ref<PrivchatFlatBuffersSchema> &schema, const PackedByteArray &bytes, const String &root);

    /// Resource budgets (spec §3.6). Setters clamp to the hard limits.
    void set_max_bytes(int64_t v);
    int64_t get_max_bytes() const { return max_bytes_; }
    void set_max_vector_len(int64_t v);
    int64_t get_max_vector_len() const { return max_vector_len_; }
    void set_max_objects(int64_t v);
    int64_t get_max_objects() const { return max_objects_; }

protected:
    static void _bind_methods();

private:
    int64_t max_bytes_ = 1 << 20;
    int64_t max_vector_len_ = 65536;
    int64_t max_objects_ = 200000;
};

} // namespace godot
