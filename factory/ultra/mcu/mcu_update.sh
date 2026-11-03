#!/bin/bash
# TM-T1-MCU (firmware restart -> hid-flash)

VERSION=1.6.1 # compatible for new/old bootloader pattern
RESET_CMD=73 # 0x73 -> 115
KLIPPER_BIN="/home/t13dp/mcu_update/klipper.bin"
KLIPPER_MCU="/dev/serial/by-id/usb-Klipper_stm32f407xx_*"
# KLIPPER_MCU_OLD="/dev/serial/by-id/usb-Klipper_stm32f407xx_*"
BOOTLOADER_MCU="/dev/serial/by-id/usb-*_DRIVER_BOOT*"
BOOTLOADER_MCU_OLD="/dev/serial/by-id/usb-*-CDC_*"

echo "Start mcu_update.sh, version: $VERSION"

if [ $# -ge 1 ]
then
	KLIPPER_BIN=$1
	echo "KLIPPER_BIN: $KLIPPER_BIN"
fi
if [ $# -ge 2 ]
then
	KLIPPER_MCU=$2
	echo "KLIPPER_MCU: $KLIPPER_MCU"
fi
if [ $# -ge 3 ]
then
	BOOTLOADER_MCU=$3
	echo "BOOTLOADER_MCU: $BOOTLOADER_MCU"
fi
if [ $# -ge 4 ]
then
	RESET_CMD=$4
	echo "RESET_CMD: $RESET_CMD"
fi

if [ -f $KLIPPER_BIN ]
then
	curl http://127.0.0.1/printer/firmware_restart -d 0
	echo "Send firmware_restart to klipper for reseting MCU."

	# check whether a bootloader device exists 
	exist=0
	cnt=1
	while [ $cnt -le 10 ]
	do
		if [ -e $BOOTLOADER_MCU ]
		then
			echo "Find $BOOTLOADER_MCU in loop $cnt"
			exist=1
			break
		elif [ -e $BOOTLOADER_MCU_OLD ]
		then
			echo "Find $BOOTLOADER_MCU_OLD in loop $cnt"
			BOOTLOADER_MCU=$BOOTLOADER_MCU_OLD
			echo "Set bootloader device as $BOOTLOADER_MCU_OLD"
			exist=1
			break
		else
			echo "Warning: Can't find $BOOTLOADER_MCU in loop $cnt..."
			sleep 1
		fi
		cnt=$(($cnt+1))
	done
	
	if [ $exist -eq 1 ]
	then
		# update
		/home/t13dp/mcu_update/hid-flash $KLIPPER_BIN $BOOTLOADER_MCU

		cmd=$?
		if [ $cmd -eq 0 ]
		then
			result=0
		else
			echo "ERROR: hid-flash failed($cmd)..."
			result=$((3+$cmd))
		fi
	else
		echo "ERROR: no bootloader device..."
		result=2
	fi

	# systemctl start klipper.service
	exit $result
else
	echo "ERROR: no firmware..."
	exit 1
fi
