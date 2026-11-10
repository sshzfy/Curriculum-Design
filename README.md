# 通信原理课程设计

## 1. 当前实现范围

`IEEE802_11a_tx.m` 当前完成 6 Mbps 模式下从测试 PSDU 到 DATA OFDM 时域波形：生成测试字节、追加 CRC-32 FCS、添加 SERVICE/TAIL 和 OFDM PAD、加扰、卷积编码、交织、BPSK 调制、数据子载波映射、导频插入、2 倍频域补零上采样、128 点 IFFT 和循环前缀添加。

脚本输出的是不含 PLCP 前导码和 SIGNAL 字段的 DATA 符号波形，因此还不是完整的 IEEE 802.11a PPDU。

## 2. 运行环境

- 提供 `int2bit` 函数的 MATLAB 版本。
- Communications Toolbox（提供 `int2bit`、`poly2trellis` 和 `convenc`）。
- 在 MATLAB 当前文件夹切换到本项目目录，然后运行：

  ```matlab
  IEEE802_11a_tx
  ```

运行后，`payload_data_bits`、`crc_value`、`crc_bits_row`、`payload_bits`、`padded_bits`、`scrambled_bits`、`coded_bits`、`interleaved_bits`、`BPSK_data`、`pilot_polarity_sequence`、`pilot_subcarrier_symbols`、`frequency_domain_symbols`、`upsampled_frequency_domain_symbols`、`time_domain_symbols`、`ofdm_symbols_with_cp` 和 `transmit_waveform` 等变量会保留在工作区。各矩阵按列存放 OFDM 符号；`transmit_waveform` 是按符号顺序串行化后的复数行向量。

## 3. 系统参数

| 参数 | 默认值 | 说明 |
| --- | ---: | --- |
| `data_rate_mbps` | 6 | 目标数据速率，Mbps |
| `bits_per_subcarrier` | 1 | BPSK 每个子载波承载 1 bit |
| `coded_bits_per_symbol` | 48 | 每个 OFDM 符号的编码位数（N<sub>CBPS</sub>） |
| `data_bits_per_symbol` | 24 | 6 Mbps、编码率 1/2 时每个 OFDM 符号的数据位数（N<sub>DBPS</sub>） |
| `fft_size` | 64 | 基础频域网格长度；上采样后执行 128 点 IFFT |
| `upsampling_factor` | 2 | 频域补零插值倍率 |
| `oversampled_fft_size` | 128 | 上采样后的 IFFT 点数 |
| `sample_rate_hz` | 40 MHz | 上采样后的复基带采样率 |
| `cyclic_prefix_length` | 32 samples | 每个 DATA 符号的循环前缀长度（0.8 µs） |
| `code_rate` | 1/2 | 编码率 |
| `repeat_count` | 8 | 将 1~130 的测试字节序列重复 8 次 |
| `bits_per_byte` | 8 | 每个字节的位数 |
| `scrambler_seed` | `1011101` | 7 位非零初始状态，采用 IEEE 802.11a Annex G 示例值 |

调制和速率参数用于说明系统配置；当前数据位流长度和补零计算由 `data_bits_per_symbol` 决定。

## 4. 数据长度计算

`int2bit(..., 8, false)` 按列输出每个字节的 8 个位，第一行为最低有效位；MATLAB 的 `reshape` 按列优先展开，因此直接展平即可保持字节顺序，使每个字节最低有效位先发送。

| 阶段 | 计算 | 长度 |
| --- | --- | ---: |
| 原始数据 | 1~130 | 130 bytes = 1,040 bits |
| 重复后数据 | 130 bytes × 8 | 1,040 bytes = 8,320 bits |
| 添加 CRC-32 FCS | 8,320 + 32 | 8,352 bits |
| 添加 SERVICE 和 TAIL | 8,352 + 16 + 6 | 8,374 bits |
| OFDM 符号数 | ceil(8,374 / 24) | 349 |
| 补零 | 349 × 24 - 8,374 | 2 bits |
| 最终 bit 流 | 8,374 + 2 | 8,376 bits |
| 卷积编码（率 1/2） | 8,376 × 2 | 16,752 bits |
| 交织 | 349 symbols × 48 bits | 16,752 bits |
| 频域资源映射 | 349 symbols × 64 bins | 每符号 48 个数据子载波、4 个导频和 12 个空载波 |

## 5. CRC-32 FCS

脚本按 IEEE 802.11 FCS 使用 CRC-32：标准多项式为 `0x04C11DB7`，位反射实现使用 `0xEDB88320`，CRC 寄存器初值为 `0xFFFFFFFF`，计算结束后再与 `0xFFFFFFFF` 异或。测试数据的每个字节以最低有效位先行，因此 CRC 也逐位按该顺序计算；32 位 FCS 按最低有效位先行追加到数据末尾。

FCS 只覆盖 PSDU 数据，不覆盖 SERVICE、TAIL 或 OFDM PAD。当前示例没有生成 MAC 头部，重复后的测试字节序列作为 CRC 输入。`payload_data_bits` 是 FCS 前的数据，`crc_value` 是 32 位数值结果，`bitget(crc_value, 1:32)` 按最低有效位先行得到 FCS，`payload_bits` 是追加 FCS 后的 PSDU；当前示例的 FCS 为 `0x3640D343`。

## 6. 加扰实现

加扰器使用 7 位线性反馈移位寄存器，生成多项式为 `x^7 + x^4 + 1`。每个时钟周期将寄存器第  7 位与第 4 位异或得到扰码位，然后移位并将反馈位移入寄存器的 x1；扰码位再与对应的数据位异或。先处理生成全部的加扰序列，数据最后和整个序列进行异或。最后恢复 TAIL 位，全部置零。

## 7. 卷积编码

卷积编码使用约束长度 `K=7`、生成多项式 `[133 171]`（八进制），码率为 1/2。输入流中已有 6 个全零 TAIL 位，用于将编码器状态归零；因此本示例的 8,376 个输入位编码为 16,752 个输出位。

## 8. 交织

交织器按每个 OFDM 符号的 `N_CBPS = coded_bits_per_symbol = 48` 个编码位分别处理。对符号内零起始输入索引 `k`，两级置换为：

```text
i = (N_CBPS / 16) × (k mod 16) + floor(k / 16)
s = max(N_BPSC / 2, 1)
j = s × floor(i / s) + (i + N_CBPS - floor(16 × i / N_CBPS)) mod s
```

其中 `N_BPSC = bits_per_subcarrier`。`coded_bits(k)` 被放到交织输出位置 `j`；代码使用 MATLAB 的 1 起始索引时会对 `k`、`j` 加 1。当前 6 Mbps BPSK 模式下 `N_BPSC = 1`，因此 `s = 1`，第二级置换为恒等映射。交织只改变每个 48 位符号内部的位序，不改变总位数；脚本也会检查编码位总数能否被 `N_CBPS` 整除。

## 9. 子载波映射与导频

每个 OFDM 符号的 48 个 BPSK 数据值依次放在以下子载波编号：`[-26:-22, -20:-8, -6:-1, 1:6, 8:20, 22:26]`。四个导频位于 `[-21, -7, 7, 21]`；其余 12 个载波（DC、保护带和 Nyquist 空载波）保持为零。标准载波编号 `k` 转成 MATLAB 64 点频域网格的自然频率顺序时使用索引 `mod(k, 64) + 1`，不需要 `fftshift`。`frequency_domain_symbols` 是上采样步骤的输入，补零后生成 128 点 IFFT 输入。

导频基值按 `[-21, -7, 7, 21]` 的顺序为 `[1, 1, 1, -1]`，再乘以 IEEE 802.11a 的 127 项极性序列。序列由同一 `x^7 + x^4 + 1` 扰码器、全 1 初态生成，输出 0 映射为 +1，输出 1 映射为 -1。标准中的 `p_0` 用于 SIGNAL 符号；本脚本只生成 DATA 符号，所以第一个 DATA 符号使用 `p_1`，后续循环使用该 127 项序列。

## 10. 频域上采样、IFFT 与循环前缀

64 点频谱按自然频率顺序在正、负频率两部分之间补入 64 个零，形成 128 点频谱；负频率子载波移动到新频谱末尾，原有子载波编号和 312.5 kHz 间隔不变。沿每列执行 128 点 IFFT，并乘以 2 补偿 MATLAB IFFT 的 `1/N` 归一化，使波形幅度与 64 点 IFFT 的结果一致。该频域补零方式用于将基本 20 MHz 采样率提高到 40 MHz。

每个 128 点有效 OFDM 符号前添加末尾 32 个采样点作为循环前缀。40 MHz 采样率下，32 点对应 0.8 µs；有效符号为 3.2 µs，因此加 CP 后每个符号共 160 点、持续 4 µs。当前示例生成 349 个 DATA 符号：`frequency_domain_symbols` 为 64×349，`upsampled_frequency_domain_symbols` 和 `time_domain_symbols` 为 128×349，`ofdm_symbols_with_cp` 为 160×349，`transmit_waveform` 含 55,840 个复采样点。

采样率和频域插值方法参考《通信原理课程设计实验指导书2023》第 1.2.3 和 1.5.1 节。该波形尚未拼接短/长训练序列或 SIGNAL 字段，也未执行 DAC 量化和射频发送。

## 11. 可视化

脚本末尾的“绘图”部分生成三张 MATLAB 图窗：

1. **时域波形图**：前 2 个含循环前缀的 DATA OFDM 符号的实部（I）与虚部（Q），并标出每个符号循环前缀的结束位置。
2. **星座图**：所有实际发送的 BPSK 数据符号（`0 → +1`、`1 → -1`），标出同相/正交分量坐标轴与 bit 对应关系。
3. **功率谱密度图**：完整串行发射波形的 Welch 功率谱密度，频率单位为 MHz，功率谱密度单位为 dB/Hz。
