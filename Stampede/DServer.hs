{-# LANGUAGE OverloadedStrings #-}

module Stampede.DServer where

import Network
import Control.Monad
import System.IO
import Data.ByteString as B
import qualified Data.ByteString.Lazy as BL

import Stampede.Stomp
import Stampede.Parse
import Stampede.Dump
import Stampede.Helpers
import Data.Attoparsec (Parser, parse, feed, IResult (..))
import Data.Text (Text)

import Control.Distributed.Process
import Data.Binary

type SktInfo = (Handle, HostName, PortNumber)

data ClientState = ClientState {
        sktInfo     :: SktInfo
    ,   receivePort :: ReceivePort Frame
    ,   sendPort    :: SendPort Frame
    }

server :: PortNumber -> Process ()
server port = liftIO (withSocketsDo $ listenOn (PortNumber port)) >>= acceptLoop

acceptLoop :: Socket -> Process ()
acceptLoop skt = go
    where go = do
            infos@(h,addr,port) <- liftIO $ accept skt
            liftIO $ hSetBuffering h NoBuffering
            clientPid <- spawnLocal $ clientProcess infos
            go

client :: SktInfo -> ReceivePort Frame -> SendPort Frame -> ClientState
client = ClientState

clientProcess :: SktInfo -> Process ()
clientProcess infos@(h,_,_) = do
    (spIn,rpIn) <- newChan
    (spOut,rpOut) <- newChan
    spawnLocal (parseClientInputLoop h spIn) >>= link
    spawnLocal (forwardClientOutputLoop h rpOut) >>= link
    processClientInputLoop (client infos rpIn spOut) rpIn 

processClientInputLoop :: ClientState -> ReceivePort Frame -> Process ()
processClientInputLoop _st0 rp = go _st0
    where go :: ClientState -> Process ()
          go st0 = do
            frm <- receiveChanTimeout 100000 rp --encodes input heartbeat
            go st0

forwardClientOutputLoop :: Handle -> ReceivePort Frame -> Process ()
forwardClientOutputLoop h rp = go
    where go = do
            frm <- receiveChanTimeout 100000 rp --encodes output heartbeat
            let buf = maybe "" encode frm
            liftIO $ B.hPut h (B.concat $ BL.toChunks buf)
            go

parseClientInputLoop :: Handle -> SendPort Frame -> Process ()
parseClientInputLoop h sp = do
    (go (parse stream B.empty))
    `finally`
    (liftIO $ hClose h)
    where go :: ChunkParser Frame -> Process ()
          go parser = do
            buf <- liftIO $ B.hGetNonBlocking h 9000
            case (feed parser buf) of
                 Fail _ _ _      -> liftIO (hIsEOF h) >>= \x -> if x then return () else go (parse stream B.empty)
                 Done rest frms  -> mapM_ (sendChan sp) frms >> go (parse stream rest)
                 f@(Partial _)   -> go f
