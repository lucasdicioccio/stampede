
module Main where

import Stampede.Server
import Control.Distributed.Process.Backend.SimpleLocalnet   
import Control.Distributed.Process.Node (runProcess,forkProcess,initRemoteTable)

main :: IO ()
main = do
    backend  <- initializeBackend "localhost" "3000" initRemoteTable
    n0 <- newLocalNode backend
    runProcess n0 $ server 61613
