function plot_quantized()
%plot_quantized  量化演示：打印统计并保存量化后时域波形图
%
%   cd 到项目目录后运行：plot_quantized
%   输出：fig_ppdu_quantized.png

[ppdu, fs, bounds] = assemble_ppdu(false);
[iq, qt] = quantize_tx(ppdu);

% ---- 打印统计 ----
fprintf('量化统计：peak=%.4f  scale=%.2f (=(2^12-1)/peak)  PAPR=%.2f dB\n', ...
    qt.peak, qt.scale, qt.papr_db);
fprintf('量化统计：nclip=%d  nbit_used=%d  full_scale=2^12=%d\n', ...
    qt.nclip, qt.nbit_used, qt.full_scale);
fprintf('量化误差：I 最大 %.2f LSB, Q 最大 %.2f LSB\n', ...
    max(abs(double(qt.I) - real(ppdu)*qt.scale)), ...
    max(abs(double(qt.Q) - imag(ppdu)*qt.scale)));

% ---- 画量化后时域波形（前 24 us，I/Q 阶梯）----
n_zoom_us = 24;
n_zoom = n_zoom_us * 1e-6 * fs;
n_zoom = min(n_zoom, numel(ppdu));
tzoom = (0:n_zoom-1) / fs * 1e6;

fig = figure('Color','w','Name','量化后发送信号','Position',[50 50 1280 640]);

subplot(2,1,1);
stairs(tzoom, double(qt.I(1:n_zoom)), 'b-', 'LineWidth', 0.8); grid on; hold on;
xline(8, '--k'); xline(16, '--r'); xline(20, '--m');
xlabel('时间 (\mus)'); ylabel('I 量化值');
title(sprintf('量化后发送信号（×2^12，12 bit）：前 24 us I 路阶梯波形'));
xlim([0 n_zoom_us]);

subplot(2,1,2);
stairs(tzoom, double(qt.Q(1:n_zoom)), 'r-', 'LineWidth', 0.8); grid on; hold on;
xline(8, '--k'); xline(16, '--r'); xline(20, '--m');
xlabel('时间 (\mus)'); ylabel('Q 量化值');
title('量化后发送信号：前 24 us Q 路阶梯波形');
xlim([0 n_zoom_us]);

axs = findall(fig, 'Type', 'axes');
for k = 1:numel(axs), axs(k).Toolbar.Visible = 'off'; end
drawnow;
exportgraphics(fig, fullfile(pwd, 'fig_ppdu_quantized.png'), 'Resolution', 150);
fprintf('saved: fig_ppdu_quantized.png\n');
end
