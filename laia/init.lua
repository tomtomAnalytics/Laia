laia = {}

-- Base utility functions (laia.log, assert, error, wrequire)
require('laia.util.base')

-- Extensions over standard Lua packages
require('laia.util.math')    -- math.* extensions
require('laia.util.string')  -- string.* extensions
require('laia.util.table')   -- table.* extensions

-- Required packages.
torch = require('torch')
nn = require('nn')

-- Laia utilities.
laia.argparse = require('laia.util.argparse')   -- Argparse utility
require('laia.util.decode')  -- Laia decoding utilities
require('laia.util.format')  -- Laia decoding utilities
require('laia.util.io')      -- Laia I/O utilities
require('laia.util.rand')    -- RNG utils and distributions
require('laia.util.torch')   -- Torch utilities
require('laia.util.types')   -- type check/converstion utilities

-- Optional packages, show a warning if they are not found.
-- TODO(jpuigcerver): Some of these are actually mandatory modules for the
-- current standard model generated by create_model.lua.
cutorch = wrequire('cutorch')
cunn = wrequire('cunn')
cudnn = wrequire('laia.util.cudnn')   -- cudnn with extensions

-- Mandatory Laia classes
require('laia.Version')
require('laia.AdversarialRegularizer')
require('laia.CachedBatcher')
require('laia.Checkpoint')
require('laia.ClassWithOptions')
require('laia.CurriculumBatcher')
require('laia.CTCTrainer')
require('laia.EpochCheckpoint')
require('laia.EpochSummarizer')
require('laia.Monitor')
require('laia.ProgressTable')
require('laia.RandomBatcher')
require('laia.SignalHandler')
require('laia.Statistics')
require('laia.WeightDecayRegularizer')

-- Optional Laia classes
wrequire('laia.ImageDistorter')

laia.nn = {}
require('laia.nn.MDRNN')
require('laia.nn.ImageColumnSequence')

-- Determine whether stdout/stderr are terminals or not. If term package
-- cannot be loaded, assume they ARE NOT terminals (i.e. no colors shown).
local term = wrequire('term')
laia.stdout_isatty = term and term.isatty(io.stdout)
laia.stderr_isatty = term and term.isatty(io.stderr)

return laia
