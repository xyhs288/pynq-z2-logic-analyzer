# la_top.xdc —— 最终作品引脚约束（器件 xc7z020clg400-1）

# 时钟：125MHz，来自以太网 PHY，周期 8ns。
# 注意：别去复位网口 PHY，否则 CLK125 消失，PL 没有时钟。
set_property -dict {PACKAGE_PIN H16 IOSTANDARD LVCMOS33} [get_ports sys_clk]
create_clock -period 8.000 -name sys_clk [get_ports sys_clk]

# Pmod A 8 路输入，3.3V 电平，不可接 5V。
# pin1..4  = CH0..CH3 = Y18/Y19/Y16/Y17
# pin7..10 = CH4..CH7 = U18/U19/W18/W19
set_property -dict {PACKAGE_PIN Y18 IOSTANDARD LVCMOS33} [get_ports {ch_in[0]}]
set_property -dict {PACKAGE_PIN Y19 IOSTANDARD LVCMOS33} [get_ports {ch_in[1]}]
set_property -dict {PACKAGE_PIN Y16 IOSTANDARD LVCMOS33} [get_ports {ch_in[2]}]
set_property -dict {PACKAGE_PIN Y17 IOSTANDARD LVCMOS33} [get_ports {ch_in[3]}]
set_property -dict {PACKAGE_PIN U18 IOSTANDARD LVCMOS33} [get_ports {ch_in[4]}]
set_property -dict {PACKAGE_PIN U19 IOSTANDARD LVCMOS33} [get_ports {ch_in[5]}]
set_property -dict {PACKAGE_PIN W18 IOSTANDARD LVCMOS33} [get_ports {ch_in[6]}]
set_property -dict {PACKAGE_PIN W19 IOSTANDARD LVCMOS33} [get_ports {ch_in[7]}]

# 板载 4 个 LED，高电平点亮
set_property -dict {PACKAGE_PIN R14 IOSTANDARD LVCMOS33} [get_ports {led[0]}]
set_property -dict {PACKAGE_PIN P14 IOSTANDARD LVCMOS33} [get_ports {led[1]}]
set_property -dict {PACKAGE_PIN N16 IOSTANDARD LVCMOS33} [get_ports {led[2]}]
set_property -dict {PACKAGE_PIN M14 IOSTANDARD LVCMOS33} [get_ports {led[3]}]

# ---------------------------------------------------------------------
# Pmod B 八路输出（JB1..JB4，引脚 1/2/3/4/7/8/9/10）
# 用杜邦线从这里接到 Pmod A 的输入，信号就真的走了一遍芯片外部；
# 拔掉一根，对应通道立刻变平 —— 这是"采的是真实信号"最直接的验证。
# ---------------------------------------------------------------------
set_property -dict {PACKAGE_PIN W14 IOSTANDARD LVCMOS33} [get_ports {sig_out[0]}]
set_property -dict {PACKAGE_PIN Y14 IOSTANDARD LVCMOS33} [get_ports {sig_out[1]}]
set_property -dict {PACKAGE_PIN T11 IOSTANDARD LVCMOS33} [get_ports {sig_out[2]}]
set_property -dict {PACKAGE_PIN T10 IOSTANDARD LVCMOS33} [get_ports {sig_out[3]}]
set_property -dict {PACKAGE_PIN V16 IOSTANDARD LVCMOS33} [get_ports {sig_out[4]}]
set_property -dict {PACKAGE_PIN W16 IOSTANDARD LVCMOS33} [get_ports {sig_out[5]}]
set_property -dict {PACKAGE_PIN V12 IOSTANDARD LVCMOS33} [get_ports {sig_out[6]}]
set_property -dict {PACKAGE_PIN W13 IOSTANDARD LVCMOS33} [get_ports {sig_out[7]}]
