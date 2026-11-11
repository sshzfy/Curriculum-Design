clearvars -except times;close all;warning off;

% 添加发送工程路径，使 ieee802_11a_tx_func 及其依赖函数可见。
this_dir = fileparts(mfilename('fullpath'));
root_dir = fileparts(this_dir);
addpath(fullfile(root_dir, 'ieee802.11a_tx'));
addpath(this_dir);

pluto_init.ip = '192.168.2.1';
pluto_init.rx_freq = 2000e6;
pluto_init.rx_samp = 40e6;
pluto_init.rx_bw = 20e6;
pluto_init.rx_gain_mode = 'manual';
pluto_init.tx_freq = 200.00e6; %%  产生频偏
pluto_init.tx_samp = 40e6;
pluto_init.tx_bw = 20e6;


% 测试数据，后续可替换为本组自己的发送字节向量。
in_byte = uint8(1:130).';
rate = 6e6;                 % 6 Mbps；也可传 6。
upsample = 2;               % 2 倍频域上采样，输出 40 MSPS。
tx_11a = ieee802_11a_tx_func(in_byte, rate, upsample);
txdata=repmat([zeros(size(tx_11a));tx_11a],6,1); %% 空一帧，发一帧，共6帧
[input_content, ~, s] = pluto_config(pluto_init, txdata); %%% 

i = 0;
while(i < 8)   % 多传几次，等待发送数据稳定
    stepImpl(s, input_content);
    i = i + 1;
end

% 接收链路留到下一阶段实现。
% I = output_content{1};
% Q = output_content{2};
% Rx = I + 1i*Q;
% [data_byte_recv, sim_options] = ieee802_11a_rx_func(Rx(:,1), upsample);

releaseImpl(s);