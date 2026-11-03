from . import xy_offset_calibrator_core

def load_config(config):
    return xy_offset_calibrator_core.XYOffsetCalibrator(config)