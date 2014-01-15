
module Stampede.TransactionNode where

import Control.Distributed.Process
import Stampede.Types
import Stampede.Utils
import Control.Monad.State
import Control.Monad
import Data.List (delete)

-- Process that stores state about transactions
transactionNode :: TransactionId -> Process ()
transactionNode tx = do
    go (TransactionNode tx)
    where go state = do
               newState <- receiveWait [ matchState state handleFoo ]
               go newState

handleFoo = undefined
