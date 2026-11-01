# stage2_top.xdc —— 第二阶段验证顶层引脚约束

# 时钟：125MHz，来自以太网 PHY，周期 8ns
set_property -dict {PACKAGE_PIN H16 IOSTANDARD LVCMOS33} [get_ports sys_clk]
create_clock -period 8.000 -name sys_clk [get_ports sys_clk]

# 板载 4 个 LED，高电平点亮
set_property -dict {PACKAGE_PIN R14 IOSTANDARD LVCMOS33} [get_ports {led[0]}]
set_property -dict {PACKAGE_PIN P14 IOSTANDARD LVCMOS33} [get_ports {led[1]}]
set_property -dict {PACKAGE_PIN N16 IOSTANDARD LVCMOS33} [get_ports {led[2]}]
set_property -dict {PACKAGE_PIN M14 IOSTANDARD LVCMOS33} [get_ports {led[3]}]

# BTN0 (D19)，按下输出高电平：重新布防
set_property -dict {PACKAGE_PIN D19 IOSTANDARD LVCMOS33} [get_ports btn0]
