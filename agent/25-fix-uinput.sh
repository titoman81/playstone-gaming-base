#!/bin/bash
# 25-fix-uinput.sh
# Dummy script to create an empty /dev/uinput node so Sunshine doesn't crash on startup.
# We don't need actual kernel access because we use XTest, but Sunshine's initialization
# might panic if the device file doesn't exist at all.

if [ ! -e /dev/uinput ]; then
    touch /dev/uinput 2>/dev/null || true
    chmod 0666 /dev/uinput 2>/dev/null || true
fi
