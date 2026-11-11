function varargout = tx_preamble(sample_rate_hz, plot_enable)
%tx_preamble  前导序列（L-STF + L-LTF）
%
%   用法一（接口，供组帧调用）：
%     preamble = tx_preamble(40e6)         生成并绘图，返回波形
%     preamble = tx_preamble(40e6, false)  只生成不绘图
%
%   用法二（独立运行，保留脚本式运行能力）：
%     tx_preamble                         直接运行，等价于原 preambleone_fixed 脚本
%
%   输入：
%     sample_rate_hz - 采样率（Hz，默认 40e6）
%     plot_enable    - true 时按原 preambleone_fixed 的绘图输出（默认 true）
%   输出 preamble_waveform：前导序列复基带波形，1×N 行向量。
%
%   实现依据 preambleone.m / preambleone_fixed.m：64 点频域序列（自然频率
%   顺序）→ 频域中间补零到 128 点 → 128 点 IFFT（×2 补偿 1/N 归一化）→ 时域拼装。
%     短训练序列 STS：10 个短符号，每个 0.8 us（32 samples），共 320 samples；
%     长训练序列 LTF：GI2 1.6 us（64 samples）+ 2 个 3.2 us 长符号（各 128
%                     samples），共 320 samples；
%     前导总长 = STS + LTF = 640 samples（16 us）。

% ---------------- 默认参数 ----------------
if nargin < 1 || isempty(sample_rate_hz), sample_rate_hz = 40e6; end
if nargin < 2 || isempty(plot_enable),    plot_enable    = true;  end

% ---------------- 采样率契约 ----------------
base_rate = 20e6;                                    % OFDM 数学在 20 MHz
os = round(sample_rate_hz / base_rate);              % 40 MHz -> os = 2
assert(abs(sample_rate_hz - os * base_rate) < 1e-6, ...
    '采样率必须为 20 MHz 的整数倍（本设计为 40 MHz）。');

Nfft = 64;
Nup  = os * Nfft;                                    % 128 @ 40 MHz
Nsh  = 16;                                           % 短训练符号 16 点（20 MHz 域）
Nlt  = 64;                                           % 长训练符号 64 点（20 MHz 域）

% ---------------- STF 频域（64 点，自然频率顺序）----------------
stf_k = [-24 -20 -16 -12 -8 -4 4 8 12 16 20 24];
stf_v = [1+1j, -1-1j, 1+1j, -1-1j, -1-1j, 1+1j, ...
    -1-1j, -1-1j, 1+1j, 1+1j, 1+1j, 1+1j] * sqrt(13/6);   % 修正：正半轴 [-1,-1,1,1,1,1]
stf_f = zeros(1, Nfft);
stf_f(mod(stf_k, Nfft) + 1) = stf_v;

% ---------------- LTF 频域（64 点，自然频率顺序）----------------
ltf_k = -26:26;                                        % 含直流
ltf_v = [ 1,  1, -1, -1,  1,  1, -1,  1, -1,  1,  1,  1,  1,  1,  1, -1, ...
    -1,  1,  1, -1,  1, -1,  1,  1,  1,  1,  0, ...
    1, -1, -1,  1,  1, -1,  1, -1,  1, -1, -1, -1, -1, -1, ...
    1,  1, -1, -1,  1, -1,  1, -1,  1,  1,  1,  1];
ltf_f = zeros(1, Nfft);
ltf_f(mod(ltf_k, Nfft) + 1) = ltf_v;                   % DC 自动为 0

assert(abs(sum(abs(stf_f).^2) - sum(abs(ltf_f).^2)) < 1e-9, ...
    'STF 与 LTF 的频域总功率必须相等（sqrt(13/6) 保证这一点）');

% ---------------- 频域补零上采样 ----------------
pad = zeros(1, Nup - Nfft);                           % 中间补 64 个零
stf_f = [stf_f(1:Nfft/2), pad, stf_f(Nfft/2+1:end)];
ltf_f = [ltf_f(1:Nfft/2), pad, ltf_f(Nfft/2+1:end)];

stf_t = os * ifft(stf_f, Nup);                        % os 补偿 1/N 缩放
ltf_t = os * ifft(ltf_f, Nup);

% ---------------- 时域拼装 ----------------
stf = repmat(stf_t(1:os*Nsh), 1, 10);                 % 10 x 0.8 us = 320 samples
gi2 = ltf_t(os*Nlt/2 + 1 : os*Nlt);                   % GI2 = 长符号后 64 点
ltf = [gi2, ltf_t, ltf_t];                            % GI2 1.6us + 2 x 3.2us = 320 samples

preamble_waveform = [stf, ltf];
preamble_waveform = preamble_waveform(:).';

% ---------------- 自检 ----------------
expected_len = os * (10*Nsh + 2*Nsh + 2*Nlt);         % 640 @ 40 MHz
assert(numel(preamble_waveform) == expected_len, ...
    sprintf('前导长度应为 %d 点，实际 %d 点', expected_len, numel(preamble_waveform)));
assert(isequal(ltf(1:os*2*Nsh), ltf_t(os*Nlt/2+1:end)), ...
    'GI2 应为长符号的后 64 点');

% ================= 原 preambleone_fixed.m 的绘图================
if plot_enable
    Fs = sample_rate_hz;
    preamble = preamble_waveform;
    G = os;
    rmsv = @(x) sqrt(mean(abs(x).^2));
    papr = @(x) 10*log10(max(abs(x).^2) / mean(abs(x).^2));
    
    % ---- 5. 校验与指标 ----
    fprintf('总样本 %d（%.2f us）| STF %.2f us + LTF %.2f us\n', ...
        numel(preamble), numel(preamble)/Fs*1e6, numel(stf)/Fs*1e6, numel(ltf)/Fs*1e6);
    fprintf('STF 周期 %d 样本（%.2f us）| 平均功率 %.6f | PAPR %.2f dB\n', ...
        32, 32/Fs*1e6, mean(abs(preamble).^2), papr(preamble));
    fprintf('\n         %8s %8s %9s %9s\n', 'RMS', '峰值', '峰值/RMS', 'PAPR/dB');
    fprintf('STF      %8.4f %8.4f %9.3f %9.2f\n', ...
        rmsv(stf), max(abs(stf)), max(abs(stf))/rmsv(stf), papr(stf));
    fprintf('LTF      %8.4f %8.4f %9.3f %9.2f\n', ...
        rmsv(ltf), max(abs(ltf)), max(abs(ltf))/rmsv(ltf), papr(ltf));
    fprintf('峰值差   %8s %8s %9s %7.2f dB\n', '', '', '', ...
        20*log10(max(abs(ltf))/max(abs(stf))));
    
    % ---- 6. 时域：整体 / STF / LTF 分开画 ----
    t  = (0:numel(preamble)-1)/Fs*1e6;
    pk = 1.1*max(abs(preamble));
    
    figure('Color','w','Name','802.11a preamble @ 40 MHz');
    subplot(3,1,1);
    plot(t, abs(preamble), 'b', 'LineWidth', 1.1); hold on;
    plot([0 16], [rmsv(preamble) rmsv(preamble)], 'm--', 'LineWidth', 1);
    plot([8 8], [0 pk], 'r--');
    grid on; xlim([0 16]); ylim([0 pk]);
    xlabel('时间 (\mus)'); ylabel('|x[n]|');
    legend('|x[n]|', 'RMS', 'STF / LTF 分界', 'Location', 'northeast');
    title(sprintf('完整前导：10 个 L-STF + GI2 + 2 个 L-LTF（640 样本 / 16 \\mus）PAPR=%.2f dB', papr(preamble)));
    
    subplot(3,1,2);
    plot((0:numel(stf)-1)/Fs*1e6, abs(stf), 'b', 'LineWidth', 1.1); hold on;
    plot([0 8], [rmsv(stf) rmsv(stf)], 'm--', 'LineWidth', 1);
    for k = 1:9, plot([0.8 0.8]*k, [0 pk], 'k:'); end
    grid on; xlim([0 8]); ylim([0 pk]);
    xlabel('时间 (\mus)'); ylabel('|x[n]|');
    title(sprintf('L-STF：10 个 0.8 \\mus 短符号（周期 32 样本）峰值 %.4f，PAPR %.2f dB', ...
        max(abs(stf)), papr(stf)));
    
    subplot(3,1,3);
    plot((0:numel(ltf)-1)/Fs*1e6, abs(ltf), 'b', 'LineWidth', 1.1); hold on;
    plot([0 8], [rmsv(ltf) rmsv(ltf)], 'm--', 'LineWidth', 1);
    plot([1.6 1.6], [0 pk], 'r--'); plot([4.8 4.8], [0 pk], 'k:');
    grid on; xlim([0 8]); ylim([0 pk]);
    xlabel('时间 (\mus)'); ylabel('|x[n]|');
    title(sprintf('L-LTF：GI2 1.6 \\mus + 2 个 3.2 \\mus 长符号 峰值 %.4f，PAPR %.2f dB', ...
        max(abs(ltf)), papr(ltf)));
    
    % ---- 7. 频域：补零后的线谱 ----
    fM = (-Nup/2:Nup/2-1) * (Fs/Nup)/1e6;
    
    figure('Color','w','Name','802.11a preamble spectrum @ 40 MHz');
    subplot(2,1,1);
    stem(fM, abs(fftshift(fft(stf_t))), 'filled', 'MarkerSize', 4);
    grid on; xlim([-20 20]); xlabel('频率 (MHz)'); ylabel('|X[k]|');
    title('L-STF 频谱：12 根谱线，间隔 4x312.5 kHz = 1.25 MHz，|f|>=10 MHz 为补零区');
    
    subplot(2,1,2);
    stem(fM, abs(fftshift(fft(ltf_t))), 'filled', 'MarkerSize', 4);
    grid on; xlim([-20 20]); xlabel('频率 (MHz)'); ylabel('|X[k]|');
    title('L-LTF 频谱：52 根谱线，间隔 312.5 kHz（±26，DC 置零）');
    
    % ---- 8. PSD：前导自身 vs 长随机载荷 ----
    [Pxx, fp] = pwelch(preamble, hann(256,'periodic'), 128, 512, Fs, 'centered');
    
    rng(0);
    idx_data  = [-26:-22, -20:-8, -6:-1, 1:6, 8:20, 22:26];
    idx_pilot = [-21 -7 7 21];
    nsym = 200;
    nPer = Nup + 32;
    xpay = zeros(1, nsym*nPer);
    for m = 1:nsym
        X = zeros(1, Nfft);
        X(mod(idx_data,  Nfft)+1) = (2*randi([0 1],1,48)-1) + 1j*(2*randi([0 1],1,48)-1);
        X(mod(idx_pilot, Nfft)+1) = [1 1 1 -1] * (1+1j);
        xs = G * ifft([X(1:Nfft/2), zeros(1,Nup-Nfft), X(Nfft/2+1:end)], Nup);
        xpay((m-1)*nPer + (1:nPer)) = [xs(end-31:end), xs];
    end
    [Ppay, fpay] = pwelch(xpay, hann(512,'periodic'), 384, 2048, Fs, 'centered');
    
    d1 = 10*log10(Pxx); d1 = d1 - max(d1(abs(fp) <= 7.5e6));
    d2 = 10*log10(Ppay); d2 = d2 - max(d2(abs(fpay) <= 7.5e6));
    b1 = abs(fp)   <= 7.5e6;
    b2 = abs(fpay) <= 7.5e6;
    fprintf('\n前导 PSD 带内起伏：std %.2f dB，峰谷 %.1f dB\n', std(d1(b1)), max(d1(b1))-min(d1(b1)));
    fprintf('随机载荷 PSD 带内起伏：std %.2f dB，峰谷 %.1f dB\n', std(d2(b2)), max(d2(b2))-min(d2(b2)));
    
    figure('Color','w','Name','PSD: preamble vs random payload');
    subplot(2,1,1);
    plot(fp/1e6, d1, 'k'); grid on; xlim([-20 20]); ylim([-45 5]);
    xlabel('频率 (MHz)'); ylabel('归一化 PSD (dB)');
    title(sprintf('16 \\mus 前导的 PSD：4 段 Welch，带内 std %.1f dB（1.25 MHz 周期的梳齿状起伏）', std(d1(b1))));
    
    subplot(2,1,2);
    plot(fpay/1e6, d2, 'b'); grid on; xlim([-20 20]); ylim([-45 5]);
    xlabel('频率 (MHz)'); ylabel('归一化 PSD (dB)');
    title(sprintf('200 个随机 OFDM 符号的 PSD：带内 std %.1f dB（这才是"平顶"）', std(d2(b2))));
end

% ---------------- 输出 ----------------
if nargout >= 1
    varargout{1} = preamble_waveform;
end
end
