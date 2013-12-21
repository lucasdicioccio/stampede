{-# LANGUAGE OverloadedStrings #-}

module Server where

import Network
import Control.Monad
import Control.Concurrent
import Control.Exception (finally)
import System.IO
import Data.ByteString as B
import Data.Map as M

import Stomp
import Parse
import Dump
import Data.Attoparsec (Parser, parse, feed, IResult (..))

type Client = (Handle, HostName, PortNumber)

server :: PortNumber -> IO ()
server port = withSocketsDo $ listenOn (PortNumber port) >>= acceptLoop

acceptLoop :: Socket -> IO ()
acceptLoop skt = (forever $ accept skt >>= forkIO . clientLoop) `finally` (sClose skt)

handle :: Client -> Handle
handle (h,_,_) = h

clientLoop :: Client -> IO ()
clientLoop client@(h,_,_) = do
    hSetBuffering h NoBuffering
    go (parse stream B.empty)
    where go parser = do
            buf <- hGetNonBlocking h 9000
            case (feed parser buf) of
                 Fail _ _ _      -> hIsEOF h >>= \x -> if x then return () else go (parse stream B.empty)
                 Done rest frms  -> mapM_ (handleFrame client) frms >> go (parse stream rest)
                 f@(Partial _)   -> go f

handleFrame ::  Client -> Frame -> IO ()
handleFrame client (ServerFrame _ _ _)          = hClose $ handle client
handleFrame client (ClientFrame cmd hds body)   = handleCommand client cmd hds body

handleCommand :: Client -> ClientCommand -> Headers -> Body -> IO ()
handleCommand client (Connect) hdrs body = hPut (handle client) $ dump (ServerFrame Connected (M.empty) "")
handleCommand client (Subscribe) hdrs body = print hdrs >> print body
handleCommand client (Send) hdrs body = print hdrs >> print body
