function [ppdu, fs, bounds] = assemble_ppdu(length_bytes, plot_enable, payload_bytes, repeat_count)
%assemble_ppdu  在 40 MHz 下组装完整的 IEEE 802.11a PPDU。
%
%   [ppdu, fs, bounds] = assemble_ppdu()
%   [ppdu, fs, bounds] = assemble_ppdu(length_bytes)
%   [ppdu, fs, bounds] = assemble_ppdu(length_bytes, plot_enable)
%
%   本函数复用现有发送模块：
%       tx_preamble      -> L-STF + L-LTF  （640 点）
%       tx_signal_field  -> SIGNAL 字段    （160 点）
%       tx_data          -> DATA 字段      （当前载荷为 55840 点）
%
%   输入：
%       length_bytes - SIGNAL LENGTH 字段（PSDU 字节数）。
%                      默认 1044 = 1040 个数据字节 + 4 字节 CRC-32 FCS，
%                      与 tx_data() 的默认固定载荷一致。
%       plot_enable  - true 时绘制完整 PPDU（默认 false）。
%       payload_bytes- 可选，传给 tx_data 的发送数据字节向量。
%       repeat_count - 可选，传给 tx_data 的数据重复次数。
%
%   输出：
%       ppdu   - 40e6 采样率下的复基带波形，1×N 行向量。
%       fs     - 采样率，Hz。
%       bounds - 各段采样点范围：.preamble、.signal、.data。

if nargin < 1 || isempty(length_bytes)
    length_bytes = 1044;
end
if nargin < 2 || isempty(plot_enable)
    plot_enable = false;
end
if nargin < 3 || isempty(payload_bytes)
    payload_bytes = uint8(1:130);
end
if nargin < 4 || isempty(repeat_count)
    repeat_count = 8;
end

fs = 40e6;

% 生成 PPDU 各段。
preamble = tx_preamble(fs, false);
signal_field = tx_signal_field(fs, length_bytes, false);
[data_field, data_fs] = tx_data(false, payload_bytes, repeat_count);

assert(data_fs == fs, 'tx_data 返回了异常的采样率。');

% 统一为 1×N 行向量。
preamble = preamble(:).';
signal_field = signal_field(:).';
data_field = data_field(:).';

ppdu = [preamble, signal_field, data_field];

% 记录各段边界，供后续同步和调试使用。
bounds = struct( ...
    'preamble', [1, numel(preamble)], ...
    'signal',   [numel(preamble) + 1, numel(preamble) + numel(signal_field)], ...
    'data',     [numel(preamble) + numel(signal_field) + 1, numel(ppdu)]);

fprintf('PPDU：前导=%d 点，SIGNAL=%d 点，DATA=%d 点，总长=%d 点\n', ...
    numel(preamble), numel(signal_field), numel(data_field), numel(ppdu));

if plot_enable
    t_us = (0:numel(ppdu)-1) / fs * 1e6;
    figure('Name', 'IEEE 802.11a PPDU @ 40 MHz', 'Color', 'w');
    plot(t_us, real(ppdu), 'b'); hold on;
    plot(t_us, imag(ppdu), 'r');
    xline([bounds.preamble(2), bounds.signal(2)] / fs * 1e6, '--k', ...
        {'前导结束', 'SIGNAL 结束'});
    xlabel('时间 (\mus)'); ylabel('幅度');
    legend('I 路', 'Q 路', 'Location', 'northeast');
    title('组装后的 802.11a PPDU');
    grid on;
end
end
