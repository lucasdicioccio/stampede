{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE OverloadedStrings #-}

module Stampede.DServer where

import Network
import Control.Monad
import Control.Monad.State
import System.IO
import qualified Data.ByteString as B
import qualified Data.Map as M
import qualified Data.ByteString.Lazy as BL

import Stampede.Stomp
import Stampede.Parse
import Stampede.Dump
import Stampede.Helpers
import Data.Attoparsec (Parser, parse, feed, IResult (..))
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Read (decimal)
import Data.Text.Binary

import Control.Distributed.Process
import Data.Binary (Binary, encode, decode)
import Data.Typeable (Typeable)

import GHC.Generics

type SktInfo = (Handle, HostName, PortNumber)

type SubscriptionId = Text
type Subscription = (SubscriptionId, SendPort Frame)
type Destination = Text

data RoutingTable = RoutingTable {
        table :: M.Map Destination SubscriptionNodeId
    }

type SubscriptionNodeId = ProcessId

data SubscriptionNode = SubscriptionNode {
        path            :: Destination
    ,   subscriptions   :: [Subscription]
    } 

type Requester = ProcessId
data SubscriptionNodeCommand = GetSubscribees Requester
    deriving (Show, Eq, Typeable, Generic)

instance Binary SubscriptionNodeCommand

data ClientState = ClientState {
        sktInfo     :: SktInfo
    ,   receivePort :: ReceivePort Frame
    ,   sendPort    :: SendPort Frame
    ,   nSub        :: Int
    }

server :: PortNumber -> Process ()
server port = do
    spawnLocal router
    liftIO (withSocketsDo $ listenOn (PortNumber port)) >>= acceptLoop

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

-- Process that stores state about who is subscribed to a given destination
subscriptionNode :: Destination -> Process ()
subscriptionNode dst = do
    go (SubscriptionNode dst [])
    where go state = do 
               newState <- receiveWait [ matchState state handleSubscription
                                       , matchState state handleSubscriptionNodeCommand
                                       ]
               go newState

handleSubscription :: Subscription -> Action SubscriptionNode
handleSubscription sub = do
    modify (\subNode -> subNode { subscriptions = sub:(subscriptions subNode) })

handleSubscriptionNodeCommand :: SubscriptionNodeCommand -> Action SubscriptionNode
handleSubscriptionNodeCommand (GetSubscribees req) = do
    sps <- liftM (map snd . subscriptions) get
    lift $ send req sps

acceptLoop :: Socket -> Process ()
acceptLoop skt = go
    where go = do
            infos@(h,addr,port) <- liftIO $ accept skt
            liftIO $ hSetBuffering h NoBuffering
            clientPid <- spawnLocal $ clientProcess infos
            go

client :: SktInfo -> ReceivePort Frame -> SendPort Frame -> ClientState
client skt rp sp = ClientState skt rp sp 0

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

    where connectClient :: Action ClientState
          connectClient = reply Connected [("version","1.0"), ("heart-beat","0,0")] ""

          subscribeClient :: Action ClientState
          subscribeClient = do
            let (Just dst) = M.lookup "destination" hdrs 
            client <- get
            let subId = T.pack . show $ nSub client
            let sub = (subId, sendPort client) :: Subscription
            lift $ lookupDestination dst >>= (\pid -> send pid sub)
            modify (\cl -> cl { nSub = nSub client + 1 })
            --      ack if needed
            return ()

          unsubscribeClient :: Action ClientState
          unsubscribeClient = do
            -- todo: unsubscribe and ack if needed
            return ()

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

forwardClientOutputLoop :: Handle -> ReceivePort Frame -> Process ()
forwardClientOutputLoop h rp = go
    where go = do
            frm <- receiveChanTimeout 1000000 rp --encodes output heartbeat
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
