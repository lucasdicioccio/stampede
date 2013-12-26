{-# LANGUAGE OverloadedStrings #-}

module Server where

import Network
import Control.Monad
import Control.Monad.State
import Control.Concurrent
import Control.Exception (finally)
import System.IO
import qualified Data.ByteString as B
import qualified Data.Text as T
import qualified Data.Map as M
import Data.List (delete)

import Stomp
import Parse
import Dump
import Helpers
import Data.Attoparsec (Parser, parse, feed, IResult (..))
import Data.Text (Text)
import Data.Text.Read (decimal)
import Data.IORef

type Destination    = Text
type SubscriptionId = Int
type Subscriptions  = (SubscriptionId, Handle)

data ServerState = ServerState {
        -- todo: method to remove dying subscriptions
        queues :: M.Map Destination [Subscriptions]
    } deriving (Show)

data ClientState = ClientState {
        handle :: Handle
    ,   hostName :: HostName
    ,   portNum :: PortNumber
    ,   receivedBytes :: Int
    ,   sentBytes :: Int
    ,   lastSubscription :: SubscriptionId
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

stompLoop :: (Frame -> Action b)-> (Handle, String, PortNumber) -> IO ()
stompLoop handler (h,host,port) = do
    let client = ClientState h host port 0 0 0
    let srv    = ServerState (M.empty)
    hSetBuffering h NoBuffering
    (void $ runAction (go (parse stream B.empty)) client) `finally` hClose h
    where go :: ChunkParser -> Action ()
          go parser = do
            cl <- get
            buf <- liftIO $ B.hGetNonBlocking h 9000
            modify (\cl -> cl { receivedBytes = (receivedBytes cl) + (B.length buf) })
            case (feed parser buf) of
                 Fail _ _ _      -> liftIO (hIsEOF h) >>= \x -> if x then return () else go (parse stream B.empty)
                 Done rest frms  -> mapM_ handler frms >> go (parse stream rest)
                 f@(Partial _)   -> go f

serverHandler ::  (IORef ServerState) -> Frame -> Action ()
serverHandler ref (ServerFrame _ _ _)          = tellError "expecting clientFrame" >> get >>= liftIO . hClose . handle
serverHandler ref (ClientFrame cmd hds body)   = handleCommand ref cmd hds body

tellError :: Text -> Action ()
tellError msg = liftIO $ print (T.append "client error:" msg)

handleCommand :: (IORef ServerState) -> ClientCommand -> Headers -> Body -> Action ()
handleCommand ref cmd hdrs body = case cmd of
    Connect         -> connectClient
    Subscribe       -> subscribeClient
    Unsubscribe     -> unsubscribeClient
    Send            -> forwardMessage
    a               -> liftIO $ print a >> print hdrs >> print body


    where connectClient = do
            client <- get
            liftIO (writeClient client Connected (M.fromList [("version","1.0"),("heartbeat","0,0")]) "") >>= (\len -> modify (\cl -> cl { sentBytes = (sentBytes cl) + len }))

          subscribeClient = do
            let (Just dst) = M.lookup "destination" hdrs 
            client <- get
            liftIO $ atomicModifyIORef ref (addSub client dst)
            put (client { lastSubscription = lastSubscription client + 1 })
            -- todo: answer that subscription worked
            return ()
            where addSub cli dst srv = (ServerState queues', queues')
                              where queues' = M.alter (appendHandle) dst (queues srv)
                                    appendHandle Nothing   = Just $ [subscription]
                                    appendHandle (Just xs) = Just $ (subscription):xs
                                    subscription = (lastSubscription cli, handle cli)

          unsubscribeClient = do
            let (Just dst)   = M.lookup "destination" hdrs
            let (Just subId) = (M.lookup "subscription" hdrs) >>= either (const Nothing) (return . fst) . decimal
            client <- get
            liftIO $ atomicModifyIORef ref (rmSub client dst subId)
            -- todo: answer that subscription didntwork
            return ()
            where rmSub cli dst subId srv = (ServerState queues', queues')
                              where queues' = M.alter (removeHandle) dst (queues srv)
                                    removeHandle Nothing   = Nothing
                                    removeHandle (Just xs) = Just $ delete subscription xs
                                    subscription = (subId, handle cli)

          forwardMessage = do
            let (Just dst) = M.lookup "destination" hdrs 
            st <- liftIO $ readIORef ref
            let handles = liftM (map snd) $ M.lookup dst (queues st)
            -- todo: add subscription id to headers
            liftIO $ maybe (print "no such queue") (mapM_ (\h -> writeClientH h Message hdrs body)) handles

writeClient :: ClientState -> ServerCommand -> Headers -> Body -> IO (Int)
writeClient client = writeClientH (handle client)

writeClientH :: Handle -> ServerCommand -> Headers -> Body -> IO (Int)
writeClientH h cmd hdrs body = do
    let buf = dump (ServerFrame cmd hdrs body)
    B.hPut h buf
    return $ B.length buf
