#!/bin/bash
# Mantiene HMA.exe corriendo - lo relanza si se cierra
while true; do
  if ! pgrep -f HMA.exe > /dev/null 2>&1; then
    sudo -u gamer DISPLAY=:0 XDG_RUNTIME_DIR=/run/user/1002 nohup /home/gamer/launch_game.sh >> /tmp/game_keepalive.log 2>&1 &
    sleep 15
  fi
  sleep 5
done
