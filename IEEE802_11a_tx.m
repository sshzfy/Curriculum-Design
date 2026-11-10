clear;
clc;
close all;

%% 参数设置
data_rate_mbps = 6;            % 6 Mbps：BPSK，编码率 1/2
bits_per_subcarrier = 1;       % BPSK：每个子载波承载 1 bit
coded_bits_per_symbol = 48;    % 每个 OFDM 符号的编码位数
data_bits_per_symbol = 24;     % 每个 OFDM 符号的数据位数
code_rate = 1/2;               % 编码效率
bits_per_byte = 8;
service_bit_count = 16;        % SERVICE 字段位数
tail_bit_count = 6;            % TAIL 字段位数
repeat_count = 8;              % 重复次数

%% 原始数据生成
payload_bytes = uint8(1:130);                                       % 原始数据 1~130
repeated_payload_bytes = repmat(payload_bytes, 1, repeat_count);    % 重复发送

payload_bit_matrix = int2bit(repeated_payload_bytes, bits_per_byte, false);    % 按列输出每个字节的 8 个位（第一行为最低有效位）
payload_data_bits = double(reshape(payload_bit_matrix, 1, []));                % 按列展开，保持字节顺序

% CRC-32 计算
crc_polynomial_reflected = uint32(hex2dec('EDB88320'));    % 反射多项式
crc_register = uint32(hex2dec('FFFFFFFF'));                % CRC 寄存器初始值

for k = 1:numel(payload_data_bits)
    feedback_bit = xor(bitget(crc_register, 1), payload_data_bits(k));    % 异或最低有效位和当前数据位
    crc_register = bitshift(crc_register, -1);                            % 右移一位
    if feedback_bit
        crc_register = bitxor(crc_register, crc_polynomial_reflected);    % 反馈位为 1 时，异位多项式
    end
end

crc_value = bitxor(crc_register, uint32(hex2dec('FFFFFFFF')));    % 最终 CRC 值

crc_bits_row = double(bitget(crc_value, 1:32));       % CRC 值的位展开
payload_bits = [payload_data_bits, crc_bits_row];     % 数据 + FCS

% 加上 SERVICE、TAIL 字段位
service_bits = zeros(1, service_bit_count);
tail_bits = zeros(1, tail_bit_count);
bits_before_padding = [service_bits, payload_bits, tail_bits];     % SERVICE、数据 + FCS、TAIL

%% OFDM 符号补零
ofdm_symbol_count = ceil(numel(bits_before_padding) / data_bits_per_symbol);                  % OFDM 符号数（向上取整）
padding_bit_count = ofdm_symbol_count * data_bits_per_symbol - numel(bits_before_padding);    % 补零位数
padded_bits = [bits_before_padding, zeros(1, padding_bit_count)];                             % 补零后的 bit 流

% 长度统计
fprintf('重复后数据：%d bytes (%d bits)\n', numel(repeated_payload_bytes), numel(payload_data_bits));
fprintf('CRC-32 FCS：0x%08X（32 bits）\n', crc_value);
fprintf('最终 bit 流：%d bits\n', numel(padded_bits));

%% 加扰
scrambler_seed = [1 0 1 1 1 0 1];    % x7~x1，索引为 1~7

scrambling_sequence = zeros(size(padded_bits));    % 加扰序列
scrambler_state = scrambler_seed;                  % 加扰状态

% 加扰过程：
%             ————————————————>xor———————————————
%            |                 ^                 |
%            |                 |                 v
%     输出<——x7 <- x6 <- x5 <- x4 <- x3 <- x2 <- x1 <——————— 输入数据
% x7 和 x4 位异或，作为反馈送入 x1，其他位左移一位。
for bit_index = 1:numel(padded_bits)
    scrambling_sequence(bit_index) = xor(scrambler_state(1), scrambler_state(4));    % x7 异或 x4，作为反馈送入 x1
    scrambler_state = [scrambler_state(2:end), scrambling_sequence(bit_index)];      % 更新加扰状态
end

scrambled_bits = double(xor(padded_bits, scrambling_sequence));    % 加扰后的 bit 流

% 处理 TAIL 位
tail_start_index = numel(service_bits) + numel(payload_bits) + 1;             % TAIL 位起始索引
tail_indices = tail_start_index:(tail_start_index + numel(tail_bits) - 1);    % TAIL 位索引
scrambled_bits(tail_indices) = 0;                                             % 恢复 TAIL 位为 0

fprintf('加扰后 bit 流：%d bits\n', numel(scrambled_bits));

%% 卷积编码
trellis = poly2trellis(7, [133 171]);
coded_bits = convenc(scrambled_bits, trellis);

fprintf('卷积编码后 bit 流：%d bits\n', numel(coded_bits));

%% 交织
% 交织器以每个 OFDM 符号的 N_CBPS 个编码位为单位独立处理。
if mod(coded_bits_per_symbol, 16) ~= 0
    error('coded_bits_per_symbol 必须是 16 的整数倍。');
end

coded_bits = reshape(coded_bits, 1, []);
if mod(numel(coded_bits), coded_bits_per_symbol) ~= 0
    error('卷积编码后的位数必须是 coded_bits_per_symbol 的整数倍。');
end

interleaved_symbol_count = numel(coded_bits) / coded_bits_per_symbol;    % 交织 OFDM 符号数
coded_bits_matrix = reshape(coded_bits, coded_bits_per_symbol, ...
    interleaved_symbol_count);                                           % 48 * interleaved_symbol_count 的矩阵
interleaved_bits_matrix = zeros(size(coded_bits_matrix));

% IEEE 802.11a 第一级置换：输入索引 k 映射到 i。
k = 0:(coded_bits_per_symbol - 1);
interleaver_first_permutation = ...
    (coded_bits_per_symbol / 16) * mod(k, 16) + floor(k / 16);

% 第二级置换：N_BPSC = bits_per_subcarrier，s = max(N_BPSC/2, 1)。
interleaver_s = max(bits_per_subcarrier / 2, 1);
interleaver_second_permutation = interleaver_s * ...
    floor(interleaver_first_permutation / interleaver_s) + ...
    mod(interleaver_first_permutation + coded_bits_per_symbol - ...
    floor(16 * interleaver_first_permutation / coded_bits_per_symbol), ...
    interleaver_s);

% 每列对应一个 OFDM 符号；将输入 k 放到最终输出位置 j。
for symbol_index = 1:interleaved_symbol_count
    interleaved_bits_matrix(interleaver_second_permutation + 1, ...
        symbol_index) = coded_bits_matrix(k + 1, symbol_index);
end

interleaved_bits = reshape(interleaved_bits_matrix, 1, []);

fprintf('交织 OFDM 符号数：%d\n', interleaved_symbol_count);
fprintf('交织后 bit 流：%d bits\n', numel(interleaved_bits));

%% BPSK 调制
BPSK_data = 1 - 2 * interleaved_bits_matrix;    % BPSK 符号：0 -> +1，1 -> -1

% BPSK_data 为 48 x interleaved_symbol_count 的矩阵，每列是一个 OFDM 符号的
% 48 个数据子载波调制符号；实际发送符号的星座图统一在脚本末尾的“绘图”部分绘制。

%% 子载波映射
fft_size = 64;
data_subcarrier_indices = [-26:-22, -20:-8, -6:-1, 1:6, 8:20, 22:26];    % +-21 +-7 留给导频，0 用于 DC
pilot_subcarrier_indices = [-21, -7, 7, 21];    % 用于导频的子载波索引

if numel(data_subcarrier_indices) ~= size(BPSK_data, 1)
    error('数据子载波数量必须与每个 OFDM 符号的数据调制符号数一致。');
end

% 转换到 1~64 范围
data_bin_indices = mod(data_subcarrier_indices, fft_size) + 1;
pilot_bin_indices = mod(pilot_subcarrier_indices, fft_size) + 1;
frequency_domain_symbols = complex(zeros(fft_size, interleaved_symbol_count));
frequency_domain_symbols(data_bin_indices, :) = BPSK_data;

%% 插入导频
% IEEE 802.11a 导频极性序列由 x^7 + x^4 + 1 扰码器生成，初态为全 1。
pilot_sequence_bits = zeros(1, 127);
pilot_scrambler_state = ones(1, 7);
for pilot_index = 1:numel(pilot_sequence_bits)
    pilot_sequence_bits(pilot_index) = xor( ...
        pilot_scrambler_state(1), pilot_scrambler_state(4));
    pilot_scrambler_state = [pilot_scrambler_state(2:end), ...
        pilot_sequence_bits(pilot_index)];
end

% 标准将扰码输出 0 映射为 +1、1 映射为 -1，得到 p_0 ... p_126。
pilot_polarity_sequence = 1 - 2 * pilot_sequence_bits;

% p_0 用于 SIGNAL；本脚本只生成 DATA，因此首个 OFDM 符号使用 p_1。
pilot_polarity_indices = mod(1:interleaved_symbol_count, ...
    numel(pilot_polarity_sequence)) + 1;
pilot_symbol_base = [1; 1; 1; -1];
pilot_subcarrier_symbols = pilot_symbol_base * ...
    pilot_polarity_sequence(pilot_polarity_indices);
frequency_domain_symbols(pilot_bin_indices, :) = pilot_subcarrier_symbols;

null_subcarrier_count = fft_size - numel(data_bin_indices) - ...
    numel(pilot_bin_indices);
fprintf('频域矩阵：%d bins × %d OFDM 符号\n', ...
    fft_size, size(frequency_domain_symbols, 2));
fprintf('每符号子载波：%d 数据 + %d 导频 + %d 空载波\n', ...
    numel(data_bin_indices), numel(pilot_bin_indices), null_subcarrier_count);

%% 上采样
upsampling_factor = 2;
base_sample_rate_hz = 20e6;
sample_rate_hz = base_sample_rate_hz * upsampling_factor;
oversampled_fft_size = fft_size * upsampling_factor;

if mod(fft_size, 2) ~= 0
    error('频域补零上采样要求 fft_size 为偶数。');
end

% 在正、负频率部分之间补零，保持原有子载波编号及间隔。
% 原 64 点频谱的后半部分（负频率）移到 128 点频谱末尾。
half_fft_size = fft_size / 2;
upsampled_frequency_domain_symbols = ...
    complex(zeros(oversampled_fft_size, interleaved_symbol_count));
upsampled_frequency_domain_symbols(1:half_fft_size, :) = ...
    frequency_domain_symbols(1:half_fft_size, :);
upsampled_frequency_domain_symbols(oversampled_fft_size - half_fft_size + 1:end, :) = ...
    frequency_domain_symbols(half_fft_size + 1:end, :);

fprintf('频域 2 倍上采样：%d -> %d 点，采样率 %.0f MHz\n', ...
    fft_size, oversampled_fft_size, sample_rate_hz / 1e6);

%% IFFT
% MATLAB 的 IFFT 含 1/N 归一化；乘上上采样倍率以保持 64 点 IFFT 的幅度。
time_domain_symbols = ifft(upsampled_frequency_domain_symbols, ...
    oversampled_fft_size, 1) * upsampling_factor;

fprintf('时域 OFDM 符号矩阵：%d samples × %d symbols\n', ...
    size(time_domain_symbols, 1), size(time_domain_symbols, 2));

%% 循环前缀 CP
cyclic_prefix_fraction = 1 / 4;
cyclic_prefix_length = oversampled_fft_size * cyclic_prefix_fraction;
cyclic_prefix_duration_s = cyclic_prefix_length / sample_rate_hz;

if cyclic_prefix_length ~= fix(cyclic_prefix_length)
    error('循环前缀长度必须为整数个采样点。');
end

cyclic_prefix_samples = time_domain_symbols( ...
    end - cyclic_prefix_length + 1:end, :);
ofdm_symbols_with_cp = [cyclic_prefix_samples; time_domain_symbols];

% 按列序排列 OFDM 符号，生成连续发送的行向量复基带波形。
transmit_waveform = ofdm_symbols_with_cp(:).';

fprintf('循环前缀：%d samples (%.1f us)\n', ...
    cyclic_prefix_length, cyclic_prefix_duration_s * 1e6);
fprintf('加 CP 后：%d samples × %d symbols；串行波形：%d complex samples\n', ...
    size(ofdm_symbols_with_cp, 1), size(ofdm_symbols_with_cp, 2), ...
    numel(transmit_waveform));

%% 绘图

% -------------------------------
% 1) 时域波形图
% -------------------------------
% 展示前若干个含循环前缀的 DATA OFDM 符号，并标出循环前缀结束位置。
plot_symbol_count = 4;    % 显示前 4 个 OFDM 符号
plot_sample_count = (oversampled_fft_size + cyclic_prefix_length) * ...
    plot_symbol_count;
plot_waveform = transmit_waveform(1:plot_sample_count);
plot_time_axis_us = (0:(plot_sample_count - 1)) / sample_rate_hz * 1e6;

symbol_duration_us = (oversampled_fft_size + cyclic_prefix_length) / ...
    sample_rate_hz * 1e6;                     % 每个含 CP 符号的时长
cp_duration_us = cyclic_prefix_duration_s * 1e6;    % CP 时长
cp_end_times_us = (0:(plot_symbol_count - 1)) * symbol_duration_us + ...
    cp_duration_us;                           % 每个符号 CP 结束的时刻

figure('Name', '时域波形图');
subplot(2, 1, 1);
plot(plot_time_axis_us, real(plot_waveform), 'b');
hold on;
for cp_time = cp_end_times_us
    xline(cp_time, '--k');
end
grid on;
ylabel('同相分量 I');
title('DATA OFDM 时域波形（前 2 个符号，实部）');
hold off;

subplot(2, 1, 2);
plot(plot_time_axis_us, imag(plot_waveform), 'r');
hold on;
for cp_time = cp_end_times_us
    xline(cp_time, '--k');
end
grid on;
xlabel('时间 (\mus)');
ylabel('正交分量 Q');
title('DATA OFDM 时域波形（前 2 个符号，虚部）');
hold off;

% -------------------------------
% 2) 星座图
% -------------------------------
% 展示实际发送的 BPSK 数据符号（0 -> +1，1 -> -1）。
transmitted_bpsk_symbols = BPSK_data(:);

figure('Name', '星座图');
plot(transmitted_bpsk_symbols, zeros(size(transmitted_bpsk_symbols)), ...
    'b.', 'MarkerSize', 6);
hold on;
xline(0, ':k');
yline(0, ':k');
text(-1, 0.15, 'bit 1', 'HorizontalAlignment', 'center');
text(1, 0.15, 'bit 0', 'HorizontalAlignment', 'center');
grid on;
axis equal;
xlim([-1.5 1.5]);
ylim([-0.6 0.6]);
xlabel('同相分量 I');
ylabel('正交分量 Q');
title(sprintf('BPSK 星座图（%d 个实际发送符号）', numel(transmitted_bpsk_symbols)));
hold off;

% -------------------------------
% 3) 功率谱密度图（Welch 方法）
% -------------------------------
psd_segment_length = 4096;
psd_overlap = psd_segment_length / 2;
psd_fft_length = 8192;
psd_segment_step = psd_segment_length - psd_overlap;
psd_segment_count = floor((numel(transmit_waveform) - psd_overlap) / ...
    psd_segment_step);
psd_window = 0.5 - 0.5 * cos(2 * pi * ...
    (0:psd_segment_length - 1)' / psd_segment_length);
psd_accumulator = zeros(psd_fft_length, 1);

for psd_segment_index = 1:psd_segment_count
    first_sample_index = (psd_segment_index - 1) * psd_segment_step + 1;
    last_sample_index = first_sample_index + psd_segment_length - 1;
    waveform_segment = transmit_waveform(first_sample_index:last_sample_index).';
    segment_spectrum = fftshift(fft(waveform_segment .* psd_window, ...
        psd_fft_length));
    psd_accumulator = psd_accumulator + abs(segment_spectrum).^2 / ...
        (sample_rate_hz * sum(psd_window.^2));
end

power_spectral_density = psd_accumulator / psd_segment_count;
psd_frequency_hz = (-psd_fft_length / 2:psd_fft_length / 2 - 1) * ...
    (sample_rate_hz / psd_fft_length);

figure('Name', '功率谱密度图');
plot(psd_frequency_hz / 1e6, ...
    10 * log10(max(power_spectral_density, realmin('double'))));
grid on;
xlabel('频率 (MHz)');
ylabel('功率谱密度 (dB/Hz)');
title('完整 DATA 发射波形的功率谱密度');
