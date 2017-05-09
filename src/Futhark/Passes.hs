{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
-- | Optimisation pipelines.
module Futhark.Passes
  ( standardPipeline
  , sequentialPipeline
  , gpuPipeline
  , CompilationMode (..)
  )
where

import Control.Category ((>>>), id)
import Control.Monad.Except
import Data.Maybe

import Prelude hiding (id)

import Futhark.Optimise.CSE
import Futhark.Optimise.Fusion
import Futhark.Optimise.InPlaceLowering
import Futhark.Optimise.InliningDeadFun
import Futhark.Optimise.TileLoops
import Futhark.Optimise.DoubleBuffer
import Futhark.Optimise.Unstream
import Futhark.Pass.MemoryBlockMerging
import Futhark.Pass.ExpandAllocations
import Futhark.Pass.ExplicitAllocations
import Futhark.Pass.ExtractKernels
import Futhark.Pass.FirstOrderTransform
import Futhark.Pass.KernelBabysitting
import Futhark.Pass.Simplify
import Futhark.Pass
import Futhark.Pipeline
import Futhark.Representation.ExplicitMemory (ExplicitMemory)
import Futhark.Representation.SOACS (SOACS)
import Futhark.Representation.AST.Syntax
import Futhark.Util

-- | Are we compiling the Futhark program as an executable or a
-- library?  This affects which functions are considered as roots for
-- dead code elimination and ultimately exist in generated code.
data CompilationMode = Executable
                     -- ^ Only the top-level function named @main@ is
                       -- alive.
                     | Library
                       -- ^ Only top-level functions marked @entry@
                       -- are alive.

standardPipeline :: CompilationMode -> Pipeline SOACS SOACS
standardPipeline mode =
  passes [ simplifySOACS
         , inlineAndRemoveDeadFunctions
         , performCSE True
         , simplifySOACS
           -- We run fusion twice
         , fuseSOACs
         , performCSE True
         , simplifySOACS
         , fuseSOACs
         , performCSE True
         , simplifySOACS
         , removeDeadFunctions
         ]

-- Experimental!  Enable by setting the environment variable
-- MEMORY_BLOCK_MERGING to 1.
usesExperimentalMemoryBlockMerging :: Bool
usesExperimentalMemoryBlockMerging =
  maybe False (=="1") $ lookup "MEMORY_BLOCK_MERGING" unixEnvironment

withExperimentalMemoryBlockMerging :: Pipeline SOACS ExplicitMemory
                                   -> Pipeline SOACS ExplicitMemory
withExperimentalMemoryBlockMerging =
  (>>> passes [ mergeMemoryBlocks
              , simplifyExplicitMemory
              ])

withExperimentalPasses :: Pipeline SOACS ExplicitMemory
                       -> Pipeline SOACS ExplicitMemory
withExperimentalPasses pipeline =
  if usesExperimentalMemoryBlockMerging
  then withExperimentalMemoryBlockMerging pipeline
  else pipeline

sequentialPipeline :: CompilationMode -> Pipeline SOACS ExplicitMemory
sequentialPipeline mode =
  withExperimentalPasses $
  standardPipeline mode >>>
  onePass firstOrderTransform >>>
  passes [ simplifyKernels
         , inPlaceLowering
         ] >>>
  onePass explicitAllocations >>>
  passes [ simplifyExplicitMemory
         , performCSE False
         , simplifyExplicitMemory
         , doubleBuffer
         , simplifyExplicitMemory
         ]

gpuPipeline :: CompilationMode -> Pipeline SOACS ExplicitMemory
gpuPipeline mode =
  withExperimentalPasses $
  standardPipeline mode >>>
  onePass extractKernels >>>
  passes [ simplifyKernels
         , babysitKernels
         , simplifyKernels
         , tileLoops
         , unstream
         , simplifyKernels
         , performCSE True
         , simplifyKernels
         , inPlaceLowering
         ] >>>
  onePass explicitAllocations >>>
  passes [ simplifyExplicitMemory
         , performCSE False
         , simplifyExplicitMemory
         , doubleBuffer
         , simplifyExplicitMemory
         , expandAllocations
         , simplifyExplicitMemory
         ]
