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
repeat_count = 8;              % 重复次数

%% 原始数据生成
payload_bytes = uint8(1:130);                                       % 原始数据
repeated_payload_bytes = repmat(payload_bytes, 1, repeat_count);    % 重复发送

% 按 IEEE 802.11 位序排列：每个字节最低有效位先发送。
payload_bit_matrix = int2bit(repeated_payload_bytes, bits_per_byte, false);
payload_data_bits = double(reshape(payload_bit_matrix.', 1, []));

%% CRC-32 计算
% 反射形式多项式 0xEDB88320
% 初值和最终异或值均为 0xFFFFFFFF。
crc_polynomial_reflected = uint32(hex2dec('EDB88320'));
crc_register = uint32(hex2dec('FFFFFFFF'));

for bit_index = 1:numel(payload_data_bits)
    feedback_bit = xor(bitget(crc_register, 1) ~= 0, ...
        payload_data_bits(bit_index) ~= 0);
    crc_register = bitshift(crc_register, -1);
    if feedback_bit
        crc_register = bitxor(crc_register, crc_polynomial_reflected);
    end
end

crc_value = bitxor(crc_register, uint32(hex2dec('FFFFFFFF')));

% FCS 按最低有效位先发送，生成与 payload_data_bits 同为行向量的 PSDU 位流。
crc_bits_row = zeros(1, 32);
for crc_bit_index = 1:32
    crc_bits_row(crc_bit_index) = bitget(crc_value, crc_bit_index);
end
payload_bits = [payload_data_bits, crc_bits_row];

%% SERVICE、TAIL 和 OFDM 符号补零
service_bits = zeros(1, 16);
tail_bits = zeros(1, 6);
bits_before_padding = [service_bits, payload_bits, tail_bits];

ofdm_symbol_count = ceil(numel(bits_before_padding) / data_bits_per_symbol);    % OFDM 符号数
padding_bit_count = ofdm_symbol_count * data_bits_per_symbol - ...
    numel(bits_before_padding);                                                 % 补零位数
padded_bits = [bits_before_padding, zeros(1, padding_bit_count)];               % 补零后的 bit 流

% 长度统计
fprintf('原始数据：%d bytes (%d bits)\n', ...
    numel(payload_bytes), numel(payload_bytes) * bits_per_byte);
fprintf('重复后数据：%d bytes (%d bits)\n', ...
    numel(repeated_payload_bytes), numel(payload_data_bits));
fprintf('CRC-32 FCS：0x%08X（32 bits）\n', crc_value);
fprintf('添加 FCS 后 PSDU：%d bits\n', numel(payload_bits));
fprintf('添加 SERVICE 和 TAIL 后：%d bits\n', numel(bits_before_padding));
fprintf('OFDM 符号数：%d\n', ofdm_symbol_count);
fprintf('补零：%d bits\n', padding_bit_count);
fprintf('最终 bit 流：%d bits\n', numel(padded_bits));

%% 加扰
scrambler_seed = [1 0 1 1 1 0 1];

scrambling_sequence = zeros(size(padded_bits));    % 加扰序列
scrambler_state = scrambler_seed;                  % 加扰状态

% 加扰过程：
%             ————————————————>xor———————————————
%            |                 ^                 |
%            |                 |                 v
%     输出<——x7 <- x6 <- x5 <- x4 <- x3 <- x2 <- x1 <——————— 输入数据
% x7 和 x4 位异或，作为反馈送入 x1，其他位左移一位。
for bit_index = 1:numel(padded_bits)
    
    scrambling_sequence(bit_index) = xor( ...
        scrambler_state(1), scrambler_state(4));    % 加扰序列
    scrambler_state = [scrambler_state(2:end), ...
        scrambling_sequence(bit_index)];            % 更新加扰状态
end

scrambled_bits = double(xor(padded_bits, scrambling_sequence));    % 加扰后的 bit 流

% 处理 TAIL 位
tail_start_index = numel(service_bits) + numel(payload_bits) + 1;             % TAIL 位起始索引
tail_indices = tail_start_index:(tail_start_index + numel(tail_bits) - 1);    % TAIL 位索引
scrambled_bits(tail_indices) = 0;                                             % 恢复 TAIL 位为 0

fprintf('加扰初始状态：%s\n', sprintf('%d', scrambler_seed));
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

% BPSK 星座图
bpsk_constellation_points = [-1, 1];
figure('Name', 'BPSK 星座图');
plot(bpsk_constellation_points, zeros(size(bpsk_constellation_points)), ...
    'bo', 'MarkerFaceColor', 'b', 'MarkerSize', 8);
hold on;
xline(0, ':k');
yline(0, ':k');
text(-1, 0.12, 'bit 1', 'HorizontalAlignment', 'center');
text(1, 0.12, 'bit 0', 'HorizontalAlignment', 'center');
grid on;
axis equal;
xlim([-1.5 1.5]);
ylim([-0.3 0.3]);
xlabel('同相分量 I');
ylabel('正交分量 Q');
title('BPSK 星座图：0 映射到 +1，1 映射到 -1');
hold off;

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

% 抽取第 1 个符号的 64 点频域数据
sym_freq = frequency_domain_symbols(:, 1);

% 画图 (使用 fftshift 将 0 频移到中间，方便观察)
figure;
plot(-32:31, abs(fftshift(sym_freq)), 'bo-', 'LineWidth', 1.5);
grid on;
title('一个 OFDM 符号的频域幅度分布 (64点)');
xlabel('物理子载波频点 (k)'); ylabel('幅度');

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

%% 子载波映射图
% 显示第一个 DATA 符号的 64 个频域载波值，保留 BPSK 的正负号。
mapped_subcarrier_indices = (-fft_size / 2:fft_size / 2 - 1).';
first_mapped_symbol = fftshift(frequency_domain_symbols(:, 1));
data_carrier_mask = ismember(mapped_subcarrier_indices, ...
    data_subcarrier_indices);
pilot_carrier_mask = ismember(mapped_subcarrier_indices, ...
    pilot_subcarrier_indices);

figure('Name', '首个 DATA 符号子载波映射');
stem(mapped_subcarrier_indices, real(first_mapped_symbol), ...
    'Color', [0.75 0.75 0.75]);
hold on;
stem(mapped_subcarrier_indices(data_carrier_mask), ...
    real(first_mapped_symbol(data_carrier_mask)), 'b', 'filled');
stem(mapped_subcarrier_indices(pilot_carrier_mask), ...
    real(first_mapped_symbol(pilot_carrier_mask)), 'r', 'filled');
grid on;
xlim([-fft_size / 2, fft_size / 2 - 1]);
xlabel('子载波编号 k');
ylabel('实部 X[k]');
title('首个 DATA OFDM 符号的 64 点子载波映射');
legend('全部子载波', '数据子载波', '导频', 'Location', 'best');
hold off;

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

%% 时域波形图
first_symbol_with_cp = ofdm_symbols_with_cp(:, 1);
time_axis_us = (0:(numel(first_symbol_with_cp) - 1)) / ...
    sample_rate_hz * 1e6;
cp_boundary_time_us = cyclic_prefix_duration_s * 1e6;

figure('Name', '首个 DATA 符号时域波形');
subplot(2, 1, 1);
plot(time_axis_us, real(first_symbol_with_cp));
hold on;
xline(cp_boundary_time_us, '--k', 'CP 边界');
grid on;
ylabel('实部');
title('首个含循环前缀的 DATA OFDM 符号');
hold off;

subplot(2, 1, 2);
plot(time_axis_us, imag(first_symbol_with_cp));
hold on;
xline(cp_boundary_time_us, '--k', 'CP 边界');
grid on;
xlabel('时间 (\mus)');
ylabel('虚部');
hold off;
