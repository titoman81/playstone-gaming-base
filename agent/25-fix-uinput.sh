#!/bin/bash
###
# 25-fix-uinput.sh
# Playstone Gaming - Fix /dev/uinput for Sunshine virtual input (mouse/keyboard)
#
# WHY THIS IS NEEDED:
#   RunPod containers do NOT expose /dev/uinput by default.
#   The Linux kernel's uinput module IS loaded on the host (confirmed via
#   /sys/class/misc/uinput/dev), but the container's cgroup device whitelist
#   blocks access to major:minor 10:223.
#
#   This script tries multiple strategies to expose /dev/uinput:
#   1. Check if it already exists
#   2. Try nsenter into host mount + PID namespace to create device from host side
#   3. Try cgroup v1 devices.allow write
#   4. Try mknod directly
###

print_ok()   { echo "[uinput-fix] OK: ${*}"; }
print_warn() { echo "[uinput-fix] WARN: ${*}"; }
print_step() { echo "[uinput-fix] => ${*}"; }

print_step "Starting /dev/uinput fix..."

# Check if uinput is already available
if [ -c /dev/uinput ]; then
    print_ok "/dev/uinput already exists."
    chmod 0666 /dev/uinput 2>/dev/null || true
    exit 0
fi

# Get major:minor from sysfs
UINPUT_SYS="/sys/class/misc/uinput"
if [ ! -f "${UINPUT_SYS}/dev" ]; then
    print_warn "Kernel uinput module not loaded. Mouse input will NOT work."
    exit 0
fi

UINPUT_DEVNUM=$(cat "${UINPUT_SYS}/dev")
UINPUT_MAJOR=$(echo "${UINPUT_DEVNUM}" | cut -d: -f1)
UINPUT_MINOR=$(echo "${UINPUT_DEVNUM}" | cut -d: -f2)
print_step "uinput device: ${UINPUT_MAJOR}:${UINPUT_MINOR}"

# Strategy 1: nsenter into host mount namespace (pid 1 = docker host's init)
# This works on some RunPod configurations where the container shares the host PID namespace
print_step "Strategy 1: nsenter into host namespaces..."
if nsenter --mount=/proc/1/ns/mnt -- test -e /proc/1/ns/mnt 2>/dev/null; then
    nsenter --mount=/proc/1/ns/mnt --pid=/proc/1/ns/pid -- \
        sh -c "mknod /dev/uinput c ${UINPUT_MAJOR} ${UINPUT_MINOR} && chmod 0666 /dev/uinput" 2>/dev/null && \
        print_ok "/dev/uinput created via nsenter (host mount namespace)." && exit 0
fi

# Strategy 2: Try to unlock cgroup devices.allow for our container
print_step "Strategy 2: cgroup devices.allow..."
# Find our container ID from cgroup path
CGROUP_PATH=$(cat /proc/self/cgroup 2>/dev/null | grep devices | head -1 | cut -d: -f3)
if [ -n "${CGROUP_PATH}" ]; then
    # Try to write to the parent container's devices.allow
    for ALLOW_FILE in \
        "/sys/fs/cgroup/devices${CGROUP_PATH}/devices.allow" \
        "/sys/fs/cgroup/devices/devices.allow"; do
        if [ -w "${ALLOW_FILE}" ]; then
            print_step "Writing to cgroup: ${ALLOW_FILE}"
            echo "c ${UINPUT_MAJOR}:${UINPUT_MINOR} rwm" > "${ALLOW_FILE}" 2>/dev/null && \
                print_ok "cgroup device unlocked." && break
        fi
    done
fi

# Strategy 3: Direct mknod (works if cgroup was unlocked above, or if privileged)
print_step "Strategy 3: mknod /dev/uinput..."
if mknod /dev/uinput c "${UINPUT_MAJOR}" "${UINPUT_MINOR}" 2>/dev/null; then
    chmod 0666 /dev/uinput
    print_ok "/dev/uinput created via mknod."
    exit 0
fi

# Strategy 4: Try tee trick via /proc/self/fd to bypass mknod restriction
print_step "Strategy 4: bind mount trick via nsenter..."
nsenter -t 1 --mount --pid -- sh -c "\
    [ -c /dev/uinput ] || mknod /dev/uinput c ${UINPUT_MAJOR} ${UINPUT_MINOR}; \
    chmod 0666 /dev/uinput" 2>/dev/null && \
    print_ok "/dev/uinput available via host nsenter -t 1." && exit 0

print_warn "All strategies failed. Sunshine will run WITHOUT virtual mouse/keyboard."
print_warn "To fix permanently: ensure RunPod pod is created with --device /dev/uinput"
print_warn "This has been configured in orchestrator.py's dockerArgs parameter."

exit 0
