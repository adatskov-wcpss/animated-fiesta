docker run -d --name debian-selkies -p 3000:3000 -p 3001:3001 --shm-size="5gb" -v /tmp:/tmp -e PUID=1000 -e PGID=1000 --restart unless-stopped lscr.io/linuxserver/baseimage-selkies:debianbookworm
