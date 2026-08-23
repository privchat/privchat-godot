// register_types.h — GDExtension entry for the privchat native addon.
#pragma once

#include <godot_cpp/core/class_db.hpp>

using namespace godot;

void initialize_privchat_module(ModuleInitializationLevel p_level);
void uninitialize_privchat_module(ModuleInitializationLevel p_level);
