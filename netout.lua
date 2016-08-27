#!/usr/bin/env th

require 'torch'
require 'cutorch'
require 'cunn'
require 'cudnn'
require 'nn'

require 'src.utilities'
require 'src.RandomBatcher'; local Batcher = RandomBatcher

function opts_parse(arg)
  cmd = torch.CmdLine()

  cmd:text()
  cmd:text('Generate raw outputs of a DCNN-LSTM-CTC model.')
  cmd:text()

  cmd:text('Options:')
  cmd:option('-batch_size', 40, 'Batch size')
  cmd:option('-min_width', 0, 'Minimum image width for batches')
  cmd:option('-width_factor', true, 'Make width a factor of the max pooling reduction')
  cmd:option('-gpu', 0, 'Which gpu to use. -1 = use CPU')
  cmd:option('-seed', 0x12345, 'Random number generator seed to use')
  cmd:option('-htk', false, 'Output in KTK format')
  cmd:option('-softmax', false, 'Whether to add softmax layer at end of network')
  cmd:option('-convout', false, 'Whether to provide output of convolutional layers')
  cmd:option('-outpads', '', 'File to output image horizontal paddings')
  -- @todo Finish implementation of prior computation
  cmd:option('-priorcomp', '', 'Compute priors using given ground truth')
  cmd:option('-loglkh', '', 'Compute log-likelihoods using provided priors')
  cmd:option('-alpha', 0.3, 'p(x|s) = P(s|x) / P(s)^LOGLKH_ALPHA_FACTOR')

  cmd:text()

  cmd:text('Arguments:')
  cmd:argument('model', 'Path to the neural network model file')
  cmd:argument('data', 'Path to the list of images')
  cmd:argument('outdir', 'Directory to write character posterior matrices')
  cmd:text()

  local opt = cmd:parse(arg or {})
  assert(opt.batch_size > 0, 'Batch size must be greater than 0')
  return opt
end

local opt = opts_parse(arg)

math.randomseed(opt.seed)
torch.manualSeed(opt.seed)
cutorch.manualSeed(opt.seed)

local model = torch.load(opt.model).model

-- Prior computation mode
if opt.priorcomp ~= '' then
  opt.gt_file = opt.priorcomp
  opt.priorcomp = true
  opt.softmax = true
  opt.convout = false
  opt.loglkh = ''
else
  opt.priorcomp = false
end

-- Log-likelihood computation mode
local loglkh = false
local logprior = {}
local zeroprior = {}
if opt.loglkh ~= '' then
  local f = io.open(opt.loglkh, 'r')
  assert(f ~= nil, string.format('Unable to read priors file: %q', opt.loglkh))
  local ln = 0
  while true do
    local line = f:read('*line')
    if line == nil then break end
    ln = ln+1
    line = line:match('^%s*(.-)%s*$'):gsub('.*%s','')
    local prior = tonumber(line)
    zeroprior[ln] = prior == 0 and true or false
    logprior[ln] = torch.log(prior)*opt.alpha
  end
  f:close()
  loglkh = true
  opt.softmax = true
end

-- Output image paddings
local outpads = false
if opt.outpads ~= '' then
  outpads = io.open(opt.outpads, 'w')
end

-- Output from convolutional layers
if opt.convout then
  local blstm = model:findModules('cudnn.BLSTM')
  assert(#blstm > 0, 'For convout expected to find a BLSTM module')
  local n = model:size()
  while model:get(n) ~= blstm[1] do
    model:remove()
    n = n-1
  end
  model:remove()
end

-- Add softmax layer
if opt.softmax then
  model:add(nn.SoftMax())
end

-- 
if opt.gpu >= 0 then
  cutorch.setDevice(opt.gpu + 1) -- +1 because lua is 1-indexed
  model = model:cuda()
  cudnn.convert(model, cudnn)
else
  -- CPU
  model:float()
end

model:evaluate()

-- Read input channels from the model
opt.channels = model:get(1):get(1).nInputPlane
-- Compute width factor from model
if opt.width_factor then
  opt.width_factor = 1
  local maxpool = model:findModules('cudnn.SpatialMaxPooling')
  for n=1,#maxpool do
    opt.width_factor = opt.width_factor * maxpool[n].kW
  end
else
  opt.width_factor = 0
end
local dv = Batcher(opt.data, opt); dv:epochReset()

local nSamples = torch.IntStorage(1);
local sampPeriod = torch.IntStorage(1); sampPeriod[1] = 100000; -- 10000000 = 1seg
local sampSize = torch.ShortStorage(1);
local parmKind = torch.ShortStorage(1); parmKind[1] = 9; -- PARMKIND=USER

local n = 0
for batch=1,dv:numSamples(),opt.batch_size do
  -- Prepare batch
  local batch_size = n+opt.batch_size > dv:numSamples() and dv:numSamples()-n or opt.batch_size
  local batch_img, batch_gt, _, batch_ids, batch_hpad = dv:next(opt.batch_size)
  if opt.gpu >= 0 then
    batch_img = batch_img:cuda()
  end

  if outpads then
    for i = 1, batch_size do
      outpads:write(batch_ids[i]..' '..batch_hpad[i][1]..' '..batch_hpad[i][2]..' '..batch_hpad[i][3]..'\n')
    end
    outpads:flush();
  end

  -- Forward through network
  local output = model:forward(batch_img)

  -- Compute priors
  if opt.priorcomp then
    if not prior_count then
      local prior_total = 0
      local prior_count = torch.IntTensor(output:size(2)):zero()
    end

    local nframes = output:size(1) / opt.batch_size
    local sample = torch.FloatTensor(nframes,output:size(2))

    -- Loop through batch samples
    for i = 1, batch_size do

      -- Copy sample for speed
      local j = 1
      for f=i,output:size(1),opt.batch_size do
        sample[{j,{}}]:copy(output[{f,{}}])
        j = j+1
      end

      -- @todo Do forced alignment of sample w.r.t. batch_gt[i]
      sample:log()
      local tbFA = forceAlignment(sample,batch_gt[i])

      prior_total = prior_total + nframes
      -- @todo Increment prior_count
      for _,v in pairs(tbFA) do
	 prior_count[v] = prior_count[v] + 1
      end
      
    end

  -- Ouput from convolutional layers
  elseif opt.convout then

    -- Loop through batch samples
    for i = 1, batch_size do
      -- Output in HTK format
      if opt.htk then
        local fd = torch.DiskFile( opt.outdir..'/'..batch_ids[i]..'.fea', 'w' ):binary():bigEndianEncoding()
        nSamples[1] = output:size(1)
        sampSize[1] = 4*output:size(3)
        fd:writeInt( nSamples[1] )
        fd:writeInt( sampPeriod[1] )
        fd:writeShort( sampSize[1] )
        fd:writeShort( parmKind[1] )
        for f=1, output:size(1) do
          for c = 1, output:size(3) do
            fd:writeFloat( output[f][i][c] )
          end
        end
        fd:close()
      -- Output in ASCII format
      else
        local fd = io.open( opt.outdir..'/'..batch_ids[i]..'.fea', 'wb' )
        for f=1, output:size(1) do
          fd:write( string.format('%g',output[f][i][1]) )
          for c = 2, output:size(3) do
            fd:write( string.format(' %g',output[f][i][c]) )
          end
          fd:write('\n')
        end
        fd:close()
      end
    end

  -- Output from complete network
  else

    local nframes = output:size(1) / opt.batch_size
    local values = nframes*output:size(2)
    local sample = torch.FloatTensor(nframes,output:size(2))

    -- Softmax output
    --if opt.softmax2 then
    --  output:exp()
    --  output:cdiv( output:sum(2):repeatTensor(1,output:size(2)) ); 
    --end

    if loglkh then
      for k = 1, sample:size(2) do
        if zeroprior[k] then
          output[{{},k}]:fill(-743.747)
        else
          output[{{},k}]:log():csub(logprior[k])
        end
      end
    end

    -- Loop through batch samples
    for i = 1, batch_size do

      -- Copy sample for speed
      local j = 1
      for f=i,output:size(1),opt.batch_size do
        sample[{j,{}}]:copy(output[{f,{}}])
        j = j+1
      end

      -- Output in HTK format
      if opt.htk then
        local fd = torch.DiskFile( opt.outdir..'/'..batch_ids[i]..'.fea', 'w' ):binary():bigEndianEncoding()
        nSamples[1] = output:size(1)/opt.batch_size
        sampSize[1] = 4*output:size(2)
        fd:writeInt( nSamples[1] )
        fd:writeInt( sampPeriod[1] )
        fd:writeShort( sampSize[1] )
        fd:writeShort( parmKind[1] )
        local storage = sample:storage()
        for j=1,values do
          fd:writeFloat( storage[j] )
        end
        fd:close()
      -- Output in ASCII format
      else
        local fd = io.open( opt.outdir..'/'..batch_ids[i]..'.fea', 'wb' )
        for j=1,sample:size(1) do
          fd:write( string.format('%g',sample[{j,1}]) )
          for k = 2, sample:size(2) do
            fd:write( string.format(' %g',sample[{j,k}]) )
          end
          fd:write('\n')
        end
        fd:close()
      end
    end

  end

  n = n + batch_size
end

if opt.priorcomp then
  for n=1,#prior_count do
    io.write( string.format('%d\t%d\t%d\t%.10e\n',n-1,prior_count[n],prior_total,prior_count[n]/prior_total) )
  end
end

if outpads then
  outpads:close()
end