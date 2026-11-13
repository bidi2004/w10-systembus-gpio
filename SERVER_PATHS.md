# 赛事服务器路径索引

服务器：`RDserver04`。工程根目录：`/tmp/s4_04usr_w10_dma_20261113`。

以下路径来自 2026-11-13 已有在线核查记录，本次发布未重新验证存续。`/tmp` 不是永久归档保证；GitHub 不提供服务器访问权限，也不包含凭据。

## 关键源码（相对工程根目录）

- `rtl/acc/kwt_nice.v`
- `rtl/acc/kwt_sram16.v`
- `rtl/acc/kwt_shared_sram.v`
- `rtl/acc/kwt_bus_dma.v`
- `rtl/e203/e203_subsys_nice_core.v`：平台集成，未收录本仓库。
- `rtl/soc/kwt_platform_macros.v`、`rtl/soc/kwt_mrom_top.v`：平台存储封装，未收录本仓库。
- `sim/gpio_accept/driver.c`、`sim/gpio_accept/hardware_identity.json`
- `sysbus_source_changes.json`：平台修改记录，记录存在不等于完整源码身份复核完成。

## 原始结果（相对工程根目录）

|内容|路径|
|---|---|
|官方宏 RTL 十二层验证|`sim/results/sysbus_20261113T113030038639Z`；`gpio_macro.log`|
|L0 门级功能验证|`sim/results/sysbus_20261113T113228662847Z`；`gpio_gate.log`|
|十二层门级/功耗记录|`sim/results/gpio_power12_20261113/L00` 至 `L11` 下的 `metrics.json`；`gpio_power12.log`|
|综合与时序|`sim/results/sysbus_dc_fast_20261113T102549398935Z`|
|综合目录内重点文件|`area.rpt`、`timing_max.rpt`、`timing_min.rpt`、`reviewed_accelerator_max.rpt`、`reviewed_accelerator_min.rpt`、`reviewed_constraints.rpt`、`reviewed_check_timing.rpt`、`reviewed_soc.sdc`、`soc.ddc`、`soc_mapped.v`、`config.tcl`|
|L0 功耗|`sim/results/sysbus_power_20261113T114036891704Z/power_verbose.rpt`、`activity.rpt`、`memory_activity.rpt`|
|活动深入审计|`sim/results/gpio_activity_audit_20261113`；`gpio_audit.log`|
|波形别名比较|`sim/results/gpio_activity_audit_20261113/alias_window_comparison.json`；`gpio_wave_audit.log`|

各层实际功耗目录以其 `metrics.json` 的 `power_directory` 为准，不能按目录时间猜测。

## 已有核查记录中的身份信息

- `soc.ddc`：`39be83a171b8c6a89725ff4aa6b4713901bcec9fc66e5eb543a32d6ac0f218e5`（前次在线重算）。
- `soc_mapped.v`：`d693e8cc720de9b04673e4072f0981f6b47ad418a1b573213eb5a3f767812de0`（12 层记录一致，非本次重算）。
- firmware：`9a245df4c377a6e891ee9bf941b3e3b552219f4c18151b01e4c769b7ea244e72`（12 层记录一致）。

这些哈希用于定位已有实验，不能替代全部最终源码的逐文件身份核验。本仓库 SOURCE_SHA256.txt 仅描述公开参考文件。
