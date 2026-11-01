# bringup_top.xdc —— 板级自检引脚约束
# 与 la_top.xdc 是两套独立约束，不要同时加入同一个工程（Y18 用法冲突）。

# 时钟：125MHz，来自以太网 PHY，周期 8ns
set_property -dict {PACKAGE_PIN H16 IOSTANDARD LVCMOS33} [get_ports sys_clk]
create_clock -period 8.000 -name sys_clk [get_ports sys_clk]

# 板载 4 个 LED，高电平点亮
set_property -dict {PACKAGE_PIN R14 IOSTANDARD LVCMOS33} [get_ports {led[0]}]
set_property -dict {PACKAGE_PIN P14 IOSTANDARD LVCMOS33} [get_ports {led[1]}]
set_property -dict {PACKAGE_PIN N16 IOSTANDARD LVCMOS33} [get_ports {led[2]}]
set_property -dict {PACKAGE_PIN M14 IOSTANDARD LVCMOS33} [get_ports {led[3]}]

# Pmod A：pin1 = Y18 作输出，pin3 = Y16 作输入
# 顶层端口必须约束，缺了 Vivado 报 DRC UCIO-1，bitstream 生不出来
set_property -dict {PACKAGE_PIN Y18 IOSTANDARD LVCMOS33} [get_ports pmod_out]
set_property -dict {PACKAGE_PIN Y16 IOSTANDARD LVCMOS33} [get_ports pmod_in]

# Pmod 引脚悬空时读高电平（已实测：加了内部下拉仍读 1，
# 说明板上该引脚有外部上拉），这里下拉保留，无副作用
set_property PULLTYPE PULLDOWN [get_ports pmod_in]
