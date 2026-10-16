#!/bin/sh
# Native Linux x86_64 build. This does not rebuild or replace the Windows DLL.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
godot_cpp_path=${GODOT_CPP_PATH:-"$root/../godot-cpp"}
if [ "$(uname -m)" != "x86_64" ]; then
    echo 'Linux x86_64 is required.' >&2
    exit 2
fi
if [ ! -f "$godot_cpp_path/SConstruct" ]; then
    echo 'Set GODOT_CPP_PATH to godot-cpp 507ed9d840c01a3c5b2a39af8bb4000bfac30bf5 (API 4.7).' >&2
    exit 2
fi
cd "$root"
exec scons platform=linux arch=x86_64 target=template_release precision=single \
    "godot_cpp_path=$godot_cpp_path" "build_profile=$root/build_profile_linux.json" \
    use_static_cpp=yes use_hot_reload=no optimize=speed debug_symbols=no lto=none \
    -j "${JOBS:-2}" "$@"
