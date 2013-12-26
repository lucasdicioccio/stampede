{-# LANGUAGE OverloadedStrings #-}

module Server where

import Network
import Control.Monad
import Control.Monad.State
import Control.Concurrent
import Control.Exception (finally)
import System.IO
import Data.ByteString as B
import Data.Map as M

import Stomp
import Parse
import Dump
import Helpers
import Data.Attoparsec (Parser, parse, feed, IResult (..))
import Data.Text (Text)
import Data.IORef

type Destination = Text

data ServerState = ServerState {
        queues :: M.Map Destination [Handle]
    } deriving (Show)

data ClientState = ClientState {
        handle :: Handle
    ,   hostName :: HostName
    ,   portNum :: PortNumber
    ,   receivedBytes :: Int
    ,   sentBytes :: Int
    -- TODO createdAt, lastReceived
    } deriving (Show)

server :: PortNumber -> IO ()
server port = withSocketsDo $ listenOn (PortNumber port) >>= acceptLoop

acceptLoop :: Socket -> IO ()
acceptLoop skt = do
    ref <- newIORef (ServerState M.empty)
    (forever $ accept skt >>= forkIO . stompLoop (serverHandler ref)) `finally` (sClose skt)

type Action a = StateT ClientState IO a

runAction f client = runStateT f client

stompLoop :: (ClientState -> Frame -> Action b)-> (Handle, String, PortNumber) -> IO ()
stompLoop handler (h,host,port) = do
    let client = ClientState h host port 0 0
    let srv    = ServerState (M.empty)
    hSetBuffering h NoBuffering
    (void $ runAction (go (parse stream B.empty)) client) `finally` hClose h
    where go :: ChunkParser -> Action ()
          go parser = do
            cl <- get
            buf <- liftIO $ hGetNonBlocking h 9000
            modify (\cl -> cl { receivedBytes = (receivedBytes cl) + (B.length buf) })
            case (feed parser buf) of
                 Fail _ _ _      -> liftIO (hIsEOF h) >>= \x -> if x then return () else go (parse stream B.empty)
                 Done rest frms  -> mapM_ (handler cl) frms >> go (parse stream rest)
                 f@(Partial _)   -> go f

serverHandler ::  (IORef ServerState) -> ClientState -> Frame -> Action ()
serverHandler ref client (ServerFrame _ _ _)          = liftIO . hClose $ handle client
serverHandler ref client (ClientFrame cmd hds body)   = handleCommand ref client cmd hds body

handleCommand :: (IORef ServerState) -> ClientState -> ClientCommand -> Headers -> Body -> Action ()
handleCommand ref client cmd hdrs body = case cmd of
    Connect     -> connectClient
    Subscribe   -> subscribeClient
    Send        -> forwardMessage
    a           -> liftIO $ print a >> print hdrs >> print body


    where connectClient = do
            liftIO (writeClient client Connected (M.fromList [("version","1.0"),("heartbeat","0,0")]) "") >>= (\len -> modify (\cl -> cl { sentBytes = (sentBytes cl) + len }))

          subscribeClient = do
            let (Just dst) = M.lookup "destination" hdrs 
            liftIO $ atomicModifyIORef' ref (f dst)
            return ()
            where f dst srv = (ServerState queues', queues')
                              where queues' = M.alter (appendHandle) dst (queues srv)
                                    appendHandle Nothing   = Just $ [handle client]
                                    appendHandle (Just xs) = Just $ (handle client):xs

          forwardMessage = do
            let (Just dst) = M.lookup "destination" hdrs 
            st <- liftIO $ readIORef ref
            let handles = M.lookup dst (queues st)
            liftIO $ maybe (print "no such queue") (mapM_ (\h -> writeClientH h Message hdrs body)) handles

writeClient :: ClientState -> ServerCommand -> Headers -> Body -> IO (Int)
writeClient client = writeClientH (handle client)

writeClientH :: Handle -> ServerCommand -> Headers -> Body -> IO (Int)
writeClientH h cmd hdrs body = do
    let buf = dump (ServerFrame cmd hdrs body)
    hPut h buf
    return $ B.length buf
