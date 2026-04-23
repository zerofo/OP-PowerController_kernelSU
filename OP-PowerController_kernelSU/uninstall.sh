#!/system/bin/sh
#兜底操作
echo 1 > /sys/devices/virtual/oplus_chg/battery/mmi_charging_enable

# 获取模块 ID (从 module.prop 中读取)
MODULE_ID=$(grep_prop id $MODDIR/module.prop)

# 删除模块运行时生成的状态和配置文件
rm -rf /data/adb/modules/$MODULE_ID/*

# 返回 0 表示脚本执行成功
return 0
