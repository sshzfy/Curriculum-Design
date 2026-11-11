function [iq, qt] = quantize_tx(tx, headroom_db)
%QUANTIZE_TX  最终发送信号量化：浮点复基带 -> 12 bit 定点（满量程 ×2^12）
%
%   [iq, qt] = quantize_tx(tx)                 峰值满量程（0 dB 余量）
%   [iq, qt] = quantize_tx(tx, headroom_db)    峰值留 headroom_db dB 余量
%
%   tx : 1×N 复行向量（浮点，40 MHz 复基带）
%   iq : 1×2N int16，I/Q 交错排列 [I1 Q1 I2 Q2 ...]
%   qt : 统计结构
%        .I .Q       拆开的 int16 行向量
%        .iq         同 iq
%        .scale      缩放因子（浮点 -> 整数）
%        .peak .rms .papr_db
%        .nclip      削波点数（正常应为 0）
%        .nbit_used  实际占用的位宽
%        .full_scale 满量程
%
%   满量程 = 2^12 = 4096（12 bit DAC）。峰值归一化到 2^12-1 = 4095，
%   避免 OFDM 高 PAPR 直接乘 2^12 造成峰值溢出/削波。

FULL = 2^12;                                   % 4096
if nargin < 2 || isempty(headroom_db), headroom_db = 0; end

tx = tx(:).';
peak = max(abs(tx));
if peak <= 0, peak = 1; end

scale = (FULL - 1) / peak / 10^(headroom_db/20);

I = round(real(tx) * scale);
Q = round(imag(tx) * scale);

nclip = sum(abs(I) > FULL-1) + sum(abs(Q) > FULL-1);
I = max(min(I, FULL-1), -(FULL-1));
Q = max(min(Q, FULL-1), -(FULL-1));

I = int16(I);
Q = int16(Q);
iq = int16(reshape([double(I); double(Q)], 1, []));   % 交错

qt.I = I;
qt.Q = Q;
qt.iq = iq;
qt.scale = scale;
qt.peak = peak;
qt.rms = sqrt(mean(abs(tx).^2));
qt.papr_db = 20*log10(qt.peak / qt.rms);
qt.nclip = nclip;
qt.nbit_used = ceil(log2(max(abs([double(I) double(Q)])) + 1));   % 幅度位宽（不含符号位）
qt.full_scale = FULL;

assert(numel(iq) == 2*numel(tx), '量化后长度应为 2N');
end


