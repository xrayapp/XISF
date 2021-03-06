% [qi, qf] is the fitting range, and should be subset of [min_Q, max_Q]
%
% lb is the lower bound of RMS value, set a positive large value would
% damp the function at high-Q. Set 0 would give lsqcurvefit function full control.
%
% acu is the termination tolerance on the function value, a positive
% scalar. -4 will be converted to 10e-4 when calling optimization routine
%
% Initial RMS value is randomly sampled from Gaussian. For the least-square-fitting
% algorithm, it's very likely that the fitting result is local minimum, not
% global minimum. So the choice of initial rms value determine which local
% minumum area you are looking at. Based on Narten's paper and other
% references, it's reasonable to initialize rms around 0.05 with small
% deviation. So mean = 0.5, std = 0.2 would make sure that all initialized
% rms is around this number.

function [x,xdata,ffitn,intra,x0,SQ] = runfit(qi, qf, acu, mean, std, path_coord, path_sq, ffpath, sname, chk, solver)
clear x; tic;
clearvars -global
% important parameters
lmt = 20;   %max atom-atom distance r above which the pair won't be included into calculation
%%
fid1 = fopen(path_coord,'r');
%load atoms coordinatfion
global atom_type 
a = textscan(fid1,'%s %s %f %f %f');
s = a{1};
t = char(a{1});
if size(t,2) == 1
    for i=1:size(t,1)
        if length(s{i}) == 1
            s(i) = strcat(s(i), {blanks(1)});
        end
    end
    atom_type = char(s);
elseif size(t,2) == 2
    atom_type = t;
end

% extract atom label/number, put it into atom_label
s = a{2};
t = char(a{2});
if size(t,2) == 3 || size(t,2) == 2
    for i=1:size(t,1)
        if length(s{i}) == 3
            s(i) = strcat(s(i), {blanks(1)});
        end
        if length(s{i}) == 2
            s(i) = strcat(s(i), {blanks(2)});
        end
    end
    atom_label = char(s);
elseif size(t,2) == 4
    atom_label = t;
end

fclose(fid1);
pos = [a{3},a{4},a{5}];


global dim
dim = size(pos,1);
pos = pos';

%%%%%%%%%%%%%%%%%%%
global atomff_index
fid2 = fopen(ffpath,'r');
ff = textscan(fid2,'%s %f %f %f %f %f %f %f %f %f %f %f');
atomff_index = char(ff{1});
fclose(fid2);
global formf
formf = [ff{2:12}];
clear a ff s t;
%%%%%%%%%%%%%%%%%%%

%calculate atom-atom distance r, declare r as global to pass it to member
%funtions
%variable size r, should not be a problem for small dim. For extremely large
%dim, there is possible memory leak/overflow. For that case, pre-allocate r.
global r pinfo1 pinfo2
k = 1;
for i = 1:(dim-1)
    for j = (i+1):dim
        temp = sqrt((pos(1,i)-pos(1,j))^2+(pos(2,i)-pos(2,j))^2+(pos(3,i)-pos(3,j))^2);
        if temp < lmt                   %set limit on allowed atom-atom pair, large vaule
            k = k + 1;
        end
    end
end

r = zeros(k-1,1);
k = 1;
for i = 1:(dim-1)
    for j = (i+1):dim
        temp = sqrt((pos(1,i)-pos(1,j))^2+(pos(2,i)-pos(2,j))^2+(pos(3,i)-pos(3,j))^2);
        if temp < lmt                   %set limit on allowed atom-atom pair, large vaule
            r(k) = temp;      %to include all pairs, small value to keep nearest neighbour pairs
            k = k + 1;
        end
    end
end
pinfo1 = char(zeros(length(r), 2));
pinfo2 = char(zeros(length(r), 2));
k = 1;
for i = 1:(dim-1)
    for j = (i+1):dim
        temp = sqrt((pos(1,i)-pos(1,j))^2+(pos(2,i)-pos(2,j))^2+(pos(3,i)-pos(3,j))^2);
        if temp < lmt 
            pinfo1(k,:) = atom_type(i,:);
            pinfo2(k,:) = atom_type(j,:);
            k = k + 1;
        end
    end
end

% atom label pair information for printing
linfo1 = char(zeros(length(r), 4));
linfo2 = char(zeros(length(r), 4));
k = 1;
for i = 1:(dim-1)
    for j = (i+1):dim
        temp = sqrt((pos(1,i)-pos(1,j))^2+(pos(2,i)-pos(2,j))^2+(pos(3,i)-pos(3,j))^2);
        if temp < lmt 
            linfo1(k,:) = atom_label(i,:);
            linfo2(k,:) = atom_label(j,:);
            k = k + 1;
        end
    end
end

%input information, global vars used in MEX file
atom_type = atom_type';
atomff_index = atomff_index';
pinfo1 = pinfo1';
pinfo2 = pinfo2';
formf = formf';

%display setting info
disp(sprintf('Fitting range:\t\t\t\t [%3.1f, %3.1f]', qi, qf));
disp(sprintf('rms population:\t\t\t\t %d', length(r)));
disp(sprintf('Fitting accuracy:\t\t\t 1e%d', acu));
global data_pop;
data_pop = ceil(length(r)/100)*100; %data points needed for TR algorithm
disp(sprintf('Adjusted data population:\t %d', data_pop));


%%
%read data from file
SQ = readsq(path_sq);
xdata = SQ(:,1);
ydata = SQ(:,2);
minq = min(SQ(:,1));
maxq = max(SQ(:,1));

step = SQ(2,1) - SQ(1,1); %increment step of x vector

for i = 1:size(SQ,1)
    if SQ(i,1) - qi < 1.2*step  %find data point near qi, if error returns when running, increase the coefficient for larger search range
        idxi = i;
    elseif SQ(i,1) - qf < 1.2*step
        idxf = i;
    end
end

disp(sprintf('Adjusted Fitting range:\t\t [%3.1f, %3.1f]', SQ(idxi,1), SQ(idxf,1)));
disp(sprintf('\nrms initialization parameter (Random Gaussian Distribution)\n Mean:\t\t\t %g\n Std:\t\t\t %g', mean, std));
p_SQ = SQ(idxi:idxf,:);

%process data for desired range
fit_range = proc_sq(p_SQ);


if solver == 0
    %the main script, call fitting function to fit on select Q range
    [x,x0,Jaco] = lsqfit(fit_range, acu, mean, std);

    %Cov = inv((Jaco.')*Jaco);
    %calculate Covariance matrix
    Cov = Jaco*(Jaco.');
elseif solver == 1
      [x,x0,fval] = lsqfit_ms(fit_range, acu, mean, std);
end


%%
%processing raw data to get finer points
dq = 0.01;
q = minq:dq:maxq;
q = q';
ffit = sqfactor(x,q);
ffit = q.*ffit; %calculate inter-SQ from returned parameter vector x
% interpolate data to match raw x data spacing
ffitn = interp1(q, ffit, xdata, 'spline');
%%
%plot and write data
disp(sprintf('X(end-1) (Amplitude) and X(end) (Y-shift):\t\t %g  %g', x(end-1), x(end)));
intra = SQ(:,2) - ffitn;

if chk == 1
    rslt = [xdata, ydata, ffitn, intra];
    outname = 'SQ.txt';
    outname = strcat(datestr(now, '_HHMM_'), outname);
    outname = strcat(sname, outname);
    dlmwrite(outname, rslt, 'delimiter', '\t', 'precision', 4);

    figure
    plot(q, ffit, xdata,ydata,'-r');
    legend('Fitted Intra-Struct-Factor F(Q)', 'Normalized Experimental SofQ')
    axis([0 23 -2.5 4]);
    figure
    plot(xdata, intra)
    title('Q\times(S(Q) - F(Q)) Intermolecule structure factor')
    axis([0 23 -2.5 4]);

    filename = 'RMS_stat.txt';
    filename = strcat(datestr(now, '_HHMM_'), filename);
    filename = strcat(sname, filename);
    fid = fopen(filename,'w');

    fprintf(fid, 'atom1\tatom2\tr\t\trms\n');
    for i = 1:length(r)
        if r(i) <= 5
        fprintf(fid,'%s\t%s\t%4.2f\t%4.3f\n', linfo1(i,:), linfo2(i,:), r(i), abs(x(i)));
        end
    end
    fclose(fid);
    
    if solver == 0
        fname = 'Covar_stat.txt';
        fname = strcat(datestr(now, '_HHMM_'), fname);
        fname = strcat(sname, fname);
        dlmwrite(fname,full(Cov), 'delimiter', '\t', 'precision', 3);
    end
end
toc;
end
