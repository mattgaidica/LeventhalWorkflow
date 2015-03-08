function createPLXFiles(sessionName,varargin)

    onlyGoing = 'negative';
    
    for iarg = 1 : 2 : nargin - 1
        switch varargin{iarg}
            case 'sessionConfPath'
                sessionConfPath = varargin{iarg + 1};
            case 'nasPath',
                nasPath = varargin{iarg + 1};
            case 'onlyGoing'
                onlyGoing = varargin{iarg + 1};
        end
    end
    
    % make sessionConf variable
    if exist('sessionConfPath','var')
        load(sessionConfPath);
    else
        sessionConf = exportSessionConf(sessionName);
    end
    % override nasPath for local use
    if exist('nasPath','var')
        sessionConf.nasPath = nasPath;
    end
    
    % get paths, create: processed
    leventhalPaths = buildLeventhalPaths(sessionConf.nasPath,sessionConf.sessionName,{'processed'});
    
    spikeParameterString = sprintf('WL%02d_PL%02d_DT%02d', sessionConf.waveLength,...
       sessionConf.peakLoc, sessionConf.deadTime);

    validTetrodes = find(any(sessionConf.validMasks,2).*sessionConf.chMap(:,1));
    fullSevFiles = getChFileMap(leventhalPaths.session);
    
    for ii=1:length(validTetrodes)
        tetrodeName = sessionConf.tetrodeNames{validTetrodes(ii)};
        disp(['Processing tetrode ',tetrodeName]);
        tetrodeChannels = sessionConf.chMap(validTetrodes(ii),2:end);
        tetrodeValidMask = sessionConf.validMasks(validTetrodes(ii),:);
        
        tetrodeFilenames = fullSevFiles(tetrodeChannels);
        data = prepSEVData(tetrodeFilenames,tetrodeValidMask,500);
        locs = getSpikeLocations(data,tetrodeValidMask,sessionConf.Fs,onlyGoing);
        
        PLXfn = fullfile(leventhalPaths.processed,[sessionConf.sessionName,...
            '_',tetrodeName,'_',spikeParameterString,'.plx']);
        PLXid = makePLXInfo(PLXfn,sessionConf,tetrodeChannels,length(data));
        makePLXChannelHeader(PLXid,sessionConf,tetrodeChannels,tetrodeName);
        
        disp('Extracing waveforms...');
        waveforms = extractWaveforms(data,locs,sessionConf.peakLoc,...
            sessionConf.waveLength);
        disp('Writing waveforms to PLX file...');
        writePLXdatablock(PLXid,waveforms,locs);
    end
end

function data = prepSEVData(filenames,validMask,threshArtifacts)
    header = getSEVHeader(filenames{1});
    dataLength = (header.fileSizeBytes - header.dataStartByte) / header.sampleWidthBytes;
    data = zeros(length(validMask),dataLength);
    for ii=1:length(filenames)
        if ~validMask(ii), continue, end
        disp(['Reading ',filenames{ii}]);
        [data(ii,:),~] = read_tdt_sev(filenames{ii});
        data(ii,:) = wavefilter(data(ii,:),6);
        data(ii,:) = artifactThresh(double(data(ii,:)),threshArtifacts);
    end
end

function fullSevFiles = getChFileMap(sessionPath)
    sevFiles = dir(fullfile(sessionPath,'*.sev'));
    chFileMap = zeros(length(sevFiles),1);
    fullSevFiles = cell(length(sevFiles),1);
    for ii=1:length(sevFiles)
        chFileMap(ii) = getSEVChFromFilename(sevFiles(ii).name);
        fullSevFiles{ii} = fullfile(sessionPath,sevFiles(ii).name);
    end
    fullSevFiles(chFileMap) = fullSevFiles; %remap so they are in order
end

function ch = getSEVChFromFilename(name)
    C = strsplit(name,'_');
    C = strsplit(C{end},'.'); %C{1} = chXX
    ch = str2double(C{1}(3:end));
end

function makePLXChannelHeader(PLXid,sessionConf,tetrodeChannels,tetrodeName)
    for ii=1:length(tetrodeChannels)
        chInfo.tetName  = [sessionConf.sessionName,'_',tetrodeName];
        chInfo.wireName = sprintf('%s_W%02d', tetrodeName, ii);

        chInfo.wireNum   = ii; %tetrode number
        chInfo.WFRate    = sessionConf.Fs;
        chInfo.SIG       = tetrodeChannels(ii);  %channel number
        chInfo.refWire   = 0;     % not sure exactly what this is; Alex had it set to zero
        chInfo.gain      = 300;
        chInfo.filter    = 0;    % not sure what this is; Alex had it set to zero
        chInfo.thresh    = 0; % does this even matter anywhere?
        chInfo.numUnits  = 0;    % no sorted units
        chInfo.sortWidth = sessionConf.waveLength;
        chInfo.comment   = 'created with Spikey, makePLXChannelHeader';

        writePLXChanHeader(PLXid, chInfo);
    end
end

function PLXid = makePLXInfo(PLXfn,sessionConf,tetrodeChannels,dataLength)
    sessionDateStr = sessionConf.sessionName(7:14);
    sessionDateVec = datevec(sessionDateStr, 'yyyymmdd');

    plxInfo.comment    = '';
    plxInfo.ADFs       = sessionConf.Fs; % record the upsampled Fs as the AD freq for timestamps
    plxInfo.numWires   = length(tetrodeChannels);
    plxInfo.numEvents  = 0;
    plxInfo.numSlows   = 0;
    plxInfo.waveLength = sessionConf.waveLength;
    plxInfo.peakLoc    = sessionConf.peakLoc;

    plxInfo.year  = sessionDateVec(1);
    plxInfo.month = sessionDateVec(2);
    plxInfo.day   = sessionDateVec(3);

    timeVector = datevec('12:00','HH:MM');
    plxInfo.hour       = timeVector(4);
    plxInfo.minute     = timeVector(5);
    plxInfo.second     = 0;
    plxInfo.waveFs     = sessionConf.Fs; % record the upsampled Fs as the waveform sampling frequency
    plxInfo.dataLength = dataLength;

    plxInfo.Trodalness     = length(tetrodeChannels); %Trodalness - 0,1 = single electrode, 2 = stereotrode, 4 = tetrode
    plxInfo.dataTrodalness = 0; %this is set to 0 in the Plexon tetrode sample file

    plxInfo.bitsPerSpikeSample = 16;
    plxInfo.bitsPerSlowSample  = 16;

    plxInfo.SpikeMaxMagnitudeMV = 10000;
    plxInfo.SlowMaxMagnitudeMV  = 10000;

    plxInfo.SpikePreAmpGain = 1; % gain before final amplification stage

    PLXid = fopen(PLXfn, 'w');
    disp('PLX file opened...')
    writePLXheader(PLXid, plxInfo);
end