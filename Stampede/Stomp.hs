{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric #-}

module Stampede.Stomp where

import Control.Monad
import Data.Map (Map)
import Data.Text (Text)
import Data.Text.Encoding (decodeUtf16LE,encodeUtf16LE)
import Data.ByteString (ByteString)
import GHC.Generics
import Data.Typeable
import Data.Binary

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
    deriving (Show, Generic, Typeable)

data ServerCommand = Connected
    | Message
    | Receipt
    | Error
    deriving (Show, Generic, Typeable)

data Frame = ClientFrame ClientCommand Headers Body
    | ServerFrame ServerCommand Headers Body
    deriving (Show, Generic, Typeable)

instance Binary ClientCommand where
instance Binary ServerCommand where
instance Binary Text where
    get = liftM decodeUtf16LE get 
    put = put . encodeUtf16LE
instance Binary Frame where

clientFrame hs body x = ClientFrame x hs body
serverFrame hs body x = ServerFrame x hs body
