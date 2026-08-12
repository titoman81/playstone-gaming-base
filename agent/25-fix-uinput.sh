#!/bin/bash
###
# 25-fix-uinput.sh
# Playstone Gaming - Fix /dev/uinput for Sunshine virtual input (mouse/keyboard)
#
# WHY THIS IS NEEDED:
#   RunPod Secure Cloud containers do NOT expose /dev/uinput by default.
#   The Linux kernel's uinput module IS loaded on the host (confirmed via
#   /sys/class/misc/uinput), but the container's cgroup device whitelist
#   blocks access to major:minor 10:223.
#
#   This script:
#   1. Reads the real major:minor from /sys/class/misc/uinput/dev
#   2. Tries to allow the device via cgroup devices.allow (works if cgroup v1)
#   3. Creates the /dev/uinput device node with mknod
#   4. Sets permissions so Sunshine (running as 'default' user) can use it
###

set -e

print_header() { echo -e "\e[35m**** ${*} ****\e[0m"; }
print_step()   { echo -e "\e[36m  - ${*}\e[0m"; }
print_ok()     { echo -e "\e[32m  [OK] ${*}\e[0m"; }
print_warn()   { echo -e "\e[33m  [WARN] ${*}\e[0m"; }

print_header "Fix /dev/uinput for Sunshine virtual input"

# Check if uinput is already available
if [[ -c /dev/uinput ]]; then
    print_ok "/dev/uinput already exists — skipping."
    chmod 0666 /dev/uinput 2>/dev/null || true
    exit 0
fi

# Check if the kernel has the uinput misc device registered
UINPUT_SYS="/sys/class/misc/uinput"
if [[ ! -f "${UINPUT_SYS}/dev" ]]; then
    print_warn "Kernel uinput module not loaded (${UINPUT_SYS}/dev missing). Mouse input will NOT work."
    exit 0
fi

# Read the real major:minor from sysfs
UINPUT_DEVNUM=$(cat "${UINPUT_SYS}/dev")
UINPUT_MAJOR=$(echo "${UINPUT_DEVNUM}" | cut -d: -f1)
UINPUT_MINOR=$(echo "${UINPUT_DEVNUM}" | cut -d: -f2)
print_step "uinput device number from sysfs: ${UINPUT_MAJOR}:${UINPUT_MINOR}"

# Try to add device to cgroup whitelist (cgroup v1 only — harmless if it fails)
# This is what Docker does internally when you pass --device /dev/uinput
CGROUP_DEVICES_ALLOW=""
for path in \
    /sys/fs/cgroup/devices/devices.allow \
    /sys/fs/cgroup/devices/docker/$(basename $(cat /proc/self/cgroup 2>/dev/null | grep devices | head -1 | cut -d/ -f3- 2>/dev/null) 2>/dev/null)/devices.allow \
    $(find /sys/fs/cgroup/devices -name 'devices.allow' 2>/dev/null | head -1); do
    if [[ -w "${path}" ]]; then
        CGROUP_DEVICES_ALLOW="${path}"
        break
    fi
done

if [[ -n "${CGROUP_DEVICES_ALLOW}" ]]; then
    print_step "Allowing device via cgroup: ${CGROUP_DEVICES_ALLOW}"
    echo "c ${UINPUT_MAJOR}:${UINPUT_MINOR} rwm" > "${CGROUP_DEVICES_ALLOW}" 2>/dev/null && \
        print_ok "cgroup device allowed." || \
        print_warn "cgroup write failed (may be read-only). Trying mknod anyway..."
else
    print_warn "No writable cgroup devices.allow found. Trying mknod anyway..."
fi

# Create the device node
if mknod /dev/uinput c "${UINPUT_MAJOR}" "${UINPUT_MINOR}" 2>/dev/null; then
    chmod 0666 /dev/uinput
    print_ok "/dev/uinput created successfully (${UINPUT_MAJOR}:${UINPUT_MINOR})."
else
    # Last resort: try with nsenter into host cgroup namespace (only works on some setups)
    print_warn "mknod failed. Trying nsenter workaround..."
    nsenter --mount=/proc/1/ns/mnt -- mknod /dev/uinput c "${UINPUT_MAJOR}" "${UINPUT_MINOR}" 2>/dev/null && \
        chmod 0666 /dev/uinput && \
        print_ok "/dev/uinput created via nsenter." || \
        print_warn "All methods failed. Sunshine will run WITHOUT virtual mouse/keyboard support."
fi

echo -e "\e[34mDONE\e[0m"
