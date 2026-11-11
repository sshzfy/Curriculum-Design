function [iq, fs, qt, bounds] = tx_ppdu(headroom_db)
%TX_PPDU  最终发送信号：组帧 + 12 bit 量化（×2^12 满量程）
%
%   [iq, fs, qt, bounds] = tx_ppdu()
%   [iq, fs, qt, bounds] = tx_ppdu(headroom_db)
%
%   输出：
%     iq     - 1×2N int16，I/Q 交错 [I1 Q1 I2 Q2 ...]，可直接送 12 bit DAC
%     fs     - 采样率（40e6 Hz）
%     qt     - 量化统计（见 quantize_tx）
%     bounds - 各字段样本边界
%
%   处理链：assemble_ppdu（浮点复基带） -> quantize_tx（×2^12 量化）。

if nargin < 1 || isempty(headroom_db), headroom_db = 0; end

[ppdu, fs, bounds] = assemble_ppdu(false);
[iq, qt] = quantize_tx(ppdu, headroom_db);
end
