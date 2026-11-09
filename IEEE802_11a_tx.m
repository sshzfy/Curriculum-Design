clear;
clc;
close all;

%% 数据域生成
data_rate_mbps = 6;            % 6 Mbps：BPSK，编码率 1/2
bits_per_subcarrier = 1;       % BPSK：每个子载波承载 1 bit
coded_bits_per_symbol = 48;    % 每个 OFDM 符号的编码位数
data_bits_per_symbol = 24;     % 每个 OFDM 符号的数据位数
code_rate = 1/2;               % 编码效率
bits_per_byte = 8;
repeat_count = 8;              % 重复次数

assert(data_bits_per_symbol == coded_bits_per_symbol * code_rate, ...
    '每个 OFDM 符号的数据位数必须与编码率一致。');

% 原始数据生成
payload_bytes = uint8(1:130);                                       % 原始数据
repeated_payload_bytes = repmat(payload_bytes, 1, repeat_count);    % 重复发送

% 按 IEEE 802.11 位序排列：每个字节最低有效位先发送。
payload_bit_matrix = de2bi(repeated_payload_bytes, bits_per_byte, 'right-msb');
payload_bits = reshape(payload_bit_matrix.', 1, []);

% SERVICE、TAIL 和 OFDM 符号补零
service_bits = zeros(1, 16);
tail_bits = zeros(1, 6);
bits_before_padding = [service_bits, payload_bits, tail_bits];

ofdm_symbol_count = ceil(numel(bits_before_padding) / data_bits_per_symbol);    % OFDM 符号数
padding_bit_count = ofdm_symbol_count * data_bits_per_symbol - ...
    numel(bits_before_padding);                                                 % 补零位数
padded_bits = [bits_before_padding, zeros(1, padding_bit_count)];               % 补零后的 bit 流

% 长度统计
fprintf('原始数据：%d bytes (%d bits)\n', ...
    numel(payload_bytes), numel(payload_bytes) * bits_per_byte);
fprintf('重复后数据：%d bytes (%d bits)\n', ...
    numel(repeated_payload_bytes), numel(payload_bits));
fprintf('添加 SERVICE 和 TAIL 后：%d bits\n', numel(bits_before_padding));
fprintf('OFDM 符号数：%d\n', ofdm_symbol_count);
fprintf('补零：%d bits\n', padding_bit_count);
fprintf('最终 bit 流：%d bits\n', numel(padded_bits));

%% 加扰
scrambler_seed = [1 0 1 1 1 0 1];

scrambling_sequence = zeros(size(padded_bits));    % 加扰序列
scrambler_state = scrambler_seed;                  % 加扰状态

% 加扰过程：
%             ————————————————>xor———————————————
%            |                 ^                 |
%            |                 |                 v
%     输出<——x7 <- x6 <- x5 <- x4 <- x3 <- x2 <- x1 <——————— 输入数据
% x7 和 x4 位异或，作为反馈送入 x1，其他位左移一位。
for bit_index = 1:numel(padded_bits)
    
    scrambling_sequence(bit_index) = xor( ...
        scrambler_state(1), scrambler_state(4));    % 加扰序列
    scrambler_state = [scrambler_state(2:end), ...
        scrambling_sequence(bit_index)];            % 更新加扰状态
end

scrambled_bits = double(xor(padded_bits, scrambling_sequence));    % 加扰后的 bit 流

% 处理 TAIL 位
tail_start_index = numel(service_bits) + numel(payload_bits) + 1;             % TAIL 位起始索引
tail_indices = tail_start_index:(tail_start_index + numel(tail_bits) - 1);    % TAIL 位索引
scrambled_bits(tail_indices) = 0;                                             % 恢复 TAIL 位为 0

fprintf('加扰初始状态：%s\n', sprintf('%d', scrambler_seed));
fprintf('加扰后 bit 流：%d bits\n', numel(scrambled_bits));
