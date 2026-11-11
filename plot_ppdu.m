function plot_ppdu()
%plot_ppdu  生成组帧后 PPDU 波形图（PNG）
%
%   cd 到项目目录后运行：plot_ppdu
%   输出：
%     fig_ppdu_timedomain.png    完整一帧时域波形（I/Q）
%     fig_ppdu_frame_header.png  单帧头部结构放大（前导 + SIGNAL + 首个 DATA 符号）

[ppdu, fs, bounds] = assemble_ppdu(false);
t_us = (0:numel(ppdu)-1) / fs * 1e6;

%% ---- 图 1：完整一帧时域波形 ----
fig1 = figure('Color','w','Name','组帧后时域波形','Position',[50 50 1280 640]);

subplot(2,1,1);
plot(t_us, real(ppdu), 'b-', 'LineWidth', 0.6); grid on; hold on;
xline(bounds.preamble(2)/fs*1e6, '--r', 'LineWidth', 1.2);
xline(bounds.signal(2)/fs*1e6, '--m', 'LineWidth', 1.2);
xlabel('时间 (\mus)'); ylabel('同相分量 I');
title(sprintf('组帧后完整一帧时域波形（40 MHz，%d samples / %.2f \\mus）', numel(ppdu), t_us(end)));
xlim([0 t_us(end)]);

subplot(2,1,2);
plot(t_us, imag(ppdu), 'r-', 'LineWidth', 0.6); grid on; hold on;
xline(bounds.preamble(2)/fs*1e6, '--r', 'LineWidth', 1.2);
xline(bounds.signal(2)/fs*1e6, '--m', 'LineWidth', 1.2);
xlabel('时间 (\mus)'); ylabel('正交分量 Q');
xlim([0 t_us(end)]);
legend({'正交分量','前导结束 16us','SIGNAL结束 20us'}, 'Location','northeast');

%% ---- 图 2：单帧头部结构放大（前导 + SIGNAL + 首个 DATA 符号）----
n_zoom_us = 24;                       % 0 ~ 24 us
n_zoom = n_zoom_us * 1e-6 * fs;       % 960 samples
n_zoom = min(n_zoom, numel(ppdu));
tzoom = (0:n_zoom-1) / fs * 1e6;

fig2 = figure('Color','w','Name','单帧头部结构','Position',[50 50 1280 640]);

subplot(2,1,1);
plot(tzoom, real(ppdu(1:n_zoom)), 'b-', 'LineWidth', 0.8); grid on; hold on;
xline(8, '--k'); xline(16, '--r'); xline(20, '--m');
text(4,  max(abs(real(ppdu(1:n_zoom))))*0.9, 'STF 8us', 'HorizontalAlignment','center');
text(12, max(abs(real(ppdu(1:n_zoom))))*0.9, 'LTF 8us', 'HorizontalAlignment','center');
text(18, max(abs(real(ppdu(1:n_zoom))))*0.9, 'SIGNAL 4us', 'HorizontalAlignment','center');
text(22, max(abs(real(ppdu(1:n_zoom))))*0.9, 'DATA...', 'HorizontalAlignment','center');
xlabel('时间 (\mus)'); ylabel('同相分量 I');
title('单帧头部结构：前导(STF+LTF) + SIGNAL + 首个 DATA 符号（I 路）');
xlim([0 n_zoom_us]);

subplot(2,1,2);
plot(tzoom, imag(ppdu(1:n_zoom)), 'r-', 'LineWidth', 0.8); grid on; hold on;
xline(8, '--k'); xline(16, '--r'); xline(20, '--m');
text(4,  max(abs(imag(ppdu(1:n_zoom))))*0.9, 'STF 8us', 'HorizontalAlignment','center');
text(12, max(abs(imag(ppdu(1:n_zoom))))*0.9, 'LTF 8us', 'HorizontalAlignment','center');
text(18, max(abs(imag(ppdu(1:n_zoom))))*0.9, 'SIGNAL 4us', 'HorizontalAlignment','center');
text(22, max(abs(imag(ppdu(1:n_zoom))))*0.9, 'DATA...', 'HorizontalAlignment','center');
xlabel('时间 (\mus)'); ylabel('正交分量 Q');
xlim([0 n_zoom_us]);

end
