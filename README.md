# 通信原理课程设计

## 1. 当前实现范围

`IEEE802_11a_tx.m` 当前完成 6 Mbps 模式下的数据位流准备和加扰：生成测试字节、重复数据、转换为 bit 流、添加 16 bit SERVICE 字段和 6 bit TAIL、补齐 OFDM 符号长度，再用 802.11a 伪随机序列加扰。

该脚本目前不生成完整的 IEEE 802.11a 发射帧；卷积编码、交织、BPSK 映射、导频和子载波映射、IFFT、循环前缀及前导码仍未实现。

## 2. 运行环境

- MATLAB 2013a 或更高版本。
- Communications Toolbox，脚本使用其中的 `de2bi` 函数。
- 在 MATLAB 当前文件夹切换到本项目目录，然后运行：

  ```matlab
  IEEE802_11a_tx
  ```

运行后，`padded_bits`、`scrambling_sequence`、`scrambled_bits`、`payload_bits` 和相关计数变量会保留在工作区，便于后续发送链模块使用。

## 3. 系统参数

| 参数 | 默认值 | 说明 |
| --- | ---: | --- |
| `data_rate_mbps` | 6 | 目标数据速率，Mbps |
| `bits_per_subcarrier` | 1 | BPSK 每个子载波承载 1 bit |
| `coded_bits_per_symbol` | 48 | 每个 OFDM 符号的编码位数（N<sub>CBPS</sub>） |
| `data_bits_per_symbol` | 24 | 6 Mbps、编码率 1/2 时每个 OFDM 符号的数据位数（N<sub>DBPS</sub>） |
| `code_rate` | 1/2 | 编码率 |
| `repeat_count` | 8 | 将 1~130 的测试字节序列重复 8 次 |
| `bits_per_byte` | 8 | 每个字节的位数 |
| `scrambler_seed` | `1011101` | 7 位非零初始状态，采用 IEEE 802.11a Annex G 示例值 |

脚本会检查 `data_bits_per_symbol = coded_bits_per_symbol × code_rate`，避免修改参数时编码位数与数据位数不匹配。调制和速率参数目前用于说明系统配置；真正影响补零计算的是 `data_bits_per_symbol`。

## 4. 数据长度计算

`de2bi(..., 'right-msb')` 将每个字节按最低有效位在前的顺序转换为 bit；转置后再按行展开，保持字节顺序。

| 阶段 | 计算 | 长度 |
| --- | --- | ---: |
| 原始数据 | 1~130 | 130 bytes = 1,040 bits |
| 重复后数据 | 130 bytes × 8 | 1,040 bytes = 8,320 bits |
| 添加 SERVICE 和 TAIL | 8,320 + 16 + 6 | 8,342 bits |
| OFDM 符号数 | ceil(8,342 / 24) | 348 |
| 补零 | 348 × 24 - 8,342 | 10 bits |
| 最终 bit 流 | 8,342 + 10 | 8,352 bits |

## 5. 加扰实现

加扰器使用 7 位线性反馈移位寄存器，生成多项式为 `x^7 + x^4 + 1`。每个时钟周期将寄存器第  7 位与第 4 位异或得到扰码位，然后移位并将反馈位移入寄存器的 x1；扰码位再与对应的数据位异或。先处理生成全部的加扰序列，数据最后和整个序列进行异或。最后恢复 TAIL 位，全部置零。