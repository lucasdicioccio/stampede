{-# LANGUAGE OverloadedStrings #-}

module Dump where

import Stomp
import Data.ByteString.Char8 (ByteString, pack)
import qualified Data.ByteString as C
import qualified Data.Text.Encoding as T
import Data.Monoid (mconcat)
import qualified Data.Map as M

dump :: Frame -> ByteString
dump (ClientFrame cmd hds body) = mconcat [dumpClientCommand cmd, "\n", dumpHeaders hds, "\n", body, "\0"]
dump (ServerFrame cmd hds body) = mconcat [dumpServerCommand cmd, "\n", dumpHeaders hds, "\n", body, "\0"]

dumpServerCommand :: ServerCommand -> ByteString
dumpServerCommand Connected = "CONNECTED"
dumpServerCommand Message = "MESSAGE"
dumpServerCommand Receipt = "RECEIPT"
dumpServerCommand Error = "ERROR"

dumpClientCommand :: ClientCommand -> ByteString
dumpClientCommand Connect = "CONNECT"
dumpClientCommand Send = "SEND"
dumpClientCommand Subscribe = "SUBSCRIBE"
dumpClientCommand Unsubscribe = "UNSUBSCRIBE"
dumpClientCommand Begin = "BEGIN"
dumpClientCommand Commit = "COMMIT"
dumpClientCommand Abort = "ABORT"
dumpClientCommand Ack = "ACK"
dumpClientCommand Nack = "NACK"
dumpClientCommand Disconnect = "DISCONNECT"
dumpClientCommand Stomp = "STOMP"

dumpHeaders :: Headers -> ByteString
dumpHeaders = mconcat . map dumpPair . M.toList

dumpPair :: (Key, Value) -> ByteString
dumpPair (k, v) = mconcat [T.encodeUtf8 k, ":", T.encodeUtf8 v, "\n"]
