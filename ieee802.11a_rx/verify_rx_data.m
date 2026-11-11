% verify_rx_data.m  数据字段接收自检：理想回环 / 相位旋转 / 每符号线性相移。
% 运行方式：matlab -batch "cd(fileparts(mfilename('fullpath'))); verify_rx_data"

clear; clc;

here = fileparts(which('verify_rx_data'));
addpath(here);
addpath(fullfile(here, '..', 'ieee802.11a_tx'));

expected = repmat(uint8(1:130), 1, 8);
symbol_duration = 160;

%% 1) 理想回环
[wave, fs] = tx_data(false);
[rx1, crc1, m1] = ieee802_11a_rx_data(wave, fs);
assert(crc1 == true, '理想回环 CRC 未通过');
assert(isequal(rx1, expected), '理想回环恢复字节与发送不符');
assert(m1.ber == 0, '理想回环 BER 应为 0');
fprintf('[1] 理想回环 OK：%d bytes，crc=%d，ber=%.3g，evm=%.2f dB\n', ...
    numel(rx1), crc1, m1.ber, m1.evm_db);

%% 2) 固定相位旋转（覆盖均衡）
wave_rot = wave * exp(1j * 0.5);
[rx2, crc2, m2] = ieee802_11a_rx_data(wave_rot, fs);
assert(crc2 == true && isequal(rx2, expected), '固定相位旋转后应仍能完整恢复');
fprintf('[2] 固定相位旋转 OK：crc=%d，ber=%.3g\n', crc2, m2.ber);

%% 3) 每符号线性相移（覆盖导频跟踪）
n_sym = numel(wave) / symbol_duration;
sym_wave = reshape(wave, symbol_duration, n_sym);
drift = exp(1j * 0.01 * (0:n_sym - 1));
wave_drift = reshape(sym_wave .* drift, 1, []);
[rx3, crc3, m3] = ieee802_11a_rx_data(wave_drift, fs);
assert(crc3 == true && isequal(rx3, expected), '每符号线性相移后应仍能完整恢复');
fprintf('[3] 每符号线性相移 OK：crc=%d，ber=%.3g\n', crc3, m3.ber);

fprintf('\n=== 数据域接收自检全部通过 ===\n');
