#!/usr/bin/env python2
# Tool to query CAN bus uuids
#
# Copyright (C) 2021  Kevin O'Connor <kevin@koconnor.net>
#
# This file may be distributed under the terms of the GNU GPLv3 license.
import sys, os, optparse, time
import can
import subprocess

CANBUS_ID_ADMIN = 0x3f0
CMD_QUERY_UNASSIGNED = 0x00
RESP_NEED_NODEID = 0x20
CMD_SET_KLIPPER_NODEID = 0x01
CMD_SET_CANBOOT_NODEID = 0x11

def query_unassigned(canbus_iface):
    # Open CAN socket
    filters = [{"can_id": CANBUS_ID_ADMIN + 1, "can_mask": 0x7ff,
                "extended": False}]
    bus = can.interface.Bus(channel=canbus_iface, can_filters=filters,
                            bustype='socketcan')
    # Send query
    msg = can.Message(arbitration_id=CANBUS_ID_ADMIN,
                      data=[CMD_QUERY_UNASSIGNED], is_extended_id=False)
    bus.send(msg)
    # Read responses
    found_ids = {}
    uuid_list = []
    start_time = curtime = time.time()
    while 1:
        tdiff = start_time + 2. - curtime
        if tdiff <= 0.:
            break
        msg = bus.recv(tdiff)
        curtime = time.time()
        if (msg is None or msg.arbitration_id != CANBUS_ID_ADMIN + 1
            or msg.dlc < 7 or msg.data[0] != RESP_NEED_NODEID):
            continue
        uuid = sum([v << ((5-i)*8) for i, v in enumerate(msg.data[1:7])])
        cfg_path = set_cfg_path('%012x' % uuid) #将uuid转换为字符串后传给判断函数，返回对应的配置文件路径
        sys.stdout.write("%s\n"% (cfg_path))
        if cfg_path:
            modify_config(cfg_path,'%012x' % uuid)#将uuid改到对应的配置文件里
        else:
            uuid_list.append('%012x' % uuid)
        if uuid in found_ids:
            continue
        found_ids[uuid] = 1
        AppNames = {
            CMD_SET_KLIPPER_NODEID: "Klipper",
            CMD_SET_CANBOOT_NODEID: "CanBoot"
        }
        app_id = CMD_SET_KLIPPER_NODEID
        if msg.dlc > 7:
            app_id = msg.data[7]
        app_name = AppNames.get(app_id, "Unknown")
        sys.stdout.write("Found canbus_uuid=%012x, Application: %s\n"
                         % (uuid, app_name))
    sys.stdout.write("uuid_list:%s\n" % (uuid_list))
    # 记录有效挤出头个数(每次上电后更新，用于与tm_t1.ini做判断)
    if len(uuid_list) == 0 or len(uuid_list) > 4:
        sys.stdout.write("错误: 找到 %d 个 thr_uuids, 只能有 0 个或 小于 4 个有效挤出头\n" % (len(uuid_list)))
        return
    f = open('/home/t13dp/TM_T1/other/current_thr_number.txt', 'w+')
    f.write("%d" % (len(uuid_list)))
    f.close()
    sys.stdout.write("共找到 %d 个 thr_uuids\n" % (len(uuid_list)))
    set_thr_uuid(sorted(uuid_list, key=lambda id: id[-2:]))
    
    
def modify_config(file_path, new_uuid):
    if not os.path.exists(file_path):
        sys.stdout.write("文件路径不存在: {}".format(file_path))
        return
    with open(file_path, 'r') as file:
        lines = file.readlines()

    with open(file_path, 'w') as file:
        for line in lines:
            if line.startswith('canbus_uuid:'):
                line = 'canbus_uuid: ' + new_uuid + '\n'
            file.write(line)

def read_config(file_path):
    if not os.path.exists(file_path):
        sys.stdout.write("文件路径不存在: {}".format(file_path))
        return None  # 返回 None 表示错误
    
    uuid_value = None  # 初始化变量存储 UUID

    with open(file_path, 'r') as file:  # 只读模式打开文件
        for line in file:
            # 检查行是否包含 canbus_uuid
            if line.startswith('canbus_uuid:'):
                # 分割键值对并提取 UUID
                parts = line.split(':', 1)  # 仅分割一次
                if len(parts) > 1:
                    uuid_value = parts[1].strip()  # 去除空白字符
                    break  # 找到第一个匹配项后退出循环
    return uuid_value

def set_cfg_path(uuid):
    if uuid[0:2] in ['aa']:
        return "/home/t13dp/printer_data/config/wm_zru_mcu.cfg"
    # if uuid[0:2] in ['ab']:
    #     return "/home/t13dp/printer_data/config/tm_t1_box0.cfg"
    # if uuid[0:2] in ['ac']:
    #     return "/home/t13dp/printer_data/config/wm_zru_thr0.cfg"
    if uuid[0:2] in ['ad']:
        return "/home/t13dp/printer_data/config/wm_zru_ext.cfg"
    if uuid[0:2] in ['ae']:
        return "/home/t13dp/printer_data/config/wm_zru_hub.cfg"
    if uuid[0:2] in ['af']:
        return "/home/t13dp/printer_data/config/wm_zru_load_cell.cfg"
    # else:
    #     return "/home/t13dp/printer_data/config/wm_zru_unknown.cfg"

import shutil
# 剩余的uuid设置到thr0~thr3
def set_thr_uuid(uuid_list):
    """
    设置挤出头UUID到配置文件
    功能说明：
    1. 读取4个配置文件中的现有UUID
    2. 根据扫描到的UUID数量决定分配策略
    3. 如果UUID数量变化，按顺序分配；如果数量不变，智能匹配
    
    参数：
    uuid_list - 扫描到的UUID列表（长度可能小于4）
    
    返回：无
    """
    config_path = []      # 存储4个配置文件的路径
    read_uuid_list = []   # 存储从配置文件读取的UUID

    # ==================== 第一步：读取现有配置 ====================
    for i in range(4):
        # 构建配置文件路径（thr0.cfg ~ thr3.cfg）
        path = "/home/t13dp/printer_data/config/wm_zru_thr{}.cfg".format(i)
        config_path.append(path)
        
        # 读取配置文件中的UUID
        uuid_val = read_config(path) or ''  # 确保None转为空字符串
        read_uuid_list.append(uuid_val)
        
        # 打印读取日志
        sys.stdout.write("读取配置 [thr{}] UUID: {}\n".format(i, uuid_val))

    # ==================== 第二步：计算有效UUID数量 ====================
    # 现有配置中的非空UUID数量
    existing_count = sum(1 for uuid in read_uuid_list if uuid)
    
    # 扫描到的有效UUID数量
    valid_uuids = [uuid for uuid in uuid_list[:4] if uuid]
    new_count = len(valid_uuids)
    sys.stdout.write("现有UUID数量: {}, 新扫描UUID数量: {}\n".format(existing_count, new_count))

    # ==================== 第三步：根据数量选择配置 ====================
    dst_path = "/home/t13dp/printer_data/config/printer.cfg"
    if new_count == 0:
        sys.stdout.write("没有扫描到有效的UUID，跳过配置更新。\n")
        return
    elif new_count != existing_count:
        result = subprocess.run(['bash', '/home/t13dp/TM_T1/scripts/get_save_config.sh'], capture_output=True, text=True)
        print("stdout:", result.stdout)
        print("stderr:", result.stderr)
        src_path = "/home/t13dp/TM_T1/other/printer{}.cfg".format(new_count)
        if os.path.exists(src_path):
            shutil.copy(src_path, dst_path)
            sys.stdout.write("仅扫描到{}个UUID，已复制printer{}.cfg到printer.cfg\n".format(new_count, new_count))
        else:
            sys.stdout.write("仅扫描到{}个UUID，未找到printer{}.cfg\n".format(new_count, new_count))
        result = subprocess.run(['bash', '/home/t13dp/TM_T1/scripts/replace_save_config.sh'], capture_output=True, text=True)
        print("stdout:", result.stdout)
        print("stderr:", result.stderr)

    # ==================== 第四步：根据数量变化决定分配策略 ====================
    if new_count != existing_count:
        # 情况1：UUID数量发生变化 → 按顺序分配
        sys.stdout.write("UUID数量变化，按顺序分配策略\n")
            
        # ========按顺序分配扫描到的UUID=======
        final_uuids = []
        for i in range(4):
            if i < len(valid_uuids):
                final_uuids.append(valid_uuids[i])
            else:
                final_uuids.append('')  # 不足4个时用空字符串填充
        
        # 写入所有配置文件（即使没有变化也写入，确保顺序正确）
        for i in range(4):
            old_uuid = read_uuid_list[i]
            new_uuid = final_uuids[i]
            if new_uuid != old_uuid:
                modify_config(config_path[i], new_uuid)
                sys.stdout.write("顺序更新 [thr{}]: {} → {}\n".format(i, old_uuid, new_uuid))
            else:
                sys.stdout.write("顺序保持 [thr{}]: {}\n".format(i, old_uuid))
                
    else:
        # 情况2：UUID数量相同 → 智能匹配分配
        sys.stdout.write("UUID数量相同，使用智能匹配策略\n")
        
        # 创建需要保留的有效UUID集合
        valid_uuid_set = set(valid_uuids)
        
        final_uuids = []          # 最终要写入的UUID列表
        replaced_indices = set()   # 记录需要替换的配置位置索引
        
        # 第一轮处理：保留仍然有效的现有UUID
        for i, old_uuid in enumerate(read_uuid_list):
            if old_uuid in valid_uuid_set:
                # 情况1：旧UUID仍在有效列表中 → 保留不变
                final_uuids.append(old_uuid)
                valid_uuid_set.remove(old_uuid)  # 从待分配集合移除
                sys.stdout.write("[thr{}] UUID {} 仍然有效，保留\n".format(i, old_uuid))
            else:
                # 情况2：旧UUID需要被替换 → 先标记位置
                final_uuids.append(None)  # None表示需要后续分配新UUID
                replaced_indices.add(i)
                sys.stdout.write("[thr{}] UUID {} 需要替换\n".format(i, old_uuid))

        # 第二轮处理：分配新UUID到空缺位置
        for new_uuid in valid_uuid_set:
            if replaced_indices:
                # 取出一个需要替换的位置
                i = replaced_indices.pop()
                final_uuids[i] = new_uuid
                sys.stdout.write("智能分配新UUID {} 到 [thr{}]\n".format(new_uuid, i))
            else:
                # 没有可用位置时的处理
                sys.stderr.write("警告：没有可用位置分配给UUID {}\n".format(new_uuid))

        # 写入变更（只在实际发生变更时写入）
        for i in range(4):
            old_uuid = read_uuid_list[i]
            new_uuid = final_uuids[i]
            
            if new_uuid is not None and new_uuid != old_uuid:
                modify_config(config_path[i], new_uuid)
                sys.stdout.write(
                    "智能更新 [thr{}]: {} → {}\n".format(i, old_uuid, new_uuid))

    # 最终状态打印
    sys.stdout.write("最终UUID分配结果：\n")
    for i, uuid in enumerate(final_uuids if 'final_uuids' in locals() else read_uuid_list):
        sys.stdout.write("  thr{}: {}\n".format(i, uuid))
    


    

def main():
    usage = "%prog [options] <can interface>"
    opts = optparse.OptionParser(usage)
    options, args = opts.parse_args()
    if len(args) != 1:
        opts.error("Incorrect number of arguments")
    canbus_iface = args[0]
    query_unassigned(canbus_iface)

if __name__ == '__main__':
    main()
