# W10 SystemBus GPIO 加速器：关键代码与证据索引

本科生组初赛报告配套资料，整理日期：2026-11-13。

本仓库是**关键实现参考与服务器证据索引**，不是完整可独立运行的工程，也不代表已完成最终服务器源码逐字节一致性复核。商业工艺库、官方 SRAM/ROM 宏模型、第三方 E203 平台源码、模型权重、固件二进制和大波形均未上传。完整集成与原始工具结果请在获授权的赛事服务器读取。

## 采用方案

A16/W10/O16，64 路 MAC，原 32 位 SystemBus 与共享 SRAM；通过原 GPIO 引脚装载，CPU 经规定总线路径写入共享 SRAM，再启动计算。DMA 硬件保留，但本次 GPIO 基准测试中闲置。

X 为按 K 维奇偶交织的两个 bank，共同存储一份 X，不是两份完整 X 的乒乓缓冲。W 为双 Tile 缓存，并有权重复用逻辑。本次测试先完成外部装载、后计算；现有装载路径比较不能替代双缓冲或权重复用的独立消融。

**源码保持参考包原样**：`kwt_nice.v` 顶部仍有历史 int16 权重/装载重叠说明，`gpio_regress.py` 顶部仍有历史 SPI 描述。当前 W10 默认参数和 GPIO 测试执行顺序应以实际代码及本说明为准，不引用历史注释作为实验结论。

仓库根目录平铺关键文件；下表显示原工程路径，链接指向对应的公开文件。

## 关键代码

|文件|用途|
|---|---|
|[rtl/acc/kwt_nice.v](kwt_nice.v)|NICE 加速器、64 路 MAC、X 奇偶 bank、W 双 Tile、重定标与输出|
|[rtl/acc/kwt_sram16.v](kwt_sram16.v)|加速器内部 SRAM 封装；官方宏模型需另行配置|
|[rtl/acc/kwt_shared_sram.v](kwt_shared_sram.v)|共享 SRAM 总线侧控制|
|[rtl/acc/kwt_bus_dma.v](kwt_bus_dma.v)|原 SystemBus 之前的 DMA 与仲裁逻辑|
|[software/driver/kwt_nice.h](kwt_nice.h)|NICE 软件接口|
|[sim/gpio_accept/driver.c](driver.c)|GPIO 装载、unroll8、完成装载后启动计算|
|[sim/gpio_regress.py](gpio_regress.py)|GPIO 系统验证与平台集成参考脚本；依赖未附平台及支持文件|
|[synth/sysbus_dc_fast.tcl](sysbus_dc_fast.tcl)|全 SoC 综合、宏计数与面积/时序输出|
|[synth/review_sysbus_timing.tcl](review_sysbus_timing.tcl)|时序复核约束与报告|
|[synth/review_sysbus_power.py](review_sysbus_power.py)|活动功耗复核入口|

## 报告引用指标

|指标|结果与口径|
|---|---|
|吞吐|491.57 任务/s；150 MHz、305144 周期/任务，含装载、计算、写回|
|新增面积|0.3455481507 mm²；全 SoC 为 2.633678831633 mm²，二者不可混用|
|平均功耗|28.432612975 mW；12 层任务等权平均，综合阶段活动估算|
|最坏层汇总 NRMSE|0.085423045%；内部每层 600 条数值验证，不是官方测试成绩或分类准确率|

单任务为 99×64 与 64×256 矩阵计算，不是完整网络分类。功耗未完成全部层活动覆盖深度审计；现有功耗记录状态为 `completed_review_required`，不能写成无条件验收。加速器 reviewed setup 为 +0.32 ns，全 SoC 所列最差 setup/hold 为 0.00 ns（MET）。UART 的 24 条 max_delay 约束仍需合理性说明。没有布线寄生或 SDF 回标签核。

## 服务器与报告引用

详见 [SERVER_PATHS.md](SERVER_PATHS.md)。服务器路径仅为获授权人员的证据定位信息，**不是公开下载链接**。本次整理未重新登录服务器确认路径存续，依据 2026-11-13 已有在线核查记录。

报告可写：

> 关键 RTL、GPIO 驱动及验证/综合脚本索引公开于 https://github.com/bidi2004/w10-systembus-gpio 。原始综合、功能验证与功耗结果位于赛事服务器 RDserver04 的 `/tmp/s4_04usr_w10_dma_20261113`，具体目录见仓库 SERVER_PATHS.md。仓库仅包含关键参考代码；完整工程及受许可约束的库文件保留于服务器。该链接为报告配套索引，不代替赛事明确要求提交的材料。

## 来源与使用范围

代码从本地“报告与有效资料_20261113/实现参考”按文件原样整理，SHA256 见 [SOURCE_SHA256.txt](SOURCE_SHA256.txt)。不包含已经停用的 TCM 旁路工程。参考包与服务器最终综合源码的完整身份链尚未核闭，不能仅凭本仓库声称最终工程已通过官方合规认证。

本仓库未授予额外开源许可；已有文件中的版权与许可说明保持有效。第三方平台、工艺库和宏模型应由使用者按各自授权取得。
