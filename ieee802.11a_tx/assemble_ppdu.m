function [ppdu_waveform, sample_rate_hz, field_boundaries] = assemble_ppdu(plot_enable)
%assemble_ppdu  组帧接口：前导 + SIGNAL + DATA。
%
%   [ppdu, fs, bounds] = assemble_ppdu(plot_enable)
%
%   前导序列和 SIGNAL 字段由其他同学分别实现，接口为：
%     preamble_waveform = ieee80211a_preamble(sample_rate_hz)
%     signal_waveform   = ieee80211a_signal_field(sample_rate_hz, length_bytes)
%
%   本文件只负责调用接口、归一化成行向量、拼帧和绘图。
%
%   输入 plot_enable：true 时绘制完整 PPDU 包络和功率谱（默认 true）。
%   输出：
%     ppdu   - 完整 PPDU 复基带波形（行向量，40 MHz）
%     fs     - 采样率（Hz）
%     bounds - 各字段样本边界（struct：preamble / signal / data）
if nargin < 1 || isempty(plot_enable)
    plot_enable = true;
end

%% 1) DATA 字段（本仓库已实现）
[data_field_waveform, sample_rate_hz] = ieee802_11a_data(false);
data_field_waveform = data_field_waveform(:).';

%% 2) 前导序列（接口，由其他同学实现）
preamble_waveform = ieee80211a_preamble(sample_rate_hz);
preamble_waveform = preamble_waveform(:).';

%% 3) SIGNAL 字段（接口，由其他同学实现）
% length_bytes：SIGNAL LENGTH 字段中的 PSDU 字节数，当前为 130。
signal_waveform = ieee80211a_signal_field(sample_rate_hz, 130);
signal_waveform = signal_waveform(:).';

%% 4) 组帧：前导 + SIGNAL + DATA
ppdu_waveform = [preamble_waveform, signal_waveform, data_field_waveform];

n_preamble = numel(preamble_waveform);
n_signal = numel(signal_waveform);
n_data = numel(data_field_waveform);
field_boundaries = struct( ...
    'preamble', [1, n_preamble], ...
    'signal', n_preamble + [1, n_signal], ...
    'data', n_preamble + n_signal + [1, n_data]);

fprintf('组帧完成：PREAMBLE %d + SIGNAL %d + DATA %d = %d samples (%.2f us)\n', ...
    n_preamble, n_signal, n_data, numel(ppdu_waveform), ...
    numel(ppdu_waveform) / sample_rate_hz * 1e6);

%% 5) 绘图
if plot_enable
    ppdu_time_us = (0:numel(ppdu_waveform)-1) / sample_rate_hz * 1e6;
    boundary_times_us = [field_boundaries.signal(1), ...
        field_boundaries.data(1)] / sample_rate_hz * 1e6;
    boundary_labels = {'前导结束', 'SIGNAL 结束'};
    envelope = abs(ppdu_waveform);

    figure('Name', '完整 PPDU 时域包络');
    plot(ppdu_time_us, envelope);
    hold on;
    for idx = 1:numel(boundary_times_us)
        xline(boundary_times_us(idx), '--k');
        text(boundary_times_us(idx), max(envelope) * 0.95, boundary_labels{idx}, ...
            'Rotation', 90, 'HorizontalAlignment', 'left', ...
            'VerticalAlignment', 'top');
    end
    grid on;
    xlabel('时间 (\mus)');
    ylabel('幅度');
    title('完整 IEEE 802.11a PPDU 时域包络');

    figure('Name', '完整 PPDU 功率谱密度');
    [pxx, f] = pwelch(ppdu_waveform(:), hann(4096, 'periodic'), 2048, 8192, ...
        sample_rate_hz, 'centered', 'psd');
    plot(f / 1e6, 10 * log10(max(pxx, realmin('double'))));
    grid on;
    xlabel('频率 (MHz)');
    ylabel('功率谱密度 (dB/Hz)');
    title('完整 IEEE 802.11a PPDU 功率谱密度');
end
end
