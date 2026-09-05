#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/godot.hpp>

#include "ocean_macro_query_native.h"

using namespace godot;

void initialize_ocean_macro_query_module(ModuleInitializationLevel level) {
	if (level == MODULE_INITIALIZATION_LEVEL_SCENE) {
		GDREGISTER_CLASS(OceanMacroQueryNative);
	}
}

void uninitialize_ocean_macro_query_module(ModuleInitializationLevel) {}

extern "C" {
GDExtensionBool GDE_EXPORT ocean_macro_query_library_init(GDExtensionInterfaceGetProcAddress get_proc_address, const GDExtensionClassLibraryPtr library, GDExtensionInitialization *initialization) {
	GDExtensionBinding::InitObject init(get_proc_address, library, initialization);
	init.register_initializer(initialize_ocean_macro_query_module);
	init.register_terminator(uninitialize_ocean_macro_query_module);
	init.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);
	return init.init();
}
}
