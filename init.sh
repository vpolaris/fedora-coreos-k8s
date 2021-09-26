#!/bin/bash
#https://github.com/pftf/RPi4/releases/
#https://fedorapeople.org/groups/fcos-images/builds/latest/aarch64/
DEVICE=/dev/sdd
sudo parted ${DEVICE} -- rm 2
sudo parted ${DEVICE} -- rm 3
sudo parted ${DEVICE} -- rm 4
sudo coreos-installer install ${DEVICE} -i pi01.ign -f  fedora-coreos-34.20210915.dev.0-metal.aarch64.raw.xz --offline --insecure -n --network-dir ./network
sleep 2
sudo mount ${DEVICE}2 /media/efi/
sleep 2
cd archive/
sudo cp -r * /media/efi/
sudo umount /media/efi
sleep 2
sudo e2fsck -f ${DEVICE}3
sleep 2
sudo tune2fs -U random ${DEVICE}3
sleep 2
sudo eject ${DEVICE}
