#!/bin/sh
# Reuse the existing GCC9/glibc2.31 sysroot, preserving the distributed ABI.
set -eu
workspace=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
sysroot=${FINAL_LINUX_SYSROOT:-/opt/e1/focal}
test -f "$workspace/addons/ocean/physics/native/ocean_query/SConstruct"
test -f "$sysroot/opt/e1/godot-cpp/SConstruct"
mkdir -p "$workspace/temp/final_integration"
owned_mount=0
if ! mountpoint -q "$sysroot/work"; then
    mount --bind "$workspace" "$sysroot/work"
    owned_mount=1
fi
test "$sysroot/work/project.godot" -ef "$workspace/project.godot"
cleanup() {
    if [ "$owned_mount" -eq 1 ]; then umount "$sysroot/work"; fi
}
trap cleanup EXIT
chroot "$sysroot" /bin/sh -c 'cd /work/addons/ocean/physics/native/ocean_query && GODOT_CPP_PATH=/opt/e1/godot-cpp JOBS=8 sh build_linux_release.sh object_dir=build/linux-focal-final > /work/temp/final_integration/linux_build.log 2>&1'
echo FINAL_LINUX_BUILD_OK
