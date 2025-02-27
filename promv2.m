function [f,f_ko,v,v_ko,status1,lostxns,probtfgene] =  promv2(model,expression,expressionid,regulator,targets,litevidence,prob_prior,subsets,v11,v12,KAPPA,DATATHRESHVAL,probtfgene,sizeflag)
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%
% The PROM algorithm predicts the growth phenotype and the flux response
% after transcriptional perturbation, given a metabolic and regulatory
% network.
% INPUTS
% Model is the metabolic model obtained from COBRA toolbox through readcbmodel command
%
% Gene expression data - rows - genes,columns - conditions; no need to normalize or impute
%
% Expressionid - an array of identifiers for each row/gene should be included
%
% regulatory network - format - cell array of regulators and matching target genes
% example   Regulator = {'RegA'; 'RegB' ; 'RegC'};  Targets =
% {'GeneA';'GeneB';'GeneC'}
% note that the names or identifiers used in the regulatory data should
% match the names/ids given for gene expression data
%
%v11,v12 are obtained either from fastfva or fluxvariability command in
%cobra
% >> [v11,v12] = fastFVA(model);
%
%  sizeflag tells PROM if the regulatory network is large. it is 0 for large networks
%  and 1 for small networks ( less than 1000 interactions)
%
%OPTIONAL PARAMS
%
%- litevidence & prob_prior -> these should have the same length
%as the regulator/target arrays;
% high confidence interactions (not necessarily based on literature) should be flagged as one in litevidence
%array and the rest should be set as 0.
%
% Prob_prior should be set values between 0 and 1 for those interactions with litevidence. ( other values in
%the array would be ignored)
%
% KAPPA - determines strength of regulatory constraints - default value 1
% works for most systems
%
% subsets of tfs for which prom should be run ; default - for all tfs
%
% OUTPUT - the algorithm gives the growth rate (f) and flux response (v) after knock out of all
% the regulators in the regulatory model; status is the glpk solver status
%
% the status should be 5 for glpk; if its not then check solver error log
%
% lostxns gives the interactions that could not be quantified based on the
% threshold set for binarization
% the program would shoot a warning if the threshold chosen is bad. The
% default value (0.2 - 0.4) should work for most cases
%
% probtfgene gives the probabilities estimated for each interaction
%
%
% EXAMPLE
% load mtbpromdata
% f_ko = promv2(model,expression,expressionid,regulator,targets);
%[v11,v12] = fastFVA(model);
%[f,f_ko,v,v_ko,status1,lostxns,probtfgene] =  promv2(model,expression,expressionid,regulator,targets,[],[],[],v11,v12,[],[],[]);
% this is the tuberculosis model used in the PNAS paper
%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% INPUT HANDLING
%===========================================================
if nargin == 5, litevidence = [];prob_prior = [];subsets = [];
elseif (nargin < 5) || (nargin == 6),
    error('Incorrect number of input arguments to %s',mfilename)
end
%===========================================================
%SOME BASIC INITIALIZATION
%===========================================================
disp('initializing data')
regulated = targets;
[tfnames,b,m] = unique(regulator);
weights = model.c; stoic  = model.S; S = model.S; ctype = repmat('S',size(model.b));lbff = model.lb; ubff = model.ub;dxdt = model.b; param.msglev = 1;
lbff(lbff==ubff) = ubff(lbff == ubff) - 1E-6;

if (~exist('KAPPA','var')) || (isempty(KAPPA))         
    KAPPA = 1;
end

% for doing flux variability
%if (length(regulator) < 1000) % for small networks its faster to compute min/max for the subset thats regulated than the entire metab model
%    sizeflag = 1;
%else
%    sizeflag = 0;
%end

if (~exist('sizeflag','var')) || (isempty(sizeflag))
   
        if (length(regulator) < 1000) % for small networks its faster to compute min/max for the subset thats regulated than the entire metab model
            sizeflag = 1;
        else
            sizeflag = 0;
        end
   
end


if ~sizeflag
    if (~exist('v11','var')) || (isempty(v11))  
        [v11,v12] = fluxvariability(model); 
        %[v11,v12] = fastFVA(model); 
    end
end

if (~exist('DATATHRESHVAL','var')) || (isempty(DATATHRESHVAL))
DATATHRESHVAL = 0.33; % KAPPA = 100;
end

%fprintf('params used - KAPPA: %d and DATATHRESH: %1.3f \n', KAPPA,DATATHRESHVAL)
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
[u,v] = find(model.rxnGeneMat);
% u - reaction; v - genes
% finding rxn position
rxnpos = u;
genelist = v;
clear u v

% i need to find the reactions that each gene has influence on
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
bnumsinexpsn = expressionid;
litevidence = logical(litevidence);
if ~isempty(subsets)
    bnumstobekoed = subsets;
    regulated = targets(ismember(regulator,subsets));
    regulator = regulator(ismember(regulator,subsets));
    
    
else
    bnumstobekoed= tfnames;   % bnumstobekoed -  gives the geneids of the genes to be knocked out - by default it knocksout all the tfs in the model one by one
end
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
scou = 1;
%% new additions

lbg = model.lb; ubg = model.ub;
lbg(lbg==ubg) = ubg(lbg == ubg) - 1E-6;
a1 = [S,zeros(size(S,1),length(ubg)),zeros(size(S,1),length(ubg))];
a2 = sparse([eye(length(ubg)), eye(length(ubg)),zeros(length(ubg))]);
a3 = sparse([eye(length(ubg)), zeros(length(ubg)),-eye(length(ubg))]);
A = [a1;a2;a3];
weights11 = [weights;zeros(2*length(lbg),1)];
weights00 = [weights;zeros(2*length(lbg),1)];
lb11 = [-1000*ones(length(lbg),1);zeros(length(lbg),1);zeros(length(lbg),1)];
ub11 = [1000*ones(length(lbg),1);zeros(length(lbg),1);zeros(length(lbg),1)];
lb11(lb11==ub11) = ub11(lb11 == ub11) - 1E-6;
dxdt0 = [zeros(size(S,1),1);lbg;ubg];
ctype1 = [repmat('S',size(S,1),1);repmat('L',size(lbg,1),1);repmat('U',size(lbg,1),1)];
[v0,f0] = glpk(-weights11,A,dxdt0,lb11,ub11,ctype1,[],[],param);

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Find Probabilities using a Global Threshold
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
tic
lost_xn = false(size(regulated));
remove_interactions1 = false(size(regulated));
disp('finding probabilities')
cou = 1;cou1 = 1;cou3 = 1;
%data= knnimpute(datbackup);
data = expression;
data = knnimpute(data);
data = quantilenorm(data);  %its already normalized..
data1 = data;
%kappavals = [0,0.0001,0.001,0.05,0.1,0.25,0.33,0.5,0.75,1];
%datathreshvals = [0,0.01,0.05,0.1,0.2,0.25,0.33,0.4,0.5,0.75,1];
%datathresh = quantile(data(:),datathreshvals(scou));
%if isempty(datathresh)
%    datathresh = quantile(data(:),DATATHRESHVAL);
%end
datathresh = quantile(data(:),DATATHRESHVAL);
if datathresh < 0,
    data(data>=datathresh) = 1;
    data(data < datathresh) = 0;
else
    data(data < datathresh) = 0;
    data(data>=datathresh) = 1;
end
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
if (~exist('probtfgene','var')) || (isempty(probtfgene))  
    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    try probtfgene = ones(size(regulated)); catch M1, probtfgene = 1; end
    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    for  i = 1:length(regulated)
        k = find(ismember(bnumsinexpsn,regulated(i)));
        l = find(ismember(bnumsinexpsn,regulator(i)));
        if ~isempty(k) & ~isempty(l)
            te = data1(k,:);
            te1 = data1(l,:);
            
            tec = data(k,:);
            
            tec1 = data(l,:);
            
            cou1 = cou1 + 1;
            try kstest2(te(tec1 == 1),te(tec1== 0));
                
                if  (kstest2(te(tec1 == 1),te(tec1== 0)) == 1),
                    
                    prob1 = sum(tec(tec1 == 0))/length(tec(tec1==0));
                    probtfgene(i) = prob1;
                    cou = cou + 1;
                    %   this formula also gives the same answer  - (sum(~tec1(tec == 1))/length(tec1(tec==1))) * (sum(tec)/sum(~tec1))
                    
                else
                    
                    probtfgene(i) = 1;  % no effect
                    
                end
                
            catch ERRLG    % cant be estimated from microarray ; if it has strong evidence, i might consider setting this to zero later on
                probtfgene(i) = 1;
                lost_xn(i) = 1;
                
            end
        else
            probtfgene(i) = 1;
            lost_xn(i) = 1;
        end
    end
    
    probtfgene = probtfgene(:);
    
    toc
%    if (sum(lost_xn) > 0.75*length(probtfgene))   % check if there is problem with binarizartion.. usually there ll be some interactions that'd be missed, but if most of it (like >75% ) are...
%        % missed then its time to change the threshold
%        datathreshflag = 1;
%        disp('change binarization threshold')
%    else
        datathreshflag = 0;
%    end
    
    if ~isempty(litevidence)
        probtfgene(litevidence) = prob_prior(litevidence);  % u could set those interactions that u think have strong literature evidence to have predefined
    end                                                            % probabilities
    
    toc
else
    disp('using presupplied probabilities')
    datathreshflag = 0;
end

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%  run PROM for each knockout
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
disp('running PROM')
count = 1; thresh = 10^(-6); mthresh = 10^(-3);
allgenes = [model.genes;tfnames];
[ir,posgenelist] = ismember(regulated,model.genes);
lbf = lbff; ubf = ubff;
[v,f_wt] = glpk(-weights,stoic,dxdt,lbf,ubf,ctype);
f_wt = -f_wt;
% flooring small values to zero
v(abs(v) < thresh) = 0;
% kapavals = [0,0.0001,0.001,0.05,0.1,0.25,0.33,0.5,1,5,10];
%kappa = kapavals(scou);
kappa = KAPPA;
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
hw = waitbar(0);
% knock out the genes

vm = zeros(size(v));

% bnumstobekoed = [tfs_that_are_off;tf_that u want to knockout];
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%5
if ~sizeflag
    % disp('running fast fva for the entire network'); tic;
    %         [v11,v12] = fastFVA(model); toc;
    v11(abs(v11) < thresh) = 0;
    v12(abs(v12) < thresh) = 0;
end
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

for ci = 1:length(bnumstobekoed)
    
    disp(ci)
    
    lbg = lbf; ubg = ubf;
    lb11 = [-1000*ones(length(lbg),1);zeros(length(lbg),1);zeros(length(lbg),1)];
    ub11 = [1000*ones(length(lbg),1);zeros(length(lbg),1);zeros(length(lbg),1)];
    % check if its a metabolic or regulatory gene or both
    
    if any(strcmpi(model.genes,bnumstobekoed(ci)))
        temppos = rxnpos(genelist == find(strcmp(model.genes,bnumstobekoed(ci))));
        for jj = 1:length(temppos)
            if model.rev(temppos(jj))
                lbg(temppos) = -thresh;
                ubg(temppos) = thresh;
            else
                lbg(temppos) = -thresh;
            end
        end
        
    end
    
    [v1,fk(ci)]  = glpk(-weights,S,dxdt,lbg,ubg,ctype);
    % flooring small values to zero
    v1(abs(v1) < thresh) = 0;
    
    if any(ismember(tfnames,bnumstobekoed(ci))),
        
        
        tfstate = logical(zeros(size(tfnames)));
        tfstate(find(ismember(tfnames,bnumstobekoed(ci)))) = 1;
        k = find(ismember(regulator,tfnames(tfstate)));
        %    k(tempgeneprobs == 1) = '';
        tempgene = regulated(k);
        tempgeneprobs = probtfgene(k);
        tempgenepos = posgenelist(k);
        temprxnpos = rxnpos(ismember(genelist,tempgenepos));
        %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
        % this section is for gene-protein-reaction relationship
        x = true(size(model.genes));
        [isInModel,geneInd] = ismember(tempgene,model.genes);
        x(geneInd) = false;
        constrainRxn = false(length(temprxnpos),1);
        % Figure out if any of the reaction states is changed
        for j = 1:length(temprxnpos)
            if (~eval(model.rules{temprxnpos(j)}))
                constrainRxn(j) = true;
            end
        end
        % Constrain flux through the reactions associated with these genes
        
        %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
        tempgeneprobs(tempgenepos == 0)  = '';
        tempgene(tempgenepos == 0) = '';
        tempgenepos(tempgenepos == 0)  = '';
        
        % temprxnpos has the rxns that are going to  be affected by this tf
        % krxnpos are the rxns that will be affected by this target gene alone..
        % we loop around all the genes..
        
        
        
        for l = 1:length(tempgenepos)
            if ~isnan(tempgeneprobs(l))
                krxnpos = ismember(temprxnpos,rxnpos(ismember(genelist,tempgenepos(l))));
                for m = 1:length(temprxnpos)
                    if krxnpos(m)
                        
                        if constrainRxn(m)
                            if (tempgeneprobs(l) < 1)    % if its 1 no use in changing the bounds - might as well save time
                                if (tempgeneprobs(l) ~= 0)   % if its zero no point in estimating vm again - saves time.. but cant include in the above statement coz u have to change the bounds
                                    %if v(temprxnpos(m))
                                    if ~vm(temprxnpos(m))    % done to save time - if estimated already use it
                                        if sizeflag
                                            weights1 = weights; lbv = lbf; ubv = ubf;
                                            grwthpos = find(weights == 1);
                                            lbv(grwthpos) = v(grwthpos);
                                            weights1(temprxnpos(m)) = -1;
                                            [v11,fva1]  = glpk(-weights1,S,dxdt,lbv,ubv,ctype);
                                            weights1(temprxnpos(m)) = 1;
                                            [v12,fva2]  = glpk(-weights1,S,dxdt,lbv,ubv,ctype);
                                            
                                        end
                                        
                                        if  v(temprxnpos(m)) < 0
                                            vm(temprxnpos(m)) = min([v11(temprxnpos(m)),v12(temprxnpos(m)),v(temprxnpos(m))]);
                                        elseif v(temprxnpos(m)) > 0
                                            vm(temprxnpos(m)) = max([v11(temprxnpos(m)),v12(temprxnpos(m)),v(temprxnpos(m))]);
                                        else
                                            vm(temprxnpos(m)) = max([abs(v11(temprxnpos(m))),abs(v12(temprxnpos(m))),abs(v(temprxnpos(m)))]);
                                        end
                                        
                                        
                                    end
                                    %end
                                end
                                
                                
                                xx =    vm(temprxnpos(m))*tempgeneprobs(l); % flux times probability
                                
                                if  v(temprxnpos(m)) < 0
                                    
                                    tem = max([lbf(temprxnpos(m)),xx,lbg(temprxnpos(m))]);  %make sure we arent violating the original bounds; also get the lowest value if there were multiple modifications for the rxn
                                    lbg(temprxnpos(m)) = min([tem,-thresh]);   % prevents the solver from crashing
                                    ub11(1*length(ubg) + temprxnpos(m)) = 1000;
                                    weights11(1*length(ubg) + temprxnpos(m)) = (-1*kappa/abs(vm(temprxnpos(m))))*abs(f0);   % v0 f0 are the wild type values..
                                    vv = max([abs(vm(temprxnpos(m))),mthresh]);
                                    weights11(1*length(ubg) + temprxnpos(m)) = min([(kappa*(-1)*abs(f0))/(abs(vv)), weights11(1*length(ubg) + temprxnpos(m)) ]);
                                elseif v(temprxnpos(m)) > 0
                                    tem = min([xx,ubf(temprxnpos(m)),ubg(temprxnpos(m))]);
                                    ubg(temprxnpos(m)) = max(tem,thresh);
                                    ub11(2*length(ubg) + temprxnpos(m)) = 1000;
                                    vv = max([abs(vm(temprxnpos(m))),mthresh]);
                                    weights11(2*length(ubg) + temprxnpos(m)) = min([(kappa*(-1)*abs(f0))/abs(vv), weights11(2*length(ubg) + temprxnpos(m)) ]);  % new weights based on kappa, normalized with growth rate
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    dxdt0 = [zeros(size(S,1),1);lbg;ubg];
    %lb11(lb11==ub11) = ub11(lb11 == ub11) - 1E-6; % prevents solver from crashing
    param.itlim = 1000000;
    %  optimizeCbModel
    [v00(ci,:),f00(ci),status1(ci)] = glpk(-weights11,A,dxdt0,lb11,ub11,ctype1,[],[],param);
    f(ci) = v00(ci,find(weights));
    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    coun  = 1;        lbh = lbg; ubh  = ubg;
    
    while ((status1(ci) ~= 5) || (v00(ci,find(weights)) < 0))
        lbh(lbh ~= lbf) = lbh(lbh ~= lbf) - 1E-3;
        ubh(ubh ~= ubf) = ubh(ubh ~= ubf) + 1E-3;
        dxdt0 = [zeros(size(S,1),1);lbh;ubh];
        [v00(ci,:),f00(ci),status1(ci)] = glpk(-weights11,A,dxdt0,lb11,ub11,ctype1,[],[],param);
        coun = coun + 1
        if (coun > 50),
            % if its impossible to estimate, then
            % check the unweighted g.r and the one with max weight prom -
            % if very less difference use it - any way warn the user about
            % the problem at the iteration number - ci;
            [v3,f3,status3] = glpk(-weights,S,dxdt,lbg,ubg,ctype);
            [v30,f30,status30] = glpk(-weights00,A,dxdt0,lb11,ub11,ctype1);
            %if abs((f3- v30(find(weights)))/abs(f3)) < 0.1
            f00(ci) = -f3;
            v00(ci,find(weights)) = -f3;
            %else
            disp(' problem in'); disp(ci);break;  % if that doesnt work,  display a warning
            %end
            
            disp('check'); disp(ci); break;
            
        end
    end
    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
        f(ci) = v00(ci,find(weights));

    lbg_st(ci,:) = lbg;
    ubg_st(ci,:) = ubg;
    
    lb_st(ci,:) = lbff;
    ub_st(ci,:) = ubff;
    
    [v2(ci,:),f1(ci),status] = glpk(-weights,S,dxdt,lbg,ubg,ctype);
    f_ko(ci) = -f1(ci);
    
    ktime = toc;
    waitpar = [num2str(ceil(ci/length(tfnames)*100)),'% complete. Time taken:',num2str(ceil(ktime)),' secs'];
    %waitbar(ci/length(tfnames),hw,waitpar);
    
    
    ff00(scou,ci) = v00(ci,find(weights));
    %disp(ff00(scou,ci))
    
    %%%%%%%%%%%%%%%%%%%%%%%%%%%%
    if datathreshflag
        if all(lost_xn(k))   % if none of the probabilities of a gene can be estimated, then ->
            disp('Error: xns cant be estimated')
            v00(ci,:) = NaN;
            f1(ci) = NaN;
            v2(ci,:) = NaN;
            f00(ci) = NaN;
            %break;
        end
    end
    
    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    
    clear tempgenepos tempgeneprobs temprxnpos k
    %disp(bnumstobekoed(ci))
end

% f_ko = -f1';
v_ko = v2;
%
% f00_ko(:,scou) = v00(:,find(weights));
v00_ko = v00;
%
% f = f00_ko;
v = v00_ko;


lostxns(:,scou) = lost_xn;

%disp([f,f_ko])

end

