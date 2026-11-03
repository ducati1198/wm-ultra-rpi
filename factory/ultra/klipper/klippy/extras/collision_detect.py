# Real-time Collision & Stall Detection for Klipper
#
# Copyright (C) 2024
# This file may be distributed under the terms of the GNU GPLv3 license.

import logging
import math

class CollisionDetect:
    def __init__(self, config):
        self.printer = config.get_printer()
        self.gcode = self.printer.lookup_object('gcode')
        self.reactor = self.printer.get_reactor()
        
        # 配置参数 (单位: m/s²)
        self.threshold = config.getfloat('threshold', default=15.0, above=0.0)
        self.window_size = config.getint('window_size', default=2, minval=1)
        self.warmup_time = config.getfloat('warmup_time', default=0.2, minval=0.0)
        self.cooldown_time = config.getfloat('cooldown_time', default=1.0, minval=0.1)
        self.action = config.get('action', default='shutdown').lower()
        self.sensor_name = config.get('sensor', default='lis2dw')
        
        # 硬件与底层
        self.sensor_obj = None
        self.batch_bulk = None
        
        # 运行状态
        self.is_monitoring = False
        self.is_debugging = False
        self.debug_end_time = 0.0
        self.debug_timer = None
        
        # 算法与统计变量
        self.debug_peak = 0.0
        self.sample_counter = 0
        self.debug_samples = []
        self.prev_mag = None
        self.consecutive_hits = 0
        self.last_trigger_time = 0.0
        self.start_time = 0.0
        self.is_handling_trigger = False
        
        # 注册 G-Code 命令
        self.gcode.register_command("COLLISION_DETECT_ENABLE", self.cmd_ENABLE)
        self.gcode.register_command("COLLISION_DETECT_DISABLE", self.cmd_DISABLE)
        self.gcode.register_command("SET_COLLISION_THRESHOLD", self.cmd_SET_THRESHOLD)
        self.gcode.register_command("COLLISION_DETECT_DEBUG", self.cmd_DEBUG)
        self.gcode.register_command("COLLISION_CALIBRATE_START", self.cmd_CALIBRATE_START)
        self.gcode.register_command("COLLISION_CALIBRATE_END", self.cmd_CALIBRATE_END)

        self.printer.register_event_handler("klippy:ready", self._handle_ready)

    def _handle_ready(self):
        self.sensor_obj = self.printer.lookup_object(self.sensor_name, None)
        if self.sensor_obj is None:
            for name, obj in self.printer.objects.items():
                if name.startswith('lis2dw') or name.startswith('adxl345'):
                    self.sensor_obj = obj
                    break
        
        if self.sensor_obj is None:
            raise self.printer.config_error(f"[collision_detect] 未能定位到传感器: {self.sensor_name}")

        if hasattr(self.sensor_obj, 'batch_bulk'):
            self.batch_bulk = self.sensor_obj.batch_bulk
        elif hasattr(self.sensor_obj, 'sensor') and hasattr(self.sensor_obj.sensor, 'batch_bulk'):
            self.batch_bulk = self.sensor_obj.sensor.batch_bulk
            
        if self.batch_bulk is None:
            raise self.printer.config_error(f"[collision_detect] 传感器未找到 batch_bulk 控制器")

        self.cmd_disable()

    # 批处理核心回调函数
    def _handle_sensor_batch(self, msg):
        if not self.is_monitoring:
            # 告知 BatchBulkHelper 客户端已注销
            return False

        if self.is_handling_trigger:
            return True

        samples = msg.get('data', [])
        if not samples:
            return True

        curtime = self.reactor.monotonic()

        for pt in samples:
            self.sample_counter += 1
            # 原始数据为 mm/s²，转换为 m/s² (1G ≈ 9.80665)
            x = pt[1] / 1000.0
            y = pt[2] / 1000.0
            z = pt[3] / 1000.0
            
            # 计算加速度合模长
            curr_mag = math.sqrt(x*x + y*y + z*z)

            # 计算高频一阶差分 (冲击量 Jerk)
            if self.prev_mag is None:
                self.prev_mag = curr_mag
                impact = 0.0
            else:
                impact = abs(curr_mag - self.prev_mag)
                self.prev_mag = curr_mag

            if self.is_debugging:
                if impact > self.debug_peak:
                    self.debug_peak = impact
                # 记录 Top 样本
                if len(self.debug_samples) < 300:
                    self.debug_samples.append((self.sample_counter, x, y, z, curr_mag, impact))
                elif impact > (self.debug_peak * 0.5):
                    self.debug_samples.pop(0)
                    self.debug_samples.append((self.sample_counter, x, y, z, curr_mag, impact))
                continue

            # 启动热身滤波
            if (curtime - self.start_time) < self.warmup_time:
                continue

            # 碰撞与堵转判定
            if impact >= self.threshold:
                self.consecutive_hits += 1
                if self.consecutive_hits >= self.window_size:
                    self.is_handling_trigger = True
                    peak = impact
                    self.reactor.register_callback(lambda ev: self._execute_interrupt(peak))
                    return True
            else:
                self.consecutive_hits = 0

        # 核心保证：显式返回 True 保持客户端连接
        return True

    def _debug_timer_tick(self, eventtime):
        if not self.is_debugging:
            return self.reactor.NEVER
        if eventtime >= self.debug_end_time:
            self.cmd_CALIBRATE_END(self.gcode)
            return self.reactor.NEVER
        return eventtime + 0.1

    def _execute_interrupt(self, peak_val):
        curtime = self.reactor.monotonic()
        if (curtime - self.last_trigger_time) < self.cooldown_time:
            self.is_handling_trigger = False
            return
            
        self.last_trigger_time = curtime
        self.cmd_disable()
        
        msg = f"检测到异常碰撞/堵转冲击: {peak_val:.2f} m/s² ({peak_val/9.80665:.2f} G), 设定阈值: {self.threshold:.2f} m/s²"
        logging.error(f"[CollisionDetect] {msg}")

        if self.action == 'pause':
            self.gcode.respond_raw(f"!! 碰撞拦截: {msg}，暂停打印...")
            pause_cmd = self.printer.lookup_object('pause_resume', None)
            if pause_cmd is not None:
                pause_cmd.send_pause_command()
            else:
                self.gcode.run_script_from_command("PAUSE")
            self.is_handling_trigger = False
        else:
            self.printer.invoke_shutdown(
                f"\n{'='*50}\n"
                f"!! [碰撞急停已触发] !!\n"
                f"{msg}\n"
                f"已中断动作并保护机械结构！\n"
                f"{'='*50}"
            )

    def cmd_enable(self):
        if self.is_monitoring:
            return
        self.prev_mag = None
        self.consecutive_hits = 0
        self.sample_counter = 0
        self.debug_peak = 0.0
        self.debug_samples = []
        self.start_time = self.reactor.monotonic()
        self.is_handling_trigger = False
        self.is_monitoring = True
        
        # 注册回调，自动触发 batch_bulk._start()
        if self.batch_bulk is not None:
            self.batch_bulk.add_client(self._handle_sensor_batch)

    def cmd_disable(self):
        self.is_monitoring = False
        self.is_debugging = False
        
        if self.debug_timer is not None:
            try:
                self.reactor.unregister_timer(self.debug_timer)
            except Exception:
                pass
            self.debug_timer = None

        if self.batch_bulk is not None:
            if self._handle_sensor_batch in self.batch_bulk.client_cbs:
                self.batch_bulk.client_cbs.remove(self._handle_sensor_batch)
                if not self.batch_bulk.client_cbs:
                    self.batch_bulk._stop()

    def cmd_ENABLE(self, gcmd):
        self.cmd_enable()
        gcmd.respond_info(f"碰撞检测已启用 (阈值: {self.threshold:.2f} m/s²)")

    def cmd_DISABLE(self, gcmd):
        self.cmd_disable()
        gcmd.respond_info("碰撞检测已禁用")

    def cmd_SET_THRESHOLD(self, gcmd):
        threshold = gcmd.get_float('THRESHOLD', None)
        window = gcmd.get_int('WINDOW', None)
        action = gcmd.get('ACTION', None)
        if threshold is not None:
            self.threshold = float(threshold)
            gcmd.respond_info(f"碰撞阈值已设为: {self.threshold:.2f} m/s² ({self.threshold/9.80665:.2f} G)")
        if window is not None:
            self.window_size = int(window)
            gcmd.respond_info(f"连续触发窗口已设为: {self.window_size}")
        if action is not None:
            self.action = action.lower()
            gcmd.respond_info(f"触发动作已设为: {self.action}")

    def cmd_DEBUG(self, gcmd):
        seconds = gcmd.get_float('SECONDS', 5.0)
        self.cmd_enable()
        self.is_debugging = True
        self.debug_peak = 0.0
        self.sample_counter = 0
        self.debug_samples = []
        self.debug_end_time = self.reactor.monotonic() + seconds
        
        self.debug_timer = self.reactor.register_timer(
            self._debug_timer_tick, self.reactor.monotonic() + 0.1)
            
        gcmd.respond_info(f">>> [高频标定开启] 持续 {seconds:.1f} 秒！请在此期间【持续晃动或敲击工具头】...")

    def cmd_CALIBRATE_START(self, gcmd):
        self.cmd_enable()
        self.is_debugging = True
        self.debug_peak = 0.0
        self.sample_counter = 0
        self.debug_samples = []
        gcmd.respond_info(">>> 开始高频数据捕获...")

    def cmd_CALIBRATE_END(self, gcmd):
        if not self.is_debugging:
            gcmd.respond_info("未处于标定模式")
            return
            
        final_peak = self.debug_peak
        count = self.sample_counter
        collected = list(self.debug_samples)
        
        self.cmd_disable()

        safe_threshold = max(final_peak * 1.3, final_peak + 2.0)

        gcmd.respond_info(
            f"\n{'='*48}\n"
            f"[LIS2DW 标定报告] (单位: m/s²)\n"
            f"• 5秒捕获高频点数: {count} 点\n"
            f"• 捕获最大冲击 (Peak): {final_peak:.2f} m/s² ({final_peak/9.80665:.2f} G)\n"
            f"• ★ 推荐安全碰撞阈值: {safe_threshold:.2f} m/s² ({safe_threshold/9.80665:.2f} G)\n"
            f"  (建议在 printer.cfg 设置 threshold: {safe_threshold:.2f})\n"
            f"{'='*48}"
        )
        
        if collected:
            sorted_samples = sorted(collected, key=lambda x: x[5], reverse=True)[:10]
            lines = ["===== 最大冲击点 Top 10 ====="]
            for s_idx, x, y, z, mag, imp in sorted_samples:
                lines.append(f"#{s_idx:05d} | X:{x:6.2f} Y:{y:6.2f} Z:{z:6.2f} | 模长:{mag:5.2f} -> 冲击:{imp:5.2f} m/s²")
            gcmd.respond_info("\n".join(lines))

def load_config(config):
    return CollisionDetect(config)
