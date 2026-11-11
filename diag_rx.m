cd('D:\Code\Matlab\Principles of  Commu');
addpath('ieee802.11a_tx'); addpath('ieee802.11a_rx');
[wave, fs] = tx_data(false);
N = 128; cp=32; symdur=N+cp;
rxw = wave(:).'; nsym = numel(rxw)/symdur;
sym = reshape(rxw,symdur,nsym); sym = sym(cp+1:end,:);
F = fft(sym,N,1);
data_idx = [-26:-22,-20:-8,-6:-1,1:6,8:20,22:26];
pilot_idx = [-21,-7,7,21];
data_bins = mod(data_idx,N)+1; pilot_bins = mod(pilot_idx,N)+1;
Yd = F(data_bins,:); Yp = F(pilot_bins,:); Xp = [1;1;1;-1];
Hp = Yp./Xp;
disp('size(Hp):'); disp(size(Hp));
for c = [1 2 3 100 200 349]
    disp(['Hp(:, ' num2str(c) '):']); disp(Hp(:,c).');
end
disp(['min real(Hp): ' num2str(min(real(Hp(:))))]);
disp(['max real(Hp): ' num2str(max(real(Hp(:))))]);
disp(['count Hp ~= 0: ' num2str(sum(abs(Hp(:)) > 1e-6)) ' / ' num2str(numel(Hp))]);
disp(['Hf = mean(Hp,2):']); disp(mean(Hp,2).');
