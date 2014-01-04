
module Stampede.Router where

import Control.Distributed.Process
import Control.Monad.State
import Control.Monad
import qualified Data.Map as M

import Stampede.Types
import Stampede.Utils
import Stampede.SubscriptionNode

-- Process that routes requests to a given node
router :: Process ()
router = do
    getSelfPid >>= register "stampede.router"
    go (RoutingTable $ M.fromList [])
    where go :: RoutingTable -> Process ()
          go state = do 
                newState <- receiveWait [ matchState state handleLookup
                                        ]
                go newState

handleLookup :: (Destination, ProcessId) -> Action RoutingTable
handleLookup (dst, req) = do
    (RoutingTable rt) <- get
    let node = M.lookup dst rt
    maybe spawnAndForwardToNode forwardToNode node

    where spawnAndForwardToNode :: Action RoutingTable
          spawnAndForwardToNode = do
                sub <- lift $ do
                        pid <- spawnLocal $ subscriptionNode dst
                        monitor pid
                        send req pid
                        return pid
                modify (\(RoutingTable rt) -> (RoutingTable $ M.insert dst sub rt))

          forwardToNode :: SubscriptionNodeId -> Action RoutingTable
          forwardToNode pid = lift $ send req pid
