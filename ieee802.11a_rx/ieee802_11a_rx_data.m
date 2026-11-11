function [rx_payload_bytes, crc_ok, metrics] = ieee802_11a_rx_data(rx_waveform, sample_rate_hz, plot_enable)
%ieee802_11a_rx_data  数据字段接收：去CP→FFT→均衡→导频跟踪→BPSK解调→解交织→Viterbi→解扰→CRC。
%
%   [rx_bytes, crc_ok, metrics] = ieee802_11a_rx_data(rx_waveform, sample_rate_hz)
%   [rx_bytes, crc_ok, metrics] = ieee802_11a_rx_data(rx_waveform, sample_rate_hz, plot_enable)
%
%   输入：
%     rx_waveform    - 已同步、已截取的数据字段复基带波形（1×55840，40 MHz，含 CP）
%     sample_rate_hz - 采样率（Hz，40e6）
%     plot_enable    - 是否绘图（默认 false）
%   输出：
%     rx_payload_bytes - 恢复的 1040 字节（uint8 1×1040）
%     crc_ok           - CRC-32 校验是否通过（logical）
%     metrics          - struct：ber、evm_db、n_symbols、n_bit_errors、phase_track
%
%   范围边界：前导（定时/频偏同步、LTF 信道估计）与 SIGNAL（LENGTH）由其他同学负责，
%   本函数只处理已同步、已截取的数据字段，自包含完成均衡与导频跟踪。

if nargin < 3 || isempty(plot_enable)
    plot_enable = false;
end

%% 常量（与 tx_data 对齐）
if abs(sample_rate_hz - 40e6) > 1e-6
    error('当前仅支持 40 MHz 采样率。');
end
oversampled_fft_size = 128;
cyclic_prefix_length = 32;
symbol_duration = oversampled_fft_size + cyclic_prefix_length;   % 160 点/符号

data_subcarrier_indices = [-26:-22, -20:-8, -6:-1, 1:6, 8:20, 22:26];   % 48 个数据子载波
pilot_subcarrier_indices = [-21, -7, 7, 21];                            % 4 个导频
pilot_symbol_base = [1; 1; 1; -1];                                      % 导频基值

service_bit_count = 16;
tail_bit_count = 6;
fcs_bit_count = 32;
payload_byte_count = 1040;                                              % 130 字节 × 8 次重复
payload_data_bit_count = payload_byte_count * 8;                        % 8320
payload_with_fcs_bit_count = payload_data_bit_count + fcs_bit_count;    % 8352

coded_bits_per_symbol = 48;
scrambler_seed = [1 0 1 1 1 0 1];
trellis = poly2trellis(7, [133 171]);

%% 导频极性序列（与 TX 一致：x^7+x^4+1 扰码器，全 1 初态，0→+1、1→-1）
pilot_sequence_bits = zeros(1, 127);
pilot_scrambler_state = ones(1, 7);
for pilot_index = 1:numel(pilot_sequence_bits)
    pilot_sequence_bits(pilot_index) = xor( ...
        pilot_scrambler_state(1), pilot_scrambler_state(4));
    pilot_scrambler_state = [pilot_scrambler_state(2:end), ...
        pilot_sequence_bits(pilot_index)];
end
pilot_polarity_sequence = 1 - 2 * pilot_sequence_bits;                  % p_0...p_126

%% 1) 去 CP
rx_waveform = rx_waveform(:).';
if mod(numel(rx_waveform), symbol_duration) ~= 0
    error('输入长度必须是 %d 的整数倍（每个含 CP 符号 %d 点）。', ...
        symbol_duration, symbol_duration);
end
data_symbol_count = numel(rx_waveform) / symbol_duration;

symbols_with_cp = reshape(rx_waveform, symbol_duration, data_symbol_count);
symbols = symbols_with_cp(cyclic_prefix_length + 1 : end, :);   % 128 × N_sym

%% 2) FFT（自然频率顺序，子载波 k 位于 mod(k,128)+1）
freq_symbols = fft(symbols, oversampled_fft_size, 1);           % 128 × N_sym

data_bins = mod(data_subcarrier_indices, oversampled_fft_size) + 1;
pilot_bins = mod(pilot_subcarrier_indices, oversampled_fft_size) + 1;

Y_data = freq_symbols(data_bins, :);        % 48 × N_sym
Y_pilot = freq_symbols(pilot_bins, :);      % 4 × N_sym

%% 3) 均衡：导频信道估计（各符号平均，去极性）+ 线性插值 + 零强制
% 注意：TX 的 128 点 IFFT 乘了 2 补偿 1/N，因此 FFT 输出是频域符号的 2 倍；
% 该因子被 H 吸收，均衡后数据符号恢复为 ±1。
pilot_polarity_indices = mod(1:data_symbol_count, 127) + 1;   % 首个 DATA 符号用 p_1
H_p_all = complex(zeros(4, data_symbol_count));
for sym = 1:data_symbol_count
    X_pilot = pilot_symbol_base * pilot_polarity_sequence(pilot_polarity_indices(sym));
    H_p_all(:, sym) = Y_pilot(:, sym) ./ X_pilot;              % 去极性后的信道估计
end
H_fixed = mean(H_p_all, 2);                 % 4 × 1（静态信道估计）
H_data = interp1(pilot_subcarrier_indices, H_fixed.', ...
    data_subcarrier_indices, 'linear', 'extrap').';   % 48 × 1
Y_eq = Y_data ./ H_data;                    % 48 × N_sym

%% 4) 导频跟踪：逐符号残余公共相位（CPE）校正
Y_out = complex(zeros(size(Y_eq)));
phase_track = zeros(1, data_symbol_count);
for sym = 1:data_symbol_count
    ratio = H_p_all(:, sym) .* conj(H_fixed);   % 残余复增益（相对固定信道）
    phi = angle(mean(ratio));
    phase_track(sym) = phi;
    Y_out(:, sym) = Y_eq(:, sym) * exp(-1j * phi);
end

%% 5) BPSK 解调：+1 -> 0，-1 -> 1
rx_bits = double(real(Y_out) < 0);          % 48 × N_sym

%% 6) 解交织（BPSK 下第二级置换为恒等，只做第一级）
k = 0:(coded_bits_per_symbol - 1);
i_perm = (coded_bits_per_symbol / 16) * mod(k, 16) + floor(k / 16);
deint_bits = zeros(size(rx_bits));
deint_bits(k + 1, :) = rx_bits(i_perm + 1, :);
coded_bits_rx = reshape(deint_bits, 1, []);  % 1 × 16752

%% 7) Viterbi 译码（硬判决、截尾）
decoded_bits = vitdec(coded_bits_rx, trellis, 48, 'trunc', 'hard');   % 1 × 8376

%% 8) 解扰（生成与 TX 相同的扰码序列后 XOR）
scrambling_sequence = zeros(1, numel(decoded_bits));
scrambler_state = scrambler_seed;
for bit_index = 1:numel(decoded_bits)
    scrambling_sequence(bit_index) = xor(scrambler_state(1), scrambler_state(4));
    scrambler_state = [scrambler_state(2:end), scrambling_sequence(bit_index)];
end
padded_bits_rx = double(xor(decoded_bits, scrambling_sequence));

%% 9) 拆帧 + CRC：SERVICE / 数据+FCS / TAIL / PAD
payload_bits_rx = padded_bits_rx(service_bit_count + 1 : ...
    service_bit_count + payload_with_fcs_bit_count);     % 8352 bit
data_bits_rx = payload_bits_rx(1:payload_data_bit_count);        % 8320 bit
fcs_bits_rx = payload_bits_rx(payload_data_bit_count + 1 : end); % 32 bit

crc_polynomial_reflected = uint32(hex2dec('EDB88320'));
crc_register = uint32(hex2dec('FFFFFFFF'));
for k = 1:numel(data_bits_rx)
    feedback_bit = xor(bitget(crc_register, 1), data_bits_rx(k));
    crc_register = bitshift(crc_register, -1);
    if feedback_bit
        crc_register = bitxor(crc_register, crc_polynomial_reflected);
    end
end
crc_value_rx = bitxor(crc_register, uint32(hex2dec('FFFFFFFF')));
crc_ok = isequal(double(bitget(crc_value_rx, 1:32)), fcs_bits_rx);

%% 10) 重组字节（每字节 LSB 先发）
byte_bits = reshape(data_bits_rx, 8, []);
rx_payload_bytes = uint8((2.^(0:7)) * byte_bits);

%% 指标
expected_payload_bytes = repmat(uint8(1:130), 1, 8);
expected_bits = double(reshape(int2bit(expected_payload_bytes, 8, false), 1, []));
bit_errors = sum(data_bits_rx ~= expected_bits);
metrics.ber = bit_errors / numel(expected_bits);
metrics.n_bit_errors = bit_errors;
metrics.n_symbols = data_symbol_count;
metrics.evm_db = 20 * log10(max(sqrt(mean(abs(Y_out - sign(real(Y_out))).^2, 'all')), eps));
metrics.phase_track = phase_track;

%% 可选绘图
if plot_enable
    figure('Name', 'RX 均衡后星座图');
    plot(real(Y_out), imag(Y_out), 'b.', 'MarkerSize', 4);
    axis equal; grid on;
    xlabel('同相分量 I'); ylabel('正交分量 Q');
    title(sprintf('均衡 + 导频跟踪后 BPSK 星座（%d 个符号）', numel(Y_out)));

    figure('Name', 'RX 导频相位跟踪');
    plot(1:data_symbol_count, phase_track * 180 / pi, '.-');
    grid on;
    xlabel('OFDM 符号编号'); ylabel('残余公共相位 (度)');
    title('导频跟踪：逐符号残余公共相位');
end
end
