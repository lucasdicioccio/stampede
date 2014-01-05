{-# LANGUAGE OverloadedStrings #-}

module Stampede.Server where

import Network
import Control.Monad
import Control.Monad.State
import System.IO
import qualified Data.ByteString as B

import Data.Attoparsec (Parser, parse, feed, IResult (..))
import qualified Data.Text as T
import qualified Data.Map as M
import Data.Text.Binary

import Control.Distributed.Process
import Data.Binary (Binary, encode, decode)
import Data.Typeable (Typeable)

import Data.Maybe

import Stampede.Stomp
import Stampede.Parse
import Stampede.Dump
import Stampede.Helpers
import Stampede.Types
import Stampede.Router

server :: PortNumber -> Process ()
server port = do
    spawnLocal router
    liftIO (withSocketsDo $ listenOn (PortNumber port)) >>= acceptLoop

acceptLoop :: Socket -> Process ()
acceptLoop skt = go
    where go = do
            infos@(h,addr,port) <- liftIO $ accept skt
            liftIO $ hSetBuffering h NoBuffering
            clientPid <- spawnLocal $ clientProcess infos
            go

clientProcess :: SktInfo -> Process ()
clientProcess infos@(h,_,_) = do
    liftIO $ print "spawning client"
    (spIn,rpIn) <- newChan
    (spOut,rpOut) <- newChan
    spawnLocal (parseClientInputLoop h spIn) >>= link
    spawnLocal (forwardClientOutputLoop h rpOut) >>= link
    processClientInputLoop (client infos rpIn spOut) rpIn 

processClientInputLoop :: ClientState -> ReceivePort Frame -> Process ()
processClientInputLoop _st0 rp = go _st0
    where go :: ClientState -> Process ()
          go st0 = do
            frm <- receiveChanTimeout 1000000 rp --encodes input heartbeat
            liftIO $ putStrLn $ "in  << " ++ show frm
            runStateT (react frm) st0 >>= go . snd

react :: (Maybe Frame) -> StateT ClientState Process ()
react Nothing                               = return ()
react (Just (ServerFrame _ _ _))            = error "should die disconnecting client"
react (Just (ClientFrame cmd hdrs body))    = handleCommand cmd hdrs body

handleCommand :: ClientCommand -> Headers -> Body -> Action ClientState
handleCommand cmd hdrs body = do
    case cmd of
        Connect         -> void connectClient
        Stomp           -> void connectClient
        Disconnect      -> error "not implemented (Disconnect)"
        Subscribe       -> subscribeClient
        Unsubscribe     -> unsubscribeClient
        Send            -> forwardMessage
        Ack             -> error "not implemented (Ack)"
        Nack            -> error "not implemented (Nack)"
        Begin           -> error "not implemented (Begin)"
        Commit          -> error "not implemented (Commit)"
        Abort           -> error "not implemented (Abort)"

    where connectClient :: Action ClientState
          connectClient = reply Connected [("version","1.0"), ("heart-beat","0,0")] ""

          subscribeClient :: Action ClientState
          subscribeClient = do
            let (Just dst) = M.lookup "destination" hdrs 
            client <- get
            let subId = T.pack . show $ nSub client
            let sub = DoSubscribe (subId, sendPort client)
            let ackMod = fromMaybe "auto" (M.lookup "ack" hdrs)
            -- pass AckMode into sub
            lift $ lookupDestination dst >>= (\pid -> send pid sub)
            modify (\cl -> cl { nSub = nSub client + 1 })
            void $ replyReceipt hdrs

          unsubscribeClient :: Action ClientState
          unsubscribeClient = do
            let (Just dst) = M.lookup "destination" hdrs 
            let (Just subId) = M.lookup "id" hdrs 
            client <- get
            let unSub = DoUnsubscribe (subId, sendPort client)
            lift $ lookupDestination dst >>= (\pid -> send pid unSub)
            modify (\cl -> cl { nUnSub = nUnSub client + 1 })
            void $ replyReceipt hdrs

          forwardMessage :: Action ClientState
          forwardMessage = do
            let (Just dst) = M.lookup "destination" hdrs 
            lift $ do
                self <- getSelfPid
                lookupDestination dst >>= (\pid -> send pid (GetSubscribees self))
                sps <- expect
                let msg = ServerFrame Message hdrs body
                -- todo: customize frame
                (mapM_ (\chan -> sendChan chan msg)) sps

lookupDestination :: Destination -> Process SubscriptionNodeId
lookupDestination dst = do
    getSelfPid >>= (\me -> nsend "stampede.router" (dst, me))
    expect

reply cmd hdrs body = liftM sendPort get >>= \chan -> lift (sendChan chan frm)
    where frm = ServerFrame cmd (M.fromList hdrs) body

replyReceipt hdrs = do
    let val = M.lookup "receipt" hdrs
    maybe (return False) (\rcpt -> reply Receipt [("receipt-id",rcpt)] "" >> return True) val

forwardClientOutputLoop :: Handle -> ReceivePort Frame -> Process ()
forwardClientOutputLoop h rp = go
    where go = do
            frm <- receiveChanTimeout 1000000 rp --encodes output heartbeat
            liftIO $ putStrLn $ "out >> " ++ show frm
            let buf = maybe "" dump frm
            liftIO $ B.hPut h buf
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
