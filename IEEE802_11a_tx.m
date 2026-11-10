clear;
clc;
close all;

%% 参数设置
data_rate_mbps = 6;            % 6 Mbps：BPSK，编码率 1/2
bits_per_subcarrier = 1;       % BPSK：每个子载波承载 1 bit
coded_bits_per_symbol = 48;    % 每个 OFDM 符号的编码位数（48 bits）
data_bits_per_symbol = 24;     % 每个 OFDM 符号的数据位数（24 bits）
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
fprintf('OFDM 符号数：%d\n', ofdm_symbol_count);
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

fprintf('加扰后 bit 流：%d bits\n', numel(scrambled_bits));

%% 卷积编码
trellis = poly2trellis(7, [133 171]);
coded_bits = reshape(convenc(scrambled_bits, trellis), 1, []);    % 卷积编码后的 bit 流

fprintf('卷积编码后 bit 流：%d bits\n', numel(coded_bits));

%% 交织
if mod(coded_bits_per_symbol, 16) ~= 0
    error('coded_bits_per_symbol 必须是 16 的整数倍。');
end

if mod(numel(coded_bits), coded_bits_per_symbol) ~= 0
    error('卷积编码后的位数必须是 coded_bits_per_symbol 的整数倍。');
end

interleaved_symbol_count = numel(coded_bits) / coded_bits_per_symbol;                        % 交织 OFDM 符号数（349）
coded_bits_matrix = reshape(coded_bits, coded_bits_per_symbol, interleaved_symbol_count);    % 48 * 349 的矩阵，每列对应一个 OFDM 符号的编码位
interleaved_bits_matrix = zeros(size(coded_bits_matrix));                                    % 48 * 349 的矩阵，用于存储交织后的 bit

% s = max(NBPSC/2,1)
interleaver_s = max(bits_per_subcarrier / 2, 1);
% 第一级置换：i = (NCBPS/16) (k mod 16) + floor(k/16), k = 0,1,…,NCBPS – 1
k = 0:(coded_bits_per_symbol - 1);
interleaver_first_permutation = (coded_bits_per_symbol / 16) * mod(k, 16) + floor(k / 16);
% 第二级置换：j = s × floor(i/s) + (i + NCBPS – floor(16 × i/NCBPS)) mod s, i = 0,1,… NCBPS – 1
interleaver_second_permutation = interleaver_s * ...
    floor(interleaver_first_permutation / interleaver_s) + ...
    mod(interleaver_first_permutation + coded_bits_per_symbol - ...
    floor(16 * interleaver_first_permutation / coded_bits_per_symbol), ...
    interleaver_s);

% 每列对应一个 OFDM 符号；将输入 k 放到最终输出位置 j。
for symbol_index = 1:interleaved_symbol_count
    interleaved_bits_matrix(interleaver_second_permutation + 1, symbol_index) = ...
        coded_bits_matrix(k + 1, symbol_index);
end

interleaved_bits = reshape(interleaved_bits_matrix, 1, []);     % 交织后的 bit 流

%% BPSK 调制：0 -> +1，1 -> -1
BPSK_data = 1 - 2 * interleaved_bits_matrix;

% 子载波映射
fft_size = 64;                                                           % 64 点 IFFT
data_subcarrier_indices = [-26:-22, -20:-8, -6:-1, 1:6, 8:20, 22:26];    % +-21 +-7 留给导频，0 用于 DC
pilot_subcarrier_indices = [-21, -7, 7, 21];                             % 用于导频的子载波索引

if numel(data_subcarrier_indices) ~= size(BPSK_data, 1)
    error('数据子载波数量必须与每个 OFDM 符号的数据调制符号数一致。');
end

% 转换到 1~64 范围
data_bin_indices = mod(data_subcarrier_indices, fft_size) + 1;                     % 数据子载波索引
pilot_bin_indices = mod(pilot_subcarrier_indices, fft_size) + 1;                   % 导频子载波索引
frequency_domain_symbols = complex(zeros(fft_size, interleaved_symbol_count));     % 频域符号矩阵
frequency_domain_symbols(data_bin_indices, :) = BPSK_data;                         % 数据子载波符号

%% 插入导频（4 个导频子载波 [-21, -7, 7, 21] 的取值为 [1, 1, 1, -1]）
pilot_symbol_base = [1; 1; 1; -1];
pilot_subcarrier_symbols = repmat(pilot_symbol_base, 1, interleaved_symbol_count);
frequency_domain_symbols(pilot_bin_indices, :) = pilot_subcarrier_symbols;

null_subcarrier_count = fft_size - numel(data_bin_indices) - numel(pilot_bin_indices);
fprintf('频域矩阵：%d bins × %d OFDM 符号\n', ...
    fft_size, size(frequency_domain_symbols, 2));
fprintf('每符号子载波：%d 数据 + %d 导频 + %d 空载波\n', ...
    numel(data_bin_indices), numel(pilot_bin_indices), null_subcarrier_count);

%% 上采样
upsampling_factor = 2;
base_sample_rate_hz = 20e6;                                  % 基础采样率 20 MHz
sample_rate_hz = base_sample_rate_hz * upsampling_factor;    % 上采样后的采样率 40 MHz
oversampled_fft_size = fft_size * upsampling_factor;         % 上采样后的 IFFT 点数 128

if mod(fft_size, 2) ~= 0
    error('频域补零上采样要求 fft_size 为偶数。');
end

% 在正、负频率部分之间补零，保持原有子载波编号及间隔。
% 原 64 点频谱的后半部分（负频率）移到 128 点频谱末尾。
half_fft_size = fft_size / 2;
upsampled_frequency_domain_symbols = complex(zeros(oversampled_fft_size, interleaved_symbol_count));    % 128 * 349 的矩阵，用于存储上采样后的频域符号
upsampled_frequency_domain_symbols(1:half_fft_size, :) = frequency_domain_symbols(1:half_fft_size, :);
upsampled_frequency_domain_symbols(oversampled_fft_size - half_fft_size + 1:end, :) = frequency_domain_symbols(half_fft_size + 1:end, :);

fprintf('频域 2 倍上采样：%d -> %d 点，采样率 %.0f MHz\n', ...
    fft_size, oversampled_fft_size, sample_rate_hz / 1e6);

%% IFFT
time_domain_symbols = ifft(upsampled_frequency_domain_symbols, oversampled_fft_size, 1) * upsampling_factor;

fprintf('时域 OFDM 符号矩阵：%d samples × %d symbols\n', ...
    size(time_domain_symbols, 1), size(time_domain_symbols, 2));

%% 循环前缀 CP
cyclic_prefix_fraction = 1 / 4;                                          % 循环前缀占 OFDM 符号长度的 1/4
cyclic_prefix_length = oversampled_fft_size * cyclic_prefix_fraction;    % 循环前缀长度 32 个采样点
cyclic_prefix_duration_s = cyclic_prefix_length / sample_rate_hz;        % 循环前缀时长 0.8 us

cyclic_prefix_samples = time_domain_symbols(end - cyclic_prefix_length + 1:end, :);     % 循环前缀样本
ofdm_symbols_with_cp = [cyclic_prefix_samples; time_domain_symbols];                    % 含循环前缀的 OFDM 符号矩阵

% 按列序排列 OFDM 符号，生成连续发送的行向量复基带波形。
transmit_waveform = ofdm_symbols_with_cp(:).';

fprintf('循环前缀：%d samples (%.1f us)\n', ...
    cyclic_prefix_length, cyclic_prefix_duration_s * 1e6);

%% 绘图

% -------------------------------
% 1) 时域波形图
% -------------------------------
% 展示前若干个含循环前缀的 DATA OFDM 符号，并标出循环前缀结束位置。
plot_symbol_count = 2;                                                                    % 显示 OFDM 符号个数
plot_sample_count = (oversampled_fft_size + cyclic_prefix_length) * plot_symbol_count;    % 每个 OFDM 符号的样本数
plot_waveform = transmit_waveform(1:plot_sample_count);
plot_time_axis_us = (0:(plot_sample_count - 1)) / sample_rate_hz * 1e6;

symbol_duration_us = (oversampled_fft_size + cyclic_prefix_length) / sample_rate_hz * 1e6;    % 每个含 CP 符号的时长，4 us
cp_duration_us = cyclic_prefix_duration_s * 1e6;                                              % CP 时长，0.8 us

figure('Name', '时域波形图');

% 实部
subplot(2, 1, 1);
plot(plot_time_axis_us, real(plot_waveform), 'b');
hold on;
i_ylim = [min(real(plot_waveform)), max(real(plot_waveform))];
i_pad = 0.15 * (i_ylim(2) - i_ylim(1));
i_ylim = [i_ylim(1) - i_pad, i_ylim(2) + i_pad];
for sym = 1:plot_symbol_count
    cp_start_us = (sym - 1) * symbol_duration_us;
    cp_end_us = cp_start_us + cp_duration_us;
    patch([cp_start_us, cp_end_us, cp_end_us, cp_start_us], ...
        [i_ylim(1), i_ylim(1), i_ylim(2), i_ylim(2)], ...
        [1, 0.85, 0.85], 'FaceAlpha', 0.4, 'EdgeColor', 'none');
    xline(cp_end_us, '--k');
end
plot(plot_time_axis_us, real(plot_waveform), 'b', 'LineWidth', 1.2);
text(cp_duration_us / 2, i_ylim(2), 'CP', ...
    'HorizontalAlignment', 'center', 'VerticalAlignment', 'top', ...
    'Color', [0.7, 0, 0], 'FontWeight', 'bold');
text((symbol_duration_us + cp_duration_us) / 2, i_ylim(2), '有效符号', ...
    'HorizontalAlignment', 'center', 'VerticalAlignment', 'top', ...
    'Color', [0, 0, 0.7], 'FontWeight', 'bold');
ylim(i_ylim);
grid on;
ylabel('同相分量 I');
title(sprintf('DATA OFDM 时域波形（前 %d 个符号，实部）', plot_symbol_count));
hold off;

% 虚部
subplot(2, 1, 2);
plot(plot_time_axis_us, imag(plot_waveform), 'r');
hold on;
q_ylim = [min(imag(plot_waveform)), max(imag(plot_waveform))];
q_pad = 0.15 * (q_ylim(2) - q_ylim(1));
q_ylim = [q_ylim(1) - q_pad, q_ylim(2) + q_pad];
for sym = 1:plot_symbol_count
    cp_start_us = (sym - 1) * symbol_duration_us;
    cp_end_us = cp_start_us + cp_duration_us;
    patch([cp_start_us, cp_end_us, cp_end_us, cp_start_us], ...
        [q_ylim(1), q_ylim(1), q_ylim(2), q_ylim(2)], ...
        [1, 0.85, 0.85], 'FaceAlpha', 0.4, 'EdgeColor', 'none');
    xline(cp_end_us, '--k');
end
plot(plot_time_axis_us, imag(plot_waveform), 'r', 'LineWidth', 1.2);
text(cp_duration_us / 2, q_ylim(2), 'CP', ...
    'HorizontalAlignment', 'center', 'VerticalAlignment', 'top', ...
    'Color', [0.7, 0, 0], 'FontWeight', 'bold');
text((symbol_duration_us + cp_duration_us) / 2, q_ylim(2), '有效符号', ...
    'HorizontalAlignment', 'center', 'VerticalAlignment', 'top', ...
    'Color', [0, 0, 0.7], 'FontWeight', 'bold');
ylim(q_ylim);
grid on;
xlabel('时间 (\mus)');
ylabel('正交分量 Q');
title(sprintf('DATA OFDM 时域波形（前 %d 个符号，虚部）', plot_symbol_count));
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
% 3) 子载波映射图
% -------------------------------
% 展示第一个 DATA OFDM 符号在 64 个子载波上的分配：
% 48 个数据子载波（蓝）、4 个导频（红）、12 个空载波（灰叉，含 DC）。
subcarrier_axis = -fft_size / 2:(fft_size / 2 - 1);    % -32 ~ 31
null_subcarrier_indices = setdiff(subcarrier_axis, ...
    [data_subcarrier_indices, pilot_subcarrier_indices]);

figure('Name', '子载波映射图');
hold on;
stem(data_subcarrier_indices, real(BPSK_data(:, 1)), 'b', 'filled');
stem(pilot_subcarrier_indices, real(pilot_subcarrier_symbols(:, 1)), 'r', 'filled');
plot(null_subcarrier_indices, zeros(size(null_subcarrier_indices)), ...
    'x', 'Color', [0.55 0.55 0.55], 'MarkerSize', 6);
xline(0, ':k');    % DC 子载波
grid on;
xlim([-32 31]);
ylim([-1.5 1.5]);
xlabel('子载波编号');
ylabel('符号值');
title(sprintf('子载波映射（第 1 个 DATA OFDM 符号）：%d 数据 + %d 导频 + %d 空载波', ...
    numel(data_subcarrier_indices), numel(pilot_subcarrier_indices), ...
    numel(null_subcarrier_indices)));
legend({'数据子载波', '导频子载波', '空载波'}, 'Location', 'southoutside', ...
    'Orientation', 'horizontal');
hold off;

% -------------------------------
% 4) 上采样后频域图
% -------------------------------
% 频域 2 倍补零上采样：原 64 点频谱在正、负频率之间插入 64 个零，
% 得到 128 点频谱（前 32 个 bin 与后 32 个 bin 为原符号，中间 64 个 bin 补零）。
upsampled_first_symbol = upsampled_frequency_domain_symbols(:, 1);

figure('Name', '上采样后频域图');
subplot(2, 1, 1);
stem(1:fft_size, real(frequency_domain_symbols(:, 1)), 'b', 'filled');
grid on;
xlim([0 fft_size + 1]);
ylabel('符号值');
title('上采样前：64 点频域符号（第 1 个 DATA 符号）');

subplot(2, 1, 2);
stem(1:oversampled_fft_size, real(upsampled_first_symbol), 'r', 'filled');
hold on;
xline(half_fft_size + 0.5, ':k');
xline(oversampled_fft_size - half_fft_size + 0.5, ':k');
grid on;
xlim([0 oversampled_fft_size + 1]);
xlabel('频域 bin 编号');
ylabel('符号值');
title('上采样后：128 点频域符号（中间 64 个 bin 补零）');
hold off;

% -------------------------------
% 5) 功率谱密度图（pwelch）
% -------------------------------
% 使用 Signal Processing Toolbox 的 pwelch 计算完整发射波形的功率谱密度。
% 参数：汉宁窗 4096 点、50% 重叠（2048 点）、8192 点 FFT、输出以 DC 为中心。
[power_spectral_density, psd_frequency_hz] = pwelch(transmit_waveform(:), ...
    hann(4096, 'periodic'), 2048, 8192, sample_rate_hz, 'centered', 'psd');

figure('Name', '功率谱密度图');
plot(psd_frequency_hz / 1e6, ...
    10 * log10(max(power_spectral_density, realmin('double'))));
grid on;
xlabel('频率 (MHz)');
ylabel('功率谱密度 (dB/Hz)');
title('完整 DATA 发射波形的功率谱密度');
