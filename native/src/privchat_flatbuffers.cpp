// privchat_flatbuffers.cpp — see privchat_flatbuffers.h.
//
// Conversion rules implemented here are the frozen ones from
// GODOT_FLATBUFFERS_CODEC_SPEC §3; each rule is referenced inline so a
// reader can check behaviour against the contract rather than against
// the author's memory.
#include "privchat_flatbuffers.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include "flatbuffers/flatbuffers.h"
#include "flatbuffers/reflection.h"
#include "flatbuffers/reflection_generated.h"

#include <algorithm>
#include <cstring>
#include <string>

using namespace godot;

namespace {

// ---------------------------------------------------------------------------
// sha256 (FIPS 180-4), self-contained so the digest does not depend on any
// engine class being available in headless/tool contexts.
// ---------------------------------------------------------------------------
struct Sha256 {
    uint32_t h[8] = {0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19};
    uint64_t len = 0;
    uint8_t buf[64];
    size_t buf_len = 0;

    static uint32_t rotr(uint32_t x, int n) { return (x >> n) | (x << (32 - n)); }

    void block(const uint8_t *p) {
        static const uint32_t k[64] = {
            0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
            0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
            0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
            0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
            0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
            0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
            0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
            0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2};
        uint32_t w[64];
        for (int i = 0; i < 16; ++i) {
            w[i] = (uint32_t(p[i * 4]) << 24) | (uint32_t(p[i * 4 + 1]) << 16) | (uint32_t(p[i * 4 + 2]) << 8) | uint32_t(p[i * 4 + 3]);
        }
        for (int i = 16; i < 64; ++i) {
            uint32_t s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3);
            uint32_t s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10);
            w[i] = w[i - 16] + s0 + w[i - 7] + s1;
        }
        uint32_t a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7];
        for (int i = 0; i < 64; ++i) {
            uint32_t s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25);
            uint32_t ch = (e & f) ^ (~e & g);
            uint32_t t1 = hh + s1 + ch + k[i] + w[i];
            uint32_t s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22);
            uint32_t maj = (a & b) ^ (a & c) ^ (b & c);
            uint32_t t2 = s0 + maj;
            hh = g; g = f; f = e; e = d + t1; d = c; c = b; b = a; a = t1 + t2;
        }
        h[0] += a; h[1] += b; h[2] += c; h[3] += d; h[4] += e; h[5] += f; h[6] += g; h[7] += hh;
    }

    void update(const uint8_t *p, size_t n) {
        len += n;
        while (n > 0) {
            size_t take = std::min(n, 64 - buf_len);
            memcpy(buf + buf_len, p, take);
            buf_len += take; p += take; n -= take;
            if (buf_len == 64) { block(buf); buf_len = 0; }
        }
    }

    std::string hex() {
        uint64_t bits = len * 8;
        uint8_t pad = 0x80;
        update(&pad, 1);
        uint8_t zero = 0;
        while (buf_len != 56) update(&zero, 1);
        uint8_t lenb[8];
        for (int i = 0; i < 8; ++i) lenb[i] = uint8_t(bits >> (56 - 8 * i));
        update(lenb, 8);
        static const char *digits = "0123456789abcdef";
        std::string out;
        for (int i = 0; i < 8; ++i) {
            for (int s = 28; s >= 0; s -= 4) out.push_back(digits[(h[i] >> s) & 0xF]);
        }
        return out;
    }
};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
constexpr int64_t HARD_MAX_BYTES = 8 << 20;
constexpr int64_t HARD_MAX_VECTOR_LEN = 1048576;
constexpr int64_t HARD_MAX_OBJECTS = 1000000;
constexpr int MAX_DEPTH = 64;

Dictionary fail(const String &error) {
    Dictionary d;
    d["ok"] = false;
    d["error"] = error;
    return d;
}

std::string gd(const String &s) { return std::string(s.utf8().get_data()); }
String to_gd(const std::string &s) { return String::utf8(s.c_str(), int(s.size())); }

/// Errors carry the path to the offending field (spec §3.7).
struct Ctx {
    const reflection::Schema *schema;
    std::string error;
    std::string path;
    int depth = 0;
    int64_t objects = 0;
    int64_t max_vector_len;
    int64_t max_objects;

    bool err(const std::string &reason) {
        if (error.empty()) error = path + ": " + reason;
        return false;
    }
    struct Scope {
        Ctx &c; size_t saved; 
        Scope(Ctx &ctx, const std::string &seg) : c(ctx), saved(ctx.path.size()) { c.path += "." + seg; c.depth++; }
        ~Scope() { c.path.resize(saved); c.depth--; }
    };
};

/// snake_case of a union member's (type) name: "MoveTo" -> "move_to",
/// "CastSkill" -> "cast_skill". Matches the JSON-mirror convention.
std::string snake(const std::string &name) {
    std::string out;
    for (size_t i = 0; i < name.size(); ++i) {
        char ch = name[i];
        if (ch >= 'A' && ch <= 'Z') {
            bool prev_lower = i > 0 && ((name[i - 1] >= 'a' && name[i - 1] <= 'z') || (name[i - 1] >= '0' && name[i - 1] <= '9'));
            bool next_lower = i + 1 < name.size() && name[i + 1] >= 'a' && name[i + 1] <= 'z';
            if (i > 0 && (prev_lower || next_lower)) out.push_back('_');
            out.push_back(char(ch - 'A' + 'a'));
        } else {
            out.push_back(ch);
        }
    }
    return out;
}

const reflection::Object *find_object(const reflection::Schema &schema, const std::string &name) {
    return schema.objects()->LookupByKey(name.c_str());
}

const reflection::Enum *enum_at(const reflection::Schema &schema, int index) {
    if (index < 0 || index >= int(schema.enums()->size())) return nullptr;
    return schema.enums()->Get(index);
}

const reflection::Object *object_at(const reflection::Schema &schema, int index) {
    if (index < 0 || index >= int(schema.objects()->size())) return nullptr;
    return schema.objects()->Get(index);
}

bool is_int_type(reflection::BaseType t) {
    return t >= reflection::Byte && t <= reflection::ULong;
}
bool is_float_type(reflection::BaseType t) { return t == reflection::Float || t == reflection::Double; }

bool int_in_range(reflection::BaseType t, int64_t v) {
    switch (t) {
        case reflection::Byte: return v >= -128 && v <= 127;
        case reflection::UByte: return v >= 0 && v <= 255;
        case reflection::Short: return v >= -32768 && v <= 32767;
        case reflection::UShort: return v >= 0 && v <= 65535;
        case reflection::Int: return v >= INT32_MIN && v <= INT32_MAX;
        case reflection::UInt: return v >= 0 && v <= int64_t(UINT32_MAX);
        case reflection::Long: return true;
        case reflection::ULong: return v >= 0; // spec §3.2: ulong ≤ 2^63-1
        default: return false;
    }
}

/// Enum value lookup by name (spec §3.4). Returns false when unknown.
bool enum_by_name(const reflection::Enum &e, const std::string &name, int64_t &out) {
    for (auto v : *e.values()) {
        if (v->name()->str() == name) { out = v->value(); return true; }
    }
    return false;
}
const reflection::EnumVal *enum_by_value(const reflection::Enum &e, int64_t value) {
    for (auto v : *e.values()) {
        if (v->value() == value) return v;
    }
    return nullptr;
}

// ---------------------------------------------------------------------------
// Encode: Dictionary -> FlatBuffers (spec §3)
// ---------------------------------------------------------------------------
struct Encoder {
    Ctx &ctx;
    flatbuffers::FlatBufferBuilder &fbb;

    /// Scalar Variant -> int64 with the strict typing of §3.2: integers only
    /// accept int, never float (a large ID that passed through a double may
    /// already have lost precision; checking for a fractional part cannot
    /// undo that).
    bool read_int(const Variant &v, reflection::BaseType t, const reflection::Enum *en, int64_t &out) {
        if (en != nullptr) {
            if (v.get_type() == Variant::STRING) {
                if (!enum_by_name(*en, gd(v), out)) return ctx.err("unknown enum value '" + gd(v) + "' for " + en->name()->str());
                return true;
            }
            if (v.get_type() != Variant::INT) return ctx.err("enum expects a name or int");
            out = int64_t(v);
            return int_in_range(t, out) ? true : ctx.err("enum value out of range");
        }
        if (t == reflection::Bool) {
            if (v.get_type() != Variant::BOOL) return ctx.err("expected bool");
            out = bool(v) ? 1 : 0;
            return true;
        }
        if (v.get_type() != Variant::INT) return ctx.err(std::string("expected int, got ") + gd(Variant::get_type_name(v.get_type())));
        out = int64_t(v);
        if (!int_in_range(t, out)) return ctx.err(t == reflection::ULong ? "ulong out of int range (must be 0..2^63-1)" : "out of range");
        return true;
    }

    bool read_float(const Variant &v, reflection::BaseType t, double &out) {
        if (v.get_type() != Variant::FLOAT) return ctx.err("expected float");
        out = double(v);
        if (std::isnan(out) || std::isinf(out)) return ctx.err("non-finite float");
        if (t == reflection::Float && std::fabs(out) > 3.4028234663852886e38) return ctx.err("out of float range");
        return true;
    }

    /// Struct fields are inline and mandatory (spec §3.5).
    bool write_struct(const reflection::Object &obj, const Dictionary &value, uint8_t *dst) {
        if (!check_keys(obj, value, /*is_struct=*/true)) return false;
        for (auto field : *obj.fields()) {
            Ctx::Scope scope(ctx, field->name()->str());
            if (!value.has(to_gd(field->name()->str()))) return ctx.err("struct field is mandatory");
            Variant v = value[to_gd(field->name()->str())];
            auto t = field->type()->base_type();
            uint8_t *at = dst + field->offset();
            if (t == reflection::Obj) {
                auto sub = object_at(*ctx.schema, field->type()->index());
                if (sub == nullptr || !sub->is_struct()) return ctx.err("unsupported struct member");
                if (v.get_type() != Variant::DICTIONARY) return ctx.err("expected Dictionary");
                if (!write_struct(*sub, v, at)) return false;
            } else if (is_float_type(t)) {
                double d; if (!read_float(v, t, d)) return false;
                if (t == reflection::Float) { float f = float(d); memcpy(at, &f, 4); } else { memcpy(at, &d, 8); }
            } else {
                int64_t i; if (!read_int(v, t, enum_at(*ctx.schema, field->type()->index()), i)) return false;
                switch (flatbuffers::GetTypeSize(t)) {
                    case 1: { uint8_t x = uint8_t(i); memcpy(at, &x, 1); break; }
                    case 2: { uint16_t x = uint16_t(i); memcpy(at, &x, 2); break; }
                    case 4: { uint32_t x = uint32_t(i); memcpy(at, &x, 4); break; }
                    default: { uint64_t x = uint64_t(i); memcpy(at, &x, 8); break; }
                }
            }
        }
        return true;
    }

    /// Unknown keys are rejected, nested too (spec §3.1). Union members are
    /// referenced by their own key, so the "<name>_type" field is implicit.
    bool check_keys(const reflection::Object &obj, const Dictionary &value, bool is_struct) {
        Array keys = value.keys();
        for (int i = 0; i < keys.size(); ++i) {
            if (keys[i].get_type() != Variant::STRING) return ctx.err("non-string key");
            std::string k = gd(keys[i]);
            const reflection::Field *f = obj.fields()->LookupByKey(k.c_str());
            if (f == nullptr) return ctx.err("unknown field " + k);
            if (f->deprecated()) return ctx.err("field " + k + " is deprecated");
            if (!is_struct && f->type()->base_type() == reflection::UType) return ctx.err("union type field " + k + " is implicit; set the union key instead");
        }
        return true;
    }

    bool count_object() {
        if (++ctx.objects > ctx.max_objects) return ctx.err("object budget exceeded");
        if (ctx.depth > MAX_DEPTH) return ctx.err("nesting too deep");
        return true;
    }

    /// Builds one union member; returns its offset and the discriminator.
    bool encode_union(const reflection::Field &field, const Variant &v, flatbuffers::uoffset_t &off, int64_t &type_value) {
        if (v.get_type() != Variant::DICTIONARY) return ctx.err("union expects a single-key Dictionary");
        Dictionary d = v;
        if (d.size() != 1) return ctx.err("union must have exactly one key");
        std::string key = gd(d.keys()[0]);
        auto en = enum_at(*ctx.schema, field.type()->index());
        if (en == nullptr) return ctx.err("union enum missing");
        for (auto ev : *en->values()) {
            if (ev->value() == 0) continue;
            if (snake(ev->name()->str()) != key && ev->name()->str() != key) continue;
            auto member = ev->union_type();
            if (member == nullptr || member->base_type() != reflection::Obj) return ctx.err("unsupported union member kind");
            auto obj = object_at(*ctx.schema, member->index());
            if (obj == nullptr || obj->is_struct()) return ctx.err("union of struct is not supported");
            Variant body = d[d.keys()[0]];
            if (body.get_type() != Variant::DICTIONARY) return ctx.err("union member expects Dictionary");
            Ctx::Scope scope(ctx, key);
            if (!encode_table(*obj, body, off)) return false;
            type_value = ev->value();
            return true;
        }
        return ctx.err("unknown union member '" + key + "'");
    }

    bool encode_vector(const reflection::Field &field, const Variant &v, flatbuffers::uoffset_t &off) {
        auto et = field.type()->element();
        // [ubyte] is raw bytes only when it is not an enum vector: a vector of a
        // ubyte-backed enum (e.g. [CommandKind]) is a list of names (spec §3.3/§3.4).
        const bool enum_vector = is_int_type(et) && field.type()->index() >= 0;
        if (et == reflection::UByte && !enum_vector && v.get_type() == Variant::PACKED_BYTE_ARRAY) {
            PackedByteArray b = v;
            if (int64_t(b.size()) > ctx.max_vector_len) return ctx.err("vector too long");
            off = fbb.CreateVector(b.ptr(), size_t(b.size())).o;
            return true;
        }
        if (et == reflection::String && v.get_type() == Variant::PACKED_STRING_ARRAY) {
            PackedStringArray a = v;
            if (int64_t(a.size()) > ctx.max_vector_len) return ctx.err("vector too long");
            std::vector<flatbuffers::Offset<flatbuffers::String>> offs;
            for (int i = 0; i < a.size(); ++i) offs.push_back(fbb.CreateString(gd(a[i])));
            off = fbb.CreateVector(offs).o;
            return true;
        }
        if (v.get_type() != Variant::ARRAY) return ctx.err("expected Array");
        Array a = v;
        if (int64_t(a.size()) > ctx.max_vector_len) return ctx.err("vector too long");
        if (et == reflection::String) {
            std::vector<flatbuffers::Offset<flatbuffers::String>> offs;
            for (int i = 0; i < a.size(); ++i) {
                if (a[i].get_type() != Variant::STRING) return ctx.err("expected String element");
                offs.push_back(fbb.CreateString(gd(a[i])));
            }
            off = fbb.CreateVector(offs).o;
            return true;
        }
        if (et == reflection::Obj) {
            auto obj = object_at(*ctx.schema, field.type()->index());
            if (obj == nullptr) return ctx.err("vector element type missing");
            if (obj->is_struct()) {
                size_t sz = obj->bytesize();
                std::vector<uint8_t> raw(sz * size_t(a.size()), 0);
                for (int i = 0; i < a.size(); ++i) {
                    Ctx::Scope scope(ctx, std::to_string(i));
                    if (a[i].get_type() != Variant::DICTIONARY) return ctx.err("expected Dictionary element");
                    if (!write_struct(*obj, a[i], raw.data() + sz * size_t(i))) return false;
                }
                fbb.StartVector(size_t(a.size()), sz, obj->minalign());
                fbb.PushBytes(raw.data(), raw.size());
                off = fbb.EndVector(size_t(a.size()));
                return true;
            }
            std::vector<flatbuffers::Offset<void>> offs;
            for (int i = 0; i < a.size(); ++i) {
                Ctx::Scope scope(ctx, std::to_string(i));
                if (a[i].get_type() != Variant::DICTIONARY) return ctx.err("expected Dictionary element");
                flatbuffers::uoffset_t o;
                if (!encode_table(*obj, a[i], o)) return false;
                offs.push_back(flatbuffers::Offset<void>(o));
            }
            std::reverse(offs.begin(), offs.end()); // CreateVector expects natural order; we built in order
            std::reverse(offs.begin(), offs.end());
            off = fbb.CreateVector(offs).o;
            return true;
        }
        if (et == reflection::Union) return ctx.err("vectors of unions are not supported");
        // Scalars.
        size_t esz = flatbuffers::GetTypeSize(et);
        auto en = enum_at(*ctx.schema, field.type()->index());
        std::vector<uint8_t> raw(esz * size_t(a.size()), 0);
        for (int i = 0; i < a.size(); ++i) {
            Ctx::Scope scope(ctx, std::to_string(i));
            uint8_t *at = raw.data() + esz * size_t(i);
            if (is_float_type(et)) {
                double d; if (!read_float(a[i], et, d)) return false;
                if (et == reflection::Float) { float f = float(d); memcpy(at, &f, 4); } else { memcpy(at, &d, 8); }
            } else {
                int64_t iv; if (!read_int(a[i], et, is_int_type(et) ? en : nullptr, iv)) return false;
                switch (esz) {
                    case 1: { uint8_t x = uint8_t(iv); memcpy(at, &x, 1); break; }
                    case 2: { uint16_t x = uint16_t(iv); memcpy(at, &x, 2); break; }
                    case 4: { uint32_t x = uint32_t(iv); memcpy(at, &x, 4); break; }
                    default: { uint64_t x = uint64_t(iv); memcpy(at, &x, 8); break; }
                }
            }
        }
        fbb.StartVector(size_t(a.size()), esz, esz);
        fbb.PushBytes(raw.data(), raw.size());
        off = fbb.EndVector(size_t(a.size()));
        return true;
    }

    bool encode_table(const reflection::Object &obj, const Dictionary &value, flatbuffers::uoffset_t &out) {
        if (!count_object()) return false;
        if (!check_keys(obj, value, false)) return false;
        // Pass 1: everything that lives outside the table (strings, vectors,
        // sub-tables, union members) must be built before StartTable.
        struct Pending { const reflection::Field *field; flatbuffers::uoffset_t off; int64_t union_type; };
        std::vector<Pending> offsets;
        for (auto field : *obj.fields()) {
            String key = to_gd(field->name()->str());
            if (!value.has(key)) continue;
            auto t = field->type()->base_type();
            if (t != reflection::String && t != reflection::Vector && t != reflection::Obj && t != reflection::Union) continue;
            if (t == reflection::Obj && object_at(*ctx.schema, field->type()->index())->is_struct()) continue;
            Ctx::Scope scope(ctx, field->name()->str());
            Variant v = value[key];
            Pending p{field, 0, 0};
            if (t == reflection::String) {
                if (v.get_type() != Variant::STRING) return ctx.err("expected String");
                p.off = fbb.CreateString(gd(v)).o;
            } else if (t == reflection::Vector) {
                if (!encode_vector(*field, v, p.off)) return false;
            } else if (t == reflection::Obj) {
                if (v.get_type() != Variant::DICTIONARY) return ctx.err("expected Dictionary");
                if (!encode_table(*object_at(*ctx.schema, field->type()->index()), v, p.off)) return false;
            } else {
                if (!encode_union(*field, v, p.off, p.union_type)) return false;
            }
            offsets.push_back(p);
        }
        // Pass 2: the table itself.
        auto start = fbb.StartTable();
        for (auto field : *obj.fields()) {
            String key = to_gd(field->name()->str());
            auto t = field->type()->base_type();
            if (t == reflection::UType) continue; // written with its union below
            if (t == reflection::String || t == reflection::Vector || t == reflection::Union ||
                (t == reflection::Obj && !object_at(*ctx.schema, field->type()->index())->is_struct())) {
                for (auto &p : offsets) {
                    if (p.field != field) continue;
                    fbb.AddOffset(field->offset(), flatbuffers::Offset<void>(p.off));
                    if (t == reflection::Union) {
                        // The discriminator field is named "<field>_type" and always precedes the value.
                        std::string tname = field->name()->str() + "_type";
                        auto tf = obj.fields()->LookupByKey(tname.c_str());
                        if (tf == nullptr) return ctx.err("union type field missing");
                        fbb.AddElement<uint8_t>(tf->offset(), uint8_t(p.union_type), 0);
                    }
                }
                continue;
            }
            if (!value.has(key)) continue; // absent scalar = default (spec §3.1)
            Ctx::Scope scope(ctx, field->name()->str());
            Variant v = value[key];
            if (t == reflection::Obj) {
                auto sub = object_at(*ctx.schema, field->type()->index());
                if (v.get_type() != Variant::DICTIONARY) return ctx.err("expected Dictionary");
                std::vector<uint8_t> raw(sub->bytesize(), 0);
                if (!write_struct(*sub, v, raw.data())) return false;
                fbb.Align(sub->minalign());
                fbb.PushBytes(raw.data(), raw.size());
                fbb.AddStructOffset(field->offset(), fbb.GetSize());
            } else if (is_float_type(t)) {
                double d; if (!read_float(v, t, d)) return false;
                if (t == reflection::Float) fbb.AddElement<float>(field->offset(), float(d), float(field->default_real()));
                else fbb.AddElement<double>(field->offset(), d, field->default_real());
            } else {
                int64_t i; if (!read_int(v, t, enum_at(*ctx.schema, field->type()->index()), i)) return false;
                // Always write: defaults are compared by the builder per type.
                switch (flatbuffers::GetTypeSize(t)) {
                    case 1: fbb.AddElement<uint8_t>(field->offset(), uint8_t(i), uint8_t(field->default_integer())); break;
                    case 2: fbb.AddElement<uint16_t>(field->offset(), uint16_t(i), uint16_t(field->default_integer())); break;
                    case 4: fbb.AddElement<uint32_t>(field->offset(), uint32_t(i), uint32_t(field->default_integer())); break;
                    default: fbb.AddElement<uint64_t>(field->offset(), uint64_t(i), uint64_t(field->default_integer())); break;
                }
            }
        }
        // Required fields (spec §3.1: verifier rejects on decode; encode refuses to build).
        for (auto field : *obj.fields()) {
            if (field->required() && !value.has(to_gd(field->name()->str()))) {
                Ctx::Scope scope(ctx, field->name()->str());
                return ctx.err("required field missing");
            }
        }
        out = fbb.EndTable(start);
        return true;
    }
};

// ---------------------------------------------------------------------------
// Decode: FlatBuffers -> Dictionary (spec §3)
// ---------------------------------------------------------------------------
struct Decoder {
    Ctx &ctx;

    Variant scalar_from(int64_t raw, reflection::BaseType t, const reflection::Enum *en) {
        if (t == reflection::Bool) return Variant(raw != 0);
        if (en != nullptr) {
            // Known value -> name; unknown -> int (spec §3.4).
            auto ev = enum_by_value(*en, raw);
            if (ev != nullptr) return Variant(to_gd(ev->name()->str()));
            return Variant(raw);
        }
        return Variant(raw);
    }

    bool read_scalar_bytes(const uint8_t *at, reflection::BaseType t, int64_t &out) {
        switch (t) {
            case reflection::Bool: case reflection::UByte: { uint8_t x; memcpy(&x, at, 1); out = x; return true; }
            case reflection::Byte: { int8_t x; memcpy(&x, at, 1); out = x; return true; }
            case reflection::Short: { int16_t x; memcpy(&x, at, 2); out = x; return true; }
            case reflection::UShort: { uint16_t x; memcpy(&x, at, 2); out = x; return true; }
            case reflection::Int: { int32_t x; memcpy(&x, at, 4); out = x; return true; }
            case reflection::UInt: { uint32_t x; memcpy(&x, at, 4); out = x; return true; }
            case reflection::Long: { int64_t x; memcpy(&x, at, 8); out = x; return true; }
            case reflection::ULong: {
                uint64_t x; memcpy(&x, at, 8);
                if (x > uint64_t(INT64_MAX)) return ctx.err("ulong out of int range");
                out = int64_t(x); return true;
            }
            default: return ctx.err("not an integer");
        }
    }

    bool decode_struct(const reflection::Object &obj, const uint8_t *base, Dictionary &out) {
        if (!count_object()) return false;
        for (auto field : *obj.fields()) {
            Ctx::Scope scope(ctx, field->name()->str());
            auto t = field->type()->base_type();
            const uint8_t *at = base + field->offset();
            String key = to_gd(field->name()->str());
            if (t == reflection::Obj) {
                Dictionary sub;
                if (!decode_struct(*object_at(*ctx.schema, field->type()->index()), at, sub)) return false;
                out[key] = sub;
            } else if (t == reflection::Float) { float f; memcpy(&f, at, 4); out[key] = double(f); }
            else if (t == reflection::Double) { double d; memcpy(&d, at, 8); out[key] = d; }
            else {
                int64_t v; if (!read_scalar_bytes(at, t, v)) return false;
                out[key] = scalar_from(v, t, enum_at(*ctx.schema, field->type()->index()));
            }
        }
        return true;
    }

    bool count_object() {
        if (++ctx.objects > ctx.max_objects) return ctx.err("object budget exceeded");
        if (ctx.depth > MAX_DEPTH) return ctx.err("nesting too deep");
        return true;
    }

    bool decode_vector(const reflection::Field &field, const flatbuffers::Table &table, Variant &out) {
        auto et = field.type()->element();
        auto vec = flatbuffers::GetFieldAnyV(table, field);
        if (vec == nullptr) return true; // absent -> key omitted
        size_t n = vec->size();
        if (int64_t(n) > ctx.max_vector_len) return ctx.err("vector too long");
        const bool enum_vector = is_int_type(et) && field.type()->index() >= 0;
        if (et == reflection::UByte && !enum_vector) {
            PackedByteArray b; b.resize(int64_t(n));
            if (n > 0) memcpy(b.ptrw(), vec->Data(), n);
            out = b; return true;
        }
        if (et == reflection::String) {
            PackedStringArray a;
            auto sv = reinterpret_cast<const flatbuffers::Vector<flatbuffers::Offset<flatbuffers::String>> *>(vec);
            for (size_t i = 0; i < n; ++i) a.push_back(to_gd(sv->Get(flatbuffers::uoffset_t(i))->str()));
            out = a; return true;
        }
        Array a;
        if (et == reflection::Obj) {
            auto obj = object_at(*ctx.schema, field.type()->index());
            if (obj->is_struct()) {
                size_t sz = obj->bytesize();
                for (size_t i = 0; i < n; ++i) {
                    Ctx::Scope scope(ctx, std::to_string(i));
                    Dictionary d;
                    if (!decode_struct(*obj, vec->Data() + sz * i, d)) return false;
                    a.push_back(d);
                }
            } else {
                auto tv = reinterpret_cast<const flatbuffers::Vector<flatbuffers::Offset<flatbuffers::Table>> *>(vec);
                for (size_t i = 0; i < n; ++i) {
                    Ctx::Scope scope(ctx, std::to_string(i));
                    Dictionary d;
                    if (!decode_table(*obj, *tv->Get(flatbuffers::uoffset_t(i)), d)) return false;
                    a.push_back(d);
                }
            }
            out = a; return true;
        }
        if (et == reflection::Union) return ctx.err("vectors of unions are not supported");
        size_t esz = flatbuffers::GetTypeSize(et);
        auto en = enum_at(*ctx.schema, field.type()->index());
        for (size_t i = 0; i < n; ++i) {
            const uint8_t *at = vec->Data() + esz * i;
            if (et == reflection::Float) { float f; memcpy(&f, at, 4); a.push_back(double(f)); }
            else if (et == reflection::Double) { double d; memcpy(&d, at, 8); a.push_back(d); }
            else { int64_t v; if (!read_scalar_bytes(at, et, v)) return false; a.push_back(scalar_from(v, et, is_int_type(et) ? en : nullptr)); }
        }
        out = a; return true;
    }

    bool decode_table(const reflection::Object &obj, const flatbuffers::Table &table, Dictionary &out) {
        if (!count_object()) return false;
        for (auto field : *obj.fields()) {
            if (field->deprecated()) continue;
            auto t = field->type()->base_type();
            if (t == reflection::UType) continue;
            Ctx::Scope scope(ctx, field->name()->str());
            String key = to_gd(field->name()->str());
            switch (t) {
                case reflection::String: {
                    auto s = flatbuffers::GetFieldS(table, *field);
                    if (s != nullptr) out[key] = to_gd(s->str());
                    break;
                }
                case reflection::Vector: {
                    Variant v;
                    if (!decode_vector(*field, table, v)) return false;
                    if (v.get_type() != Variant::NIL) out[key] = v;
                    break;
                }
                case reflection::Obj: {
                    auto sub = object_at(*ctx.schema, field->type()->index());
                    if (sub->is_struct()) {
                        auto st = flatbuffers::GetFieldStruct(table, *field);
                        if (st != nullptr) { Dictionary d; if (!decode_struct(*sub, reinterpret_cast<const uint8_t *>(st), d)) return false; out[key] = d; }
                    } else {
                        auto tb = flatbuffers::GetFieldT(table, *field);
                        if (tb != nullptr) { Dictionary d; if (!decode_table(*sub, *tb, d)) return false; out[key] = d; }
                    }
                    break;
                }
                case reflection::Union: {
                    std::string tname = field->name()->str() + "_type";
                    auto tf = obj.fields()->LookupByKey(tname.c_str());
                    if (tf == nullptr) return ctx.err("union type field missing");
                    int64_t type_value = flatbuffers::GetFieldI<uint8_t>(table, *tf);
                    if (type_value == 0) break; // NONE -> key absent
                    auto en = enum_at(*ctx.schema, field->type()->index());
                    auto ev = en != nullptr ? enum_by_value(*en, type_value) : nullptr;
                    auto tb = flatbuffers::GetFieldT(table, *field);
                    Dictionary u;
                    if (ev == nullptr || ev->union_type() == nullptr || ev->union_type()->base_type() != reflection::Obj) {
                        // Unknown member from a newer schema: keep the header, do not interpret (spec §3.4.1).
                        Dictionary unknown; unknown["type"] = type_value; u["_unknown"] = unknown;
                        out[key] = u; break;
                    }
                    auto member = object_at(*ctx.schema, ev->union_type()->index());
                    Dictionary body;
                    if (tb != nullptr && !member->is_struct()) {
                        Ctx::Scope inner(ctx, snake(ev->name()->str()));
                        if (!decode_table(*member, *tb, body)) return false;
                    }
                    u[to_gd(snake(ev->name()->str()))] = body;
                    out[key] = u;
                    break;
                }
                case reflection::Float: out[key] = double(flatbuffers::GetFieldF<float>(table, *field)); break;
                case reflection::Double: out[key] = flatbuffers::GetFieldF<double>(table, *field); break;
                default: {
                    int64_t v;
                    switch (t) {
                        case reflection::Bool: case reflection::UByte: v = flatbuffers::GetFieldI<uint8_t>(table, *field); break;
                        case reflection::Byte: v = flatbuffers::GetFieldI<int8_t>(table, *field); break;
                        case reflection::Short: v = flatbuffers::GetFieldI<int16_t>(table, *field); break;
                        case reflection::UShort: v = flatbuffers::GetFieldI<uint16_t>(table, *field); break;
                        case reflection::Int: v = flatbuffers::GetFieldI<int32_t>(table, *field); break;
                        case reflection::UInt: v = flatbuffers::GetFieldI<uint32_t>(table, *field); break;
                        case reflection::Long: v = flatbuffers::GetFieldI<int64_t>(table, *field); break;
                        case reflection::ULong: {
                            uint64_t x = flatbuffers::GetFieldI<uint64_t>(table, *field);
                            if (x > uint64_t(INT64_MAX)) return ctx.err("ulong out of int range");
                            v = int64_t(x); break;
                        }
                        default: return ctx.err("unsupported scalar type");
                    }
                    // Defaults are written out on decode (spec §3.1).
                    out[key] = scalar_from(v, t, enum_at(*ctx.schema, field->type()->index()));
                }
            }
        }
        return true;
    }
};

} // namespace

// ---------------------------------------------------------------------------
// PrivchatFlatBuffersSchema
// ---------------------------------------------------------------------------
PrivchatFlatBuffersSchema::PrivchatFlatBuffersSchema() = default;
PrivchatFlatBuffersSchema::~PrivchatFlatBuffersSchema() = default;

void PrivchatFlatBuffersSchema::_bind_methods() {
    ClassDB::bind_method(D_METHOD("get_roots"), &PrivchatFlatBuffersSchema::get_roots);
    ClassDB::bind_method(D_METHOD("get_root_identifier"), &PrivchatFlatBuffersSchema::get_root_identifier);
    ClassDB::bind_method(D_METHOD("get_root_type"), &PrivchatFlatBuffersSchema::get_root_type);
    ClassDB::bind_method(D_METHOD("get_digest"), &PrivchatFlatBuffersSchema::get_digest);
}

bool PrivchatFlatBuffersSchema::_load(const PackedByteArray &bfbs, String &error) {
    bytes_.assign(bfbs.ptr(), bfbs.ptr() + bfbs.size());
    // The schema itself is untrusted input too (spec §3.6).
    flatbuffers::Verifier v(bytes_.data(), bytes_.size());
    if (!reflection::VerifySchemaBuffer(v)) { error = "bfbs failed verification"; return false; }
    schema_ = reflection::GetSchema(bytes_.data());
    Sha256 h; h.update(bytes_.data(), bytes_.size());
    digest_ = to_gd(h.hex());
    return true;
}

PackedStringArray PrivchatFlatBuffersSchema::get_roots() const {
    PackedStringArray out;
    if (schema_ == nullptr) return out;
    for (auto o : *schema_->objects()) if (!o->is_struct()) out.push_back(to_gd(o->name()->str()));
    return out;
}
String PrivchatFlatBuffersSchema::get_root_identifier() const {
    if (schema_ == nullptr || schema_->file_ident() == nullptr) return "";
    return to_gd(schema_->file_ident()->str());
}
String PrivchatFlatBuffersSchema::get_root_type() const {
    if (schema_ == nullptr || schema_->root_table() == nullptr) return "";
    return to_gd(schema_->root_table()->name()->str());
}
String PrivchatFlatBuffersSchema::get_digest() const { return digest_; }

// ---------------------------------------------------------------------------
// PrivchatFlatBuffers
// ---------------------------------------------------------------------------
void PrivchatFlatBuffers::_bind_methods() {
    ClassDB::bind_method(D_METHOD("load_schema", "bfbs"), &PrivchatFlatBuffers::load_schema);
    ClassDB::bind_method(D_METHOD("encode", "schema", "root", "value"), &PrivchatFlatBuffers::encode);
    ClassDB::bind_method(D_METHOD("decode", "schema", "bytes", "root"), &PrivchatFlatBuffers::decode);
    ClassDB::bind_method(D_METHOD("set_max_bytes", "value"), &PrivchatFlatBuffers::set_max_bytes);
    ClassDB::bind_method(D_METHOD("get_max_bytes"), &PrivchatFlatBuffers::get_max_bytes);
    ClassDB::bind_method(D_METHOD("set_max_vector_len", "value"), &PrivchatFlatBuffers::set_max_vector_len);
    ClassDB::bind_method(D_METHOD("get_max_vector_len"), &PrivchatFlatBuffers::get_max_vector_len);
    ClassDB::bind_method(D_METHOD("set_max_objects", "value"), &PrivchatFlatBuffers::set_max_objects);
    ClassDB::bind_method(D_METHOD("get_max_objects"), &PrivchatFlatBuffers::get_max_objects);
}

void PrivchatFlatBuffers::set_max_bytes(int64_t v) { max_bytes_ = std::max<int64_t>(1, std::min<int64_t>(v, HARD_MAX_BYTES)); }
void PrivchatFlatBuffers::set_max_vector_len(int64_t v) { max_vector_len_ = std::max<int64_t>(0, std::min<int64_t>(v, HARD_MAX_VECTOR_LEN)); }
void PrivchatFlatBuffers::set_max_objects(int64_t v) { max_objects_ = std::max<int64_t>(1, std::min<int64_t>(v, HARD_MAX_OBJECTS)); }

Dictionary PrivchatFlatBuffers::load_schema(const PackedByteArray &bfbs) {
    if (int64_t(bfbs.size()) > HARD_MAX_BYTES) return fail("bfbs too large");
    Ref<PrivchatFlatBuffersSchema> s;
    s.instantiate();
    String error;
    if (!s->_load(bfbs, error)) return fail(error);
    Dictionary d;
    d["ok"] = true;
    d["error"] = "";
    d["schema"] = s;
    return d;
}

Dictionary PrivchatFlatBuffers::encode(const Ref<PrivchatFlatBuffersSchema> &schema, const String &root, const Dictionary &value) {
    Dictionary result;
    result["data"] = PackedByteArray();
    if (schema.is_null() || schema->schema() == nullptr) { result["ok"] = false; result["error"] = "schema not loaded"; return result; }
    auto obj = find_object(*schema->schema(), gd(root));
    if (obj == nullptr || obj->is_struct()) { result["ok"] = false; result["error"] = gd(root) == "" ? "root required" : to_gd("unknown root " + gd(root)); return result; }
    Ctx ctx{schema->schema(), "", gd(root), 0, 0, max_vector_len_, max_objects_};
    flatbuffers::FlatBufferBuilder fbb(1024);
    Encoder enc{ctx, fbb};
    flatbuffers::uoffset_t off = 0;
    if (!enc.encode_table(*obj, value, off)) { result["ok"] = false; result["error"] = to_gd(ctx.error); return result; }
    const char *ident = nullptr;
    if (schema->schema()->root_table() == obj && schema->schema()->file_ident() != nullptr && schema->schema()->file_ident()->size() == 4) {
        ident = schema->schema()->file_ident()->c_str();
    }
    fbb.Finish(flatbuffers::Offset<flatbuffers::Table>(off), ident);
    if (int64_t(fbb.GetSize()) > max_bytes_) { result["ok"] = false; result["error"] = "encoded size exceeds max_bytes"; return result; }
    PackedByteArray out;
    out.resize(int64_t(fbb.GetSize()));
    memcpy(out.ptrw(), fbb.GetBufferPointer(), fbb.GetSize());
    result["ok"] = true; result["error"] = ""; result["data"] = out;
    return result;
}

Dictionary PrivchatFlatBuffers::decode(const Ref<PrivchatFlatBuffersSchema> &schema, const PackedByteArray &bytes, const String &root) {
    Dictionary result;
    result["data"] = Dictionary();
    auto bad = [&](const String &e) { result["ok"] = false; result["error"] = e; return result; };
    if (schema.is_null() || schema->schema() == nullptr) return bad("schema not loaded");
    if (int64_t(bytes.size()) > max_bytes_) return bad("buffer exceeds max_bytes");
    if (bytes.size() < 8) return bad("buffer too short");
    auto obj = find_object(*schema->schema(), gd(root));
    if (obj == nullptr || obj->is_struct()) return bad(to_gd("unknown root " + gd(root)));
    // Structure first (spec §3.6): reflection verifier, then identifier.
    if (!flatbuffers::Verify(*schema->schema(), *obj, bytes.ptr(), size_t(bytes.size()), MAX_DEPTH,
            flatbuffers::uoffset_t(std::min<int64_t>(max_objects_, int64_t(UINT32_MAX))))) {
        return bad("buffer failed verification");
    }
    if (schema->schema()->root_table() == obj && schema->schema()->file_ident() != nullptr && schema->schema()->file_ident()->size() == 4) {
        if (!flatbuffers::BufferHasIdentifier(bytes.ptr(), schema->schema()->file_ident()->c_str())) return bad("file_identifier mismatch");
    }
    Ctx ctx{schema->schema(), "", gd(root), 0, 0, max_vector_len_, max_objects_};
    Decoder dec{ctx};
    Dictionary data;
    const flatbuffers::Table *tbl = flatbuffers::GetAnyRoot(bytes.ptr());
    if (!dec.decode_table(*obj, *tbl, data)) return bad(to_gd(ctx.error));
    result["ok"] = true; result["error"] = ""; result["data"] = data;
    return result;
}
