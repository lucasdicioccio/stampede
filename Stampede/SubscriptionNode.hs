
module Stampede.SubscriptionNode where

import Control.Distributed.Process
import Stampede.Types
import Stampede.Utils
import Control.Monad.State
import Control.Monad

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

