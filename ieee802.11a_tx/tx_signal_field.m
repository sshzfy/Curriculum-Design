function signal_waveform = tx_signal_field(sample_rate_hz, length_bytes)
%tx_signal_field  SIGNAL 字段接口，40 MHz 复基带。
%
%   signal_waveform = tx_signal_field(sample_rate_hz, length_bytes)
%
%   输入：
%     sample_rate_hz - 采样率（Hz，本设计为 40e6）
%     length_bytes   - SIGNAL LENGTH 字段的 PSDU 字节数（当前为 130）
%   输出 signal_waveform：SIGNAL 字段复基带波形，1×N 行向量（160 samples / 4 us）。
%
%   实现依据 signal.m 的比特级流程：
%     24 bit = RATE(4, 6 Mbps=1101) + Reserved(1) + LENGTH(12, LSB first)
%              + Parity(1) + Tail(6)；
%     BPSK + 码率 1/2 卷积编码 + 交织 + 48 数据子载波 + 4 导频 [1 1 1 -1]；
%     不做加扰。
%   为使 SIGNAL 字段与 DATA 字段（tx_data）频谱对齐，本函数：
%     1) 使用自然频率顺序 mod(k,64)+1 映射子载波（而非 signal.m 的 k+33）；
%     2) 采用标准两级交织 output[i(k)] = input[k]；
%     3) 频域中间补零到 128 点 + 128 点 IFFT（×2）上采样到 40 MHz，CP 32 点。

% ---------------- 采样率契约 ----------------
base_rate = 20e6;
os = round(sample_rate_hz / base_rate);              % 40 MHz -> os = 2
assert(abs(sample_rate_hz - os * base_rate) < 1e-6, ...
    '采样率必须为 20 MHz 的整数倍（本设计为 40 MHz）。');

Nfft = 64;
Nup  = os * Nfft;                                    % 128 @ 40 MHz
Ncp  = os * 16;                                      % 循环前缀 32 点 @ 40 MHz

% ---------------- 1. SIGNAL 24 bit ----------------
rate_bits = [1 1 0 1];                               % 6 Mbps
length_bits = fliplr(double(dec2bin(length_bytes, 12) - '0'));   % LSB 先传
assert(numel(length_bits) == 12, 'LENGTH 必须能用 12 bit 表示（<=4095）。');

sig17 = [rate_bits, 0, length_bits];                 % 17 bit（RATE + R + LENGTH）
parity_bit = mod(sum(sig17), 2);                     % 偶校验
signal_bits = [sig17, parity_bit, zeros(1, 6)];      % 24 bit

% ---------------- 2. 卷积编码 R=1/2, K=7 ----------------
trellis = poly2trellis(7, [133 171]);
coded_bits = convenc(signal_bits, trellis);          % 48 bit

% ---------------- 3. 交织（标准两级置换，与 DATA 字段一致）----------------
N_CBPS = 48;
N_BPSC = 1;
k = 0:N_CBPS-1;
i_perm = (N_CBPS/16) * mod(k, 16) + floor(k/16);
s = max(N_BPSC/2, 1);
j_perm = s * floor(i_perm/s) + mod(i_perm + N_CBPS - floor(16*i_perm/N_CBPS), s);
interleaved_bits = zeros(1, N_CBPS);
interleaved_bits(j_perm + 1) = coded_bits(k + 1);    % output[j(i(k))] = input[k]

% ---------------- 4. BPSK 调制 ----------------
mod_symbols = 1 - 2 * interleaved_bits;    % BPSK: 0 -> +1, 1 -> -1（与 DATA 字段一致）

% ---------------- 5. 子载波映射（自然频率顺序，与 DATA 一致）----------------
data_sub_idx = [-26:-22, -20:-8, -6:-1, 1:6, 8:20, 22:26];   % 48 数据子载波
pilot_sub_idx = [-21, -7, 7, 21];                            % 4 导频
pilot_values = [1, 1, 1, -1];

freq_64 = zeros(1, Nfft);
freq_64(mod(data_sub_idx, Nfft) + 1) = mod_symbols;
freq_64(mod(pilot_sub_idx, Nfft) + 1) = pilot_values;

% ---------------- 6. 频域补零上采样到 128 点 ----------------
freq_128 = zeros(1, Nup);
freq_128(1:Nfft/2) = freq_64(1:Nfft/2);
freq_128(Nup - Nfft/2 + 1 : Nup) = freq_64(Nfft/2+1:end);

% ---------------- 7. IFFT 与循环前缀 ----------------
time_domain = os * ifft(freq_128, Nup);              % ×2 补偿 1/N 归一化
signal_waveform = [time_domain(end-Ncp+1:end), time_domain];
signal_waveform = signal_waveform(:).';

% ---------------- 自检 ----------------
expected_len = os * (Nfft + 16);                     % 160 @ 40 MHz
assert(numel(signal_bits) == 24, 'SIGNAL 域应为 24 bit');
assert(mod(sum(signal_bits), 2) == 0, 'SIGNAL 域偶校验不成立');
assert(numel(coded_bits) == 48, '卷积编码后应为 48 bit');
assert(numel(signal_waveform) == expected_len, ...
    sprintf('SIGNAL 长度应为 %d 点，实际 %d 点', expected_len, numel(signal_waveform)));
end
