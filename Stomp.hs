module Stomp where

import Data.Map (Map)
import Data.Text (Text)
import Data.ByteString (ByteString)

type Key = Text
type Value = Text
type Headers = Map Key Value
type Body = ByteString

data ClientCommand = Connect 
    | Send
    | Subscribe
    | Unsubscribe
    | Begin
    | Commit
    | Abort
    | Ack
    | Nack
    | Disconnect
    | Stomp
    deriving (Show)

data ServerCommand = Connected
    | Message
    | Receipt
    | Error
    deriving (Show)

data Frame = ClientFrame ClientCommand Headers Body
    | ServerFrame ServerCommand Headers Body
    deriving (Show)

clientFrame hs body x = ClientFrame x hs body
serverFrame hs body x = ServerFrame x hs body
