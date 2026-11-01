# loopback_top.xdc —— 板内环回验收顶层的引脚约束

# 时钟：125MHz，来自以太网 PHY，周期 8ns
set_property -dict {PACKAGE_PIN H16 IOSTANDARD LVCMOS33} [get_ports sys_clk]
create_clock -period 8.000 -name sys_clk [get_ports sys_clk]

# 板载 4 个 LED，高电平点亮
set_property -dict {PACKAGE_PIN R14 IOSTANDARD LVCMOS33} [get_ports {led[0]}]
set_property -dict {PACKAGE_PIN P14 IOSTANDARD LVCMOS33} [get_ports {led[1]}]
set_property -dict {PACKAGE_PIN N16 IOSTANDARD LVCMOS33} [get_ports {led[2]}]
set_property -dict {PACKAGE_PIN M14 IOSTANDARD LVCMOS33} [get_ports {led[3]}]
