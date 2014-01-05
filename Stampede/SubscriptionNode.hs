
module Stampede.SubscriptionNode where

import Control.Distributed.Process
import Stampede.Types
import Stampede.Utils
import Control.Monad.State
import Control.Monad
import Data.List (delete)

-- Process that stores state about who is subscribed to a given destination
subscriptionNode :: Destination -> Process ()
subscriptionNode dst = do
    go (SubscriptionNode dst [])
    where go state = do 
               newState <- receiveWait [ matchState state handleSubscriptionNodeQuery
                                       , matchState state handleSubscriptionNodeCommand
                                       ]
               go newState

handleSubscriptionNodeQuery :: SubscriptionNodeQuery -> Action SubscriptionNode
handleSubscriptionNodeQuery (DoSubscribe sub)     = modify (\subNode -> subNode { subscriptions = sub:(subscriptions subNode) })
handleSubscriptionNodeQuery (DoUnsubscribe sub)   = modify (\subNode -> subNode { subscriptions = delete sub (subscriptions subNode) })

handleSubscriptionNodeCommand :: SubscriptionNodeCommand -> Action SubscriptionNode
handleSubscriptionNodeCommand (GetSubscribees req) = do
    sps <- liftM (map snd . subscriptions) get
    lift $ send req sps

