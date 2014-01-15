{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DeriveDataTypeable #-}

module Stampede.Types where

import Stampede.Stomp
import GHC.Generics
import Control.Distributed.Process
import Data.Binary (Binary, encode, decode)
import Data.Typeable (Typeable)
import Data.Text.Binary
import Data.Map (Map)
import Data.Text (Text)
import Network (PortNumber, HostName)
import Control.Monad.State (StateT)
import System.IO (Handle)

type Action a = StateT a Process ()

type SktInfo = (Handle, HostName, PortNumber)

type SubscriptionId = Text
type Subscription = (SubscriptionId, SendPort Frame)
type Destination = Text
type TransactionId = Text

data AckMode = Auto | Cumulative | Selective
    deriving (Show, Eq, Typeable, Generic)
instance Binary AckMode

data RoutingTable = RoutingTable {
        table :: Map Destination SubscriptionNodeId
    }

type SubscriptionNodeId = ProcessId

data SubscriptionNode = SubscriptionNode {
        path            :: Destination
    ,   subscriptions   :: [Subscription] -- todo: change representation (e.g., a Set)
    } 

data TransactionNode = SubscriptionNode {
        txId            :: TransactionId -- todo: add fields about acked/unacked message/ids, transaction configuration mode etc.
    } 

type Requester = ProcessId
data SubscriptionNodeCommand = GetSubscribees Requester
    deriving (Show, Eq, Typeable, Generic)
instance Binary SubscriptionNodeCommand

data SubscriptionNodeQuery = DoSubscribe AckMode Subscription
    | DoUnsubscribe Subscription
    deriving (Show, Eq, Typeable, Generic)
instance Binary SubscriptionNodeQuery

data ClientState = ClientState {
        sktInfo     :: SktInfo
    ,   receivePort :: ReceivePort Frame
    ,   sendPort    :: SendPort Frame
    ,   nSub        :: Int
    ,   nUnSub      :: Int
    }

client :: SktInfo -> ReceivePort Frame -> SendPort Frame -> ClientState
client skt rp sp = ClientState skt rp sp 0 0
