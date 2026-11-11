function preamble_waveform = ieee80211a_preamble(sample_rate_hz)
%ieee80211a_preamble  前导序列接口（L-STF + L-LTF），40 MHz 复基带。
%
%   preamble_waveform = ieee80211a_preamble(sample_rate_hz)
%
%   输入 sample_rate_hz：采样率（Hz，本设计为 40e6）。
%   输出 preamble_waveform：前导序列复基带波形，1×N 行向量。
%
%   实现依据 preambleone.m：64 点频域序列（自然频率顺序）→ 频域中间补零
%   到 128 点 → 128 点 IFFT（×2 补偿 1/N 归一化）→ 时域拼装。
%     短训练序列 STS：10 个短符号，每个 0.8 us（32 samples），共 320 samples；
%     长训练序列 LTF：GI2 1.6 us（64 samples）+ 2 个 3.2 us 长符号（各 128
%                     samples），共 320 samples；
%     前导总长 = STS + LTF = 640 samples（16 us）。
%
%   频率映射、补零方式与 DATA 字段（IEEE802_11a_tx）完全一致，均为
%   mod(k,64)+1 的自然顺序，保证 PPDU 拼接后各字段频谱对齐。

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
         1+1j, -1-1j, 1+1j, -1-1j, -1-1j, 1+1j] * sqrt(13/6);   % 与 LTF 等功率
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

% ---------------- 频域补零上采样（与 DATA 字段一致）----------------
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
end
