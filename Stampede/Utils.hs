
module Stampede.Utils where

import Data.Typeable
import Data.Binary
import Control.Monad.State
import Control.Distributed.Process

matchState :: (Typeable a1, Binary a1) => b -> (a1 -> StateT b Process a) -> Match b
matchState state f = match f'
    where f' msg = execStateT (f msg) state 

