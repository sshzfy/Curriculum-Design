% debug_rx.m  临时调试：定位 RX 恢复比特与 TX 期望比特的分歧点
clear; clc;
addpath(fullfile(pwd,'ieee802.11a_rx'));
addpath(fullfile(pwd,'ieee802.11a_tx'));

[wave, fs] = tx_data(false);

% ---- 期望比特（用已知 FCS 0x3640D343）----
data_bits = double(reshape(int2bit(repmat(uint8(1:130),1,8), 8, false), 1, []));
fcs_bits = double(bitget(uint32(hex2dec('3640D343')), 1:32));
padded_bits = [zeros(1,16), data_bits, fcs_bits, zeros(1,6), zeros(1,2)];
fprintf('padded len=%d\n', numel(padded_bits));

scrambler_seed = [1 0 1 1 1 0 1];
scrambling_sequence = zeros(1, numel(padded_bits));
scrambler_state = scrambler_seed;
for bit_index = 1:numel(padded_bits)
    scrambling_sequence(bit_index) = xor(scrambler_state(1), scrambler_state(4));
    scrambler_state = [scrambler_state(2:end), scrambling_sequence(bit_index)];
end
scrambled_bits = double(xor(padded_bits, scrambling_sequence));

% ---- RX 链路（内联）----
oversampled_fft_size = 128; cyclic_prefix_length = 32; symbol_duration = 160;
data_subcarrier_indices = [-26:-22, -20:-8, -6:-1, 1:6, 8:20, 22:26];
pilot_subcarrier_indices = [-21, -7, 7, 21];
pilot_symbols = [1 1 1 -1];
trellis = poly2trellis(7,[133 171]);

wave = wave(:).';
data_symbol_count = numel(wave)/symbol_duration;
symbols_with_cp = reshape(wave, symbol_duration, data_symbol_count);
symbols = symbols_with_cp(33:end, :);
freq_symbols = fft(symbols, 128, 1);
data_bins = mod(data_subcarrier_indices,128)+1;
pilot_bins = mod(pilot_subcarrier_indices,128)+1;
Y_data = freq_symbols(data_bins,:);
Y_pilot = freq_symbols(pilot_bins,:);
X_pilot = pilot_symbols(:);
H_p_all = Y_pilot ./ X_pilot;
H_fixed = mean(H_p_all,2);
H_data = interp1(pilot_subcarrier_indices, H_fixed.', data_subcarrier_indices, 'linear','extrap').';
Y_eq = Y_data ./ H_data;
fprintf('Y_data 样例: %s\n', num2str(round(Y_data(1:6,1).')));
fprintf('H_fixed: %s\n', num2str(round(H_fixed.')));
Y_out = complex(zeros(size(Y_eq)));
for sym=1:data_symbol_count
    ratio = H_p_all(:,sym) .* conj(H_fixed);
    phi = angle(mean(ratio));
    Y_out(:,sym) = Y_eq(:,sym)*exp(-1j*phi);
end
fprintf('Y_out 样例(real): %s\n', num2str(round(real(Y_out(1:6,1).'))));
rx_bits = double(real(Y_out) < 0);
k = 0:47;
i_perm = 3*mod(k,16) + floor(k/16);
deint_bits = zeros(size(rx_bits));
deint_bits(k+1,:) = rx_bits(i_perm+1,:);
coded_bits_rx = reshape(deint_bits,1,[]);
decoded_bits = vitdec(coded_bits_rx, trellis, 48, 'trunc', 'hard');
d = double(decoded_bits(:).');
fprintf('decoded len=%d scrambled len=%d\n', numel(d), numel(scrambled_bits));
mm = find(d ~= scrambled_bits);
fprintf('total mismatches=%d\n', numel(mm));
if ~isempty(mm), fprintf('first mismatch idx=%d\n', mm(1)); end
fprintf('decoded[1:24] = %s\n', num2str(d(1:24)));
fprintf('scrambl[1:24] = %s\n', num2str(scrambled_bits(1:24)));
