{-# LANGUAGE OverloadedStrings #-}

module Stampede.DServer where

import Network
import Control.Monad
import Control.Monad.State
import System.IO
import Data.ByteString as B
import Data.Map as M
import qualified Data.ByteString.Lazy as BL

import Stampede.Stomp
import Stampede.Parse
import Stampede.Dump
import Stampede.Helpers
import Data.Attoparsec (Parser, parse, feed, IResult (..))
import Data.Text (Text)
import Data.Text.Read (decimal)

import Control.Distributed.Process
import Data.Binary (Binary, encode, decode)
import Data.Typeable (Typeable)

type SktInfo = (Handle, HostName, PortNumber)

type SubscriptionId = Text
type Subscription = (SubscriptionId, SendPort Frame)
type SubscriptionRequest = (Destination, Subscription)
type Destination = Text

data RoutingTable = RoutingTable {
        table :: M.Map Destination SubscriptionNodeId
    }

type SubscriptionNodeId = ProcessId

data SubscriptionNode = SubscriptionNode {
        path            :: Destination
    ,   subscriptions   :: [Subscription]
    } 

data ClientState = ClientState {
        sktInfo     :: SktInfo
    ,   receivePort :: ReceivePort Frame
    ,   sendPort    :: SendPort Frame
    }

server :: PortNumber -> Process ()
server port = liftIO (withSocketsDo $ listenOn (PortNumber port)) >>= acceptLoop

matchState :: (Typeable a1, Binary a1) => b -> (a1 -> StateT b Process a) -> Match b
matchState state f = match f'
    where f' msg = execStateT (f msg) state 

-- Process that routes requests to a given node
router :: Process ()
router = do
    getSelfPid >>= register "stampede.router"
    go (RoutingTable $ M.fromList [])
    where go :: RoutingTable -> Process ()
          go state = do 
                newState <- receiveWait [ matchState state handleSubscription ]
                go newState

-- handle subscription by forwarding to the corresponding node
-- if node doesn't exists, spawn a new one and forward to it
handleSubscription :: SubscriptionRequest -> Action RoutingTable
handleSubscription (dst, sub) = do
    (RoutingTable rt) <- get
    let node = M.lookup dst rt
    maybe spawnAndForwardToNode forwardToNode node

    where spawnAndForwardToNode :: Action RoutingTable
          spawnAndForwardToNode = do
                pid <- lift $ spawnLocal $ subscriptionNode dst
                lift $ send pid sub
                modify (\(RoutingTable rt) -> (RoutingTable $ M.insert dst pid rt))

          forwardToNode :: SubscriptionNodeId -> Action RoutingTable
          forwardToNode pid = lift $ send pid sub

-- Process that stores state about who's subscribed to a given destination
subscriptionNode :: Destination -> Process ()
subscriptionNode dst = go (SubscriptionNode dst [])
    where go state = do 
               newState <- receiveWait []
               go newState

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
            liftIO $ print "receiving"
            frm <- receiveChanTimeout 1000000 rp --encodes input heartbeat
            liftIO $ print frm
            runStateT (react frm) st0 >>= go . snd

type Action a = StateT a Process ()

react :: (Maybe Frame) -> StateT ClientState Process ()
react Nothing                               = return ()
react (Just (ServerFrame _ _ _))            = error "should die disconnecting client"
react (Just (ClientFrame cmd hdrs body))    = handleCommand cmd hdrs body

handleCommand :: ClientCommand -> Headers -> Body -> Action ClientState
handleCommand cmd hdrs body = case cmd of
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

    where connectClient = sendFrame Connected (M.fromList [("version","1.0"),("heartbeat","0,0")]) ""
          subscribeClient = do
            let (Just dst) = M.lookup "destination" hdrs 
            client <- get
            -- todo spawn subscription
            --      ack if needed
            return ()
          unsubscribeClient = do
            let (Just dst)   = M.lookup "destination" hdrs
            let (Just subId) = (M.lookup "subscription" hdrs) >>= either (const Nothing) (return . fst) . decimal
            client <- get
            -- todo: ack if needed
            return ()
          forwardMessage = do
            let (Just dst) = M.lookup "destination" hdrs 
            let chans = [] :: [SendPort Frame]
            -- todo: lookup chans where to forward message
            (mapM_ (\chan -> lift $ sendChan chan $ ServerFrame Message hdrs body)) chans

sendFrame :: ServerCommand -> Headers -> Body -> Action ClientState
sendFrame cmd hdrs body = liftM sendPort get >>= \chan -> lift (sendChan chan frm)
    where frm = ServerFrame cmd hdrs body

forwardClientOutputLoop :: Handle -> ReceivePort Frame -> Process ()
forwardClientOutputLoop h rp = go
    where go = do
            liftIO $ print "waiting to send"
            frm <- receiveChanTimeout 1000000 rp --encodes output heartbeat
            liftIO $ print frm
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
