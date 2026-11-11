% verify_framing.m  组帧接口自检：前导 + SIGNAL + DATA 组帧正确性验证。
% 运行方式：matlab -batch "cd(fileparts(mfilename('fullpath'))); verify_framing"

clear; clc;

%% 0. 公共参数
fs = 40e6;
trellis = poly2trellis(7, [133 171]);

%% 1. 模块长度与组帧边界
pre = ieee80211a_preamble(fs);
sig = ieee80211a_signal_field(fs, 130);
assert(isequal(size(pre), [1 640]), '前导应为 1x640 行向量');
assert(isequal(size(sig), [1 160]), 'SIGNAL 应为 1x160 行向量');
fprintf('[1] PREAMBLE %d samples, SIGNAL %d samples\n', numel(pre), numel(sig));

[ppdu, fs_out, bounds] = assemble_ppdu(false);
assert(fs_out == fs, '采样率应为 40e6');
assert(isequal(bounds.preamble, [1 640]), 'preamble 边界错误');
assert(isequal(bounds.signal,   [641 800]), 'signal 边界错误');
n_data = numel(ppdu) - 800;
assert(bounds.data(1) == 801 && bounds.data(2) == numel(ppdu), 'data 边界错误');
fprintf('[2] 组帧: PREAMBLE %d + SIGNAL %d + DATA %d = %d samples (%.2f us)\n', ...
    640, 160, n_data, numel(ppdu), numel(ppdu)/fs*1e6);

% 组装顺序正确：前 640 等于 pre，641:800 等于 sig
assert(max(abs(ppdu(1:640) - pre)) < 1e-12, 'PPDU 前导段与 ieee80211a_preamble 不一致');
assert(max(abs(ppdu(641:800) - sig)) < 1e-12, 'PPDU SIGNAL 段与 ieee80211a_signal_field 不一致');

%% 2. 前导结构：STF 周期 32、GI2 = 长符号后 64 点、T1==T2
stf = pre(1:320);
blk = reshape(stf, 32, 10);
assert(max(abs(blk - blk(:,1)), [], 'all') < 1e-12, 'STF 周期 32 点不成立');

ltf_part = pre(321:640);          % 320 = GI2(64) + T1(128) + T2(128)
t1 = ltf_part(65:192);
t2 = ltf_part(193:320);
assert(max(abs(ltf_part(1:64) - t1(65:128))) < 1e-12, 'GI2 不是长符号后 64 点');
assert(max(abs(t1 - t2)) < 1e-12, 'T1 与 T2 不相等');
fprintf('[3] 前导结构 OK: STF 周期32 / GI2正确 / T1==T2\n');

%% 3. SIGNAL 频谱占用（自然频率顺序，能量只落在 52 个子载波上）
sym = sig(33:160);                % 去 CP，128 点有效符号
F = fft(sym);                     % 自然顺序，子载波 k 位于 mod(k,128)+1
data_idx = [-26:-22, -20:-8, -6:-1, 1:6, 8:20, 22:26];
pilot_idx = [-21, -7, 7, 21];
occ = [data_idx, pilot_idx];
bins = mod(occ, 128) + 1;
energy = abs(F).^2;
outside = energy; outside(bins) = 0;
ratio = sum(outside) / sum(energy);
fprintf('[4] SIGNAL 频谱：带外能量占比 %.3g（应接近 0）\n', ratio);
assert(ratio < 1e-8, 'SIGNAL 子载波映射错误（能量落在 52 个子载波之外）');
assert(abs(F(mod(0,128)+1)) < 1e-9, 'DC 子载波应为零');

%% 4. Viterbi 硬判决译码回 24 bit（验证速率/长度/奇偶/交织/映射整体一致）
% 数据子载波上的 BPSK 硬判决
data_bins = mod(data_idx, 128) + 1;
data_syms = F(data_bins);
rx_bits = double(real(data_syms) < 0);     % +1 -> 0, -1 -> 1

% 标准解交织：interleave 是 out[i(k)] = in[k]，所以 in[k] = out[i(k)]
N_CBPS = 48;
k = 0:N_CBPS-1;
i_perm = (N_CBPS/16) * mod(k, 16) + floor(k/16);
deint_bits = zeros(1, N_CBPS);
deint_bits(k + 1) = rx_bits(i_perm + 1);

decoded = vitdec(deint_bits, trellis, 24, 'trunc', 'hard');
expected = [1 1 0 1, 0, fliplr(double(dec2bin(130,12) - '0')), 1, zeros(1,6)];
% 重新按函数内偶校验计算 parity
sig17 = expected(1:17);
expected(18) = mod(sum(sig17), 2);
assert(isequal(decoded, expected), 'SIGNAL 24 bit 译码结果与期望不符');
fprintf('[5] SIGNAL Viterbi 译码 OK: %s\n', num2str(decoded));

fprintf('\n=== 组帧自检全部通过 ===\n');


