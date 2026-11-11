function varargout = tx_signal_field(sample_rate_hz, length_bytes, plot_enable)
%tx_signal_field  SIGNAL 字段
%
%   用法一（接口，供组帧调用）：
%     sig = tx_signal_field(40e6, 130)            生成并绘图，返回 40 MHz 波形
%     sig = tx_signal_field(40e6, 130, false)     只生成不绘图
%
%   用法二（独立运行，保留脚本式运行能力）：
%     tx_signal_field                             直接运行，等价于原 signal 脚本
%
%   输入：
%     sample_rate_hz - 采样率（Hz，默认 40e6）
%     length_bytes   - SIGNAL LENGTH 字段的 PSDU 字节数（默认 130）
%     plot_enable    - true 时按原 signal.m 的绘图输出（默认 true）
%   输出 signal_waveform：SIGNAL 字段复基带波形，1×N 行向量（160 samples / 4 us，40 MHz）。
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

% ---------------- 默认参数----------------
if nargin < 1 || isempty(sample_rate_hz), sample_rate_hz = 40e6; end
if nargin < 2 || isempty(length_bytes),   length_bytes   = 130;  end
if nargin < 3 || isempty(plot_enable),    plot_enable    = true; end

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

% ---------------- 20 MHz 基带过程----------------
time_domain_20 = ifft(freq_64, Nfft);                 % 64 点 @ 20 MHz
cp_20 = 16;
time_domain_cp_20 = [time_domain_20(end-cp_20+1:end), time_domain_20];   % 80 点

% ---------------- 6. 频域 2 倍上采样：64 点 -> 128 点（20 MHz -> 40 MHz）----------------
% 正、负频率之间补 64 个零（理想带限插值），与 DATA 字段 tx_data 完全一致。
freq_128 = zeros(1, Nup);
freq_128(1:Nfft/2) = freq_64(1:Nfft/2);
freq_128(Nup - Nfft/2 + 1 : Nup) = freq_64(Nfft/2+1:end);

% ---------------- 7. 40 MHz IFFT 与循环前缀 ----------------
time_domain_40 = os * ifft(freq_128, Nup);            % 128 点 @ 40 MHz，×2 补偿 1/N 归一化
signal_waveform = [time_domain_40(end-Ncp+1:end), time_domain_40];       % 160 点
signal_waveform = signal_waveform(:).';

% ---------------- 自检 ----------------
expected_len = os * (Nfft + 16);                     % 160 @ 40 MHz
assert(numel(signal_bits) == 24, 'SIGNAL 域应为 24 bit');
assert(mod(sum(signal_bits), 2) == 0, 'SIGNAL 域偶校验不成立');
assert(numel(coded_bits) == 48, '卷积编码后应为 48 bit');
assert(numel(signal_waveform) == expected_len, ...
    sprintf('SIGNAL 长度应为 %d 点，实际 %d 点', expected_len, numel(signal_waveform)));

% ================= 原 signal.m 的绘图 ================
if plot_enable
    figure('Name', 'IEEE 802.11a SIGNAL 域生成过程', 'Position', [50 50 1500 950]);
    
    % (1) SIGNAL 域 24 bit
    subplot(4,2,1);
    stem(0:length(signal_bits)-1, signal_bits, 'filled', 'MarkerSize', 6);
    title('SIGNAL 域比特 (24 bit)');
    xlabel('比特索引 (0 ~ 23)'); ylabel('逻辑值');
    xticks(0:2:24); ylim([-0.5 1.5]); grid on;
    
    % (2) 卷积编码后 48 bit
    subplot(4,2,2);
    stem(0:length(coded_bits)-1, coded_bits, 'filled', 'MarkerSize', 4);
    title('卷积编码后比特 (48 bit)');
    xlabel('比特索引 (0 ~ 47)'); ylabel('逻辑值');
    xticks(0:4:48); ylim([-0.5 1.5]); grid on;
    
    % (3) 交织后 48 bit
    subplot(4,2,3);
    stem(0:length(interleaved_bits)-1, interleaved_bits, 'filled', 'MarkerSize', 4);
    title('交织后比特 (48 bit)');
    xlabel('比特索引 (0 ~ 47)'); ylabel('逻辑值');
    xticks(0:4:48); ylim([-0.5 1.5]); grid on;
    
    % (4) BPSK 星座图
    subplot(4,2,4);
    plot(real(mod_symbols), imag(mod_symbols), 'ro', 'MarkerSize', 8, 'MarkerFaceColor', 'r');
    title('BPSK 调制星座图');
    xlabel('I 路幅度'); ylabel('Q 路幅度');
    xticks([-1.5 -1 0 1 1.5]); yticks([-1.5 -1 0 1 1.5]);
    xlim([-1.5 1.5]); ylim([-1.5 1.5]); grid on;
    
    % (5) 频域符号幅度
    subplot(4,2,5);
    stem(-32:31, abs(fftshift(freq_64)), 'filled', 'MarkerSize', 4);
    title('频域符号幅度 (64 点)');
    xlabel('子载波索引 (-32 ~ 31)'); ylabel('幅度');
    xticks(-32:4:32); xlim([-34 34]); grid on;
    
    % (6) IFFT 后时域符号 (64 点)
    subplot(4,2,6);
    plot(0:Nfft-1, real(time_domain_20), 'b-', 'LineWidth', 1.5); hold on;
    plot(0:Nfft-1, imag(time_domain_20), 'r-', 'LineWidth', 1.5);
    title('IFFT 后时域符号 (64 点)');
    xlabel('采样点 (0 ~ 63)'); ylabel('幅度');
    xticks(0:4:64); xlim([0 63]); grid on;
    legend('I 路', 'Q 路');
    
    % (7) 添加 CP 后的时域符号 (80 点)
    subplot(4,2,7);
    plot(0:length(time_domain_cp_20)-1, real(time_domain_cp_20), 'b-', 'LineWidth', 1.5); hold on;
    plot(0:length(time_domain_cp_20)-1, imag(time_domain_cp_20), 'r-', 'LineWidth', 1.5);
    xline(cp_20 - 0.5, 'k--', 'LineWidth', 1.5);
    yl = ylim;
    text(cp_20/2 - 1, yl(2)*0.8, '循环前缀 (CP)', 'Color', 'm', 'FontSize', 11, 'FontWeight', 'bold', 'HorizontalAlignment', 'center');
    text(cp_20 + (Nfft/2) - 1, yl(2)*0.8, '原始 IFFT 符号 (64 点)', 'Color', 'k', 'FontSize', 11, 'HorizontalAlignment', 'center');
    patch([0 cp_20-1 cp_20-1 0], [yl(1) yl(1) yl(2) yl(2)], 'm', 'FaceAlpha', 0.1, 'EdgeColor', 'none');
    title('添加循环前缀后的时域符号 (80 点)');
    xlabel('采样点 (0 ~ 79)'); ylabel('幅度');
    xticks(0:4:80); xlim([0 79]); grid on;
    legend('I 路', 'Q 路', 'Location', 'southwest');
    
    % (8) CP 重复验证 (16 点)
    subplot(4,2,8);
    plot(0:cp_20-1, real(time_domain_20(end-cp_20+1:end)), 'bo-', 'LineWidth', 2, 'MarkerFaceColor', 'b'); hold on;
    plot(0:cp_20-1, real(time_domain_cp_20(1:cp_20)), 'rx--', 'LineWidth', 2);
    title('循环前缀验证 (16 点)');
    xlabel('采样点 (0 ~ 15)'); ylabel('幅度');
    xticks(0:1:15); xlim([-0.5 15.5]); grid on;
    legend('原符号最后 16 点', 'CP 中的 16 点', 'Location', 'best');
    
    sgtitle(sprintf('IEEE 802.11a SIGNAL 域生成过程 (LENGTH = %d, 6Mbps)', length_bytes));
end

% ---------------- 输出 ----------------
if nargout >= 1
    varargout{1} = signal_waveform;
end
end
