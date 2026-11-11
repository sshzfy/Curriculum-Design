function [tx_waveform, fs, bounds, params] = ieee802_11a_tx_func(in_byte, rate, upsample, plot_enable)
%ieee802_11a_tx_func  供 example/test.m 调用的 IEEE 802.11a 发送接口。
%
%   tx_11a = ieee802_11a_tx_func(in_byte, rate, upsample)
%   [tx_waveform, fs, bounds, params] = ieee802_11a_tx_func(in_byte, rate, upsample)
%
%   输入：
%       in_byte    - 发送数据字节向量，行/列均可，取值范围 0~255。
%       rate       - 数据速率，可传 6（Mbps）或 6e6（bps）。
%                    当前仅支持 6 Mbps。
%       upsample   - 频域上采样倍数，当前必须为 2。
%       plot_enable- 可选，为 true 时绘制完整 PPDU。
%
%   输出：
%       tx_waveform - 40 MHz 完整 PPDU 复基带波形，N×1 列向量。
%       fs          - 采样率，Hz。
%       bounds      - PPDU 各段边界，来自 assemble_ppdu。
%       params      - 生成本帧的参数结构体。
%
%   本函数保持与 example/test.m 原有三输入调用方式一致，
%   实际发送实现复用现有发送工程函数。

if nargin < 1 || isempty(in_byte)
    in_byte = uint8(1:130);
end
if nargin < 2 || isempty(rate)
    rate = 6e6;
end
if nargin < 3 || isempty(upsample)
    upsample = 2;
end
if nargin < 4 || isempty(plot_enable)
    plot_enable = false;
end

validateattributes(in_byte, {'numeric'}, ...
    {'vector', 'nonempty', 'real', 'finite', 'integer', '>=', 0, '<=', 255});
in_byte = uint8(in_byte(:));

% 当前 DATA 链路仅支持 6 Mbps 和 2 倍频域上采样（40 MSPS）。
rate_is_mbps = abs(rate - 6) < 1e-9;
rate_is_bps  = abs(rate - 6e6) < 1e-6;
if ~(rate_is_mbps || rate_is_bps)
    error('ieee802_11a_tx_func:unsupportedRate', ...
        '仅支持 6 Mbps 数据速率（请传 6 或 6e6）。');
end
if ~isscalar(upsample) || upsample ~= 2
    error('ieee802_11a_tx_func:unsupportedUpsample', ...
        '仅支持 upsample = 2。');
end

repeat_count = 8;
length_bytes = numel(in_byte) * repeat_count + 4; % 数据字节 + CRC-32 FCS
if length_bytes > 4095
    error('ieee802_11a_tx_func:lengthOverflow', ...
        'PSDU 长度 %d 超过 SIGNAL LENGTH 的 12 位上限。', length_bytes);
end

% 复用工程现有的组帧和 DATA 字段实现。
[tx_waveform, fs, bounds] = assemble_ppdu(length_bytes, plot_enable, in_byte, repeat_count);
tx_waveform = tx_waveform(:);   % 转为列向量，便于 test.m 按列拼接。

params = struct( ...
    'data_byte_count', numel(in_byte), ...
    'repeat_count', repeat_count, ...
    'psdu_length_bytes', length_bytes, ...
    'rate_mbps', 6, ...
    'upsample', 2, ...
    'sample_rate_hz', fs);
end
