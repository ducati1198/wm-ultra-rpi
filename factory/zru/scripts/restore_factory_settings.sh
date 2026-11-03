#!/bin/bash
time=$(date +%Y-%m-%d_%H-%M-%S)

# backup .cfg before update
CONFIG_PATH="/home/t13dp/printer_data/config"
FACTORY_SETTINGS_PATH="/home/t13dp/TM_T1/factory_settings"

#cp ${CONFIG_PATH}/printer.cfg ${CONFIG_PATH}/printer.cfg.${time}.bak

# cp ${FACTORY_SETTINGS_PATH}/printer.cfg ${CONFIG_PATH}/
cp ${FACTORY_SETTINGS_PATH}/moonraker.conf ${CONFIG_PATH}/
cp ${FACTORY_SETTINGS_PATH}/tmt1.ini ${CONFIG_PATH}/
cp ${FACTORY_SETTINGS_PATH}/offset_calibrate.cfg ${CONFIG_PATH}/
cp ${FACTORY_SETTINGS_PATH}/macros.cfg ${CONFIG_PATH}/
cp ${FACTORY_SETTINGS_PATH}/hub.cfg ${CONFIG_PATH}/
cp ${FACTORY_SETTINGS_PATH}/extruder0.cfg ${CONFIG_PATH}/
cp ${FACTORY_SETTINGS_PATH}/extruder1.cfg ${CONFIG_PATH}/
cp ${FACTORY_SETTINGS_PATH}/extruder2.cfg ${CONFIG_PATH}/
cp ${FACTORY_SETTINGS_PATH}/extruder3.cfg ${CONFIG_PATH}/
cp ${FACTORY_SETTINGS_PATH}/change_extruder.cfg ${CONFIG_PATH}/
cp ${FACTORY_SETTINGS_PATH}/change_macros.cfg ${CONFIG_PATH}/
cp ${FACTORY_SETTINGS_PATH}/wm_zru_thr0.cfg ${CONFIG_PATH}/
cp ${FACTORY_SETTINGS_PATH}/wm_zru_thr1.cfg ${CONFIG_PATH}/
cp ${FACTORY_SETTINGS_PATH}/wm_zru_thr2.cfg ${CONFIG_PATH}/
cp ${FACTORY_SETTINGS_PATH}/wm_zru_thr3.cfg ${CONFIG_PATH}/
