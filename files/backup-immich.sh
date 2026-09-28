#!/bin/bash

echo "backing up /home/shawn folder"
  fgrep -q /srv/dev-disk-by-uuid-572f06f7-537c-4a40-8070-1952f73f65e2 /proc/mounts && sudo rsync -ah -e "ssh -i /home/shawn/.ssh/id_ed25519" --delete-after --append-verify /home/shawn/ /srv/dev-disk-by-uuid-572f06f7-537c-4a40-8070-1952f73f65e2/omv_bkup/home/shawn/
echo "backing up /home/shawn folder"
  fgrep -q /srv/dev-disk-by-uuid-572f06f7-537c-4a40-8070-1952f73f65e2 /proc/mounts && sudo rsync -ah -e "ssh -i /home/shawn/.ssh/id_ed25519" --delete-after --append-verify /srv/dev-disk-by-uuid-572f06f7-537c-4a40-8070-1952f73f65e2/omv_bkup/ shawn@192.168.4.5:/srv/dev-disk-by-uuid-c1c2d4dd-bc6b-4f1f-88dd-e4c8b48d2c3a/omv_bkup/
echo "backing up shawn_data folder"
  fgrep -q /srv/dev-disk-by-uuid-572f06f7-537c-4a40-8070-1952f73f65e2 /proc/mounts && sudo rsync -ah -e "ssh -i /home/shawn/.ssh/id_ed25519" --delete-after --append-verify /srv/dev-disk-by-uuid-572f06f7-537c-4a40-8070-1952f73f65e2/shawn_data/ shawn@192.168.4.5:/srv/dev-disk-by-uuid-c1c2d4dd-bc6b-4f1f-88dd-e4c8b48d2c3a/shawn_data/
 echo "backing up movies_shows folder"
  fgrep -q /srv/dev-disk-by-uuid-572f06f7-537c-4a40-8070-1952f73f65e2 /proc/mounts && sudo rsync -ah -e "ssh -i /home/shawn/.ssh/id_ed25519" --delete-after --append-verify /srv/dev-disk-by-uuid-572f06f7-537c-4a40-8070-1952f73f65e2/movies_shows/ shawn@192.168.4.5:/srv/dev-disk-by-uuid-c1c2d4dd-bc6b-4f1f-88dd-e4c8b48d2c3a/movies_shows/ 
echo "backing up tesla_usb folder"
  fgrep -q /srv/dev-disk-by-uuid-572f06f7-537c-4a40-8070-1952f73f65e2 /proc/mounts && sudo rsync -ahP -e "ssh -i /home/shawn/.ssh/id_ed25519" --delete-after --append-verify /srv/dev-disk-by-uuid-572f06f7-537c-4a40-8070-1952f73f65e2/tesla_usb/ shawn@192.168.4.5:/srv/dev-disk-by-uuid-c1c2d4dd-bc6b-4f1f-88dd-e4c8b48d2c3a/tesla_usb/
echo "backing up yania_data folder"
  fgrep -q /srv/dev-disk-by-uuid-572f06f7-537c-4a40-8070-1952f73f65e2 /proc/mounts && sudo rsync -ah -e "ssh -i /home/shawn/.ssh/id_ed25519" --delete-after --append-verify /srv/dev-disk-by-uuid-572f06f7-537c-4a40-8070-1952f73f65e2/yania_data/ shawn@192.168.4.5:/srv/dev-disk-by-uuid-c1c2d4dd-bc6b-4f1f-88dd-e4c8b48d2c3a/yania_data/
echo "started immich backup at `date`"
cd /home/shawn/docker/immich-docker-compose
docker compose down
dockerstopped=$?
echo "docker stopped = $dockerstopped at `date`"
fgrep -q /srv/dev-disk-by-uuid-572f06f7-537c-4a40-8070-1952f73f65e2 /proc/mounts
immichmounted=$?
fgrep -q /srv/dev-disk-by-uuid-572f06f7-537c-4a40-8070-1952f73f65e2 /proc/mounts
photosmounted=$?
  echo "fgrep -q /srv/dev-disk-by-uuid-572f06f7-537c-4a40-8070-1952f73f65e2 /proc/mounts = $immichmounted"
  echo "fgrep -q /srv/dev-disk-by-uuid-572f06f7-537c-4a40-8070-1952f73f65e2 /proc/mounts = $photosmounted"
if test $dockerstopped -eq 0 && test $immichmounted -eq 0 && test $photosmounted -eq 0
then
  echo "backing up immich postgres folder"
  fgrep -q /srv/dev-disk-by-uuid-572f06f7-537c-4a40-8070-1952f73f65e2 /proc/mounts && sudo rsync -ah -e "ssh -i /home/shawn/.ssh/id_ed25519" --delete-after --append-verify --checksum /srv/dev-disk-by-uuid-572f06f7-537c-4a40-8070-1952f73f65e2/immich/postgres/ shawn@192.168.4.5:/srv/dev-disk-by-uuid-c1c2d4dd-bc6b-4f1f-88dd-e4c8b48d2c3a/immich/postgres/
  echo "done backing up immich postgres folder at `date`"
  echo "backing up immich library"
  fgrep -q /srv/dev-disk-by-uuid-572f06f7-537c-4a40-8070-1952f73f65e2 /proc/mounts && sudo rsync -ah -e "ssh -i /home/shawn/.ssh/id_ed25519" --append-verify --delete-after /srv/dev-disk-by-uuid-572f06f7-537c-4a40-8070-1952f73f65e2/immich/library/ shawn@192.168.4.5:/srv/dev-disk-by-uuid-c1c2d4dd-bc6b-4f1f-88dd-e4c8b48d2c3a/immich/library/
  echo "done backing up immich library at `date`"
else
  echo "backup failed restarting computer"
  #reboot
fi
docker compose up -d
cd /home/shawn/
echo "backup completed at `date`"
date >> /home/shawn/logs/date
