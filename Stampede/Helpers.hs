{-# LANGUAGE OverloadedStrings #-}
module Stampede.Helpers where

import Stampede.Stomp
import qualified Data.Map as M
import Control.Monad (liftM)
import Data.Text (Text)
import Data.Text.Read (decimal)

isClientFrame :: Frame -> Bool
isClientFrame (ClientFrame _ _ _) = True
isClientFrame _                   = False

isServerFrame :: Frame -> Bool
isServerFrame (ServerFrame _ _ _) = True
isServerFrame _                   = False

headers :: Frame -> Headers
headers (ClientFrame _ h _) = h
headers (ServerFrame _ h _) = h

body :: Frame -> Body
body (ClientFrame _ _ b) = b
body (ServerFrame _ _ b) = b

readHeader :: (Value -> b) -> Key -> Frame -> Maybe b
readHeader f k frm = liftM f (M.lookup k (headers frm))

contentLength :: Frame -> Maybe Int
contentLength frm = readHeader decimal "content-length" frm >>= either (const Nothing) (return . fst)

contentType :: Frame -> Maybe Text
contentType = readHeader id "content-type"

receipt :: Frame -> Maybe Text
receipt = readHeader id "receipt"

acceptVersion :: Frame -> Maybe Text
acceptVersion = readHeader id "accept-version" -- todo parse list

host :: Frame -> Maybe Text
host = readHeader id "host"

login :: Frame -> Maybe Text
login = readHeader id "login"

password :: Frame -> Maybe Text
password = readHeader id "password"

heartBeat :: Frame -> Maybe Text
heartBeat = readHeader id "heart-beat"  -- todo parse min/max

version :: Frame -> Maybe Text
version = readHeader id "version" -- todo parse list

destination :: Frame -> Maybe Text
destination = readHeader id "destination"

transaction :: Frame -> Maybe Text
transaction = readHeader id "transaction"

ack :: Frame -> Maybe Text
ack = readHeader id "ack"

_id :: Frame -> Maybe Text
_id = readHeader id "_id"

messageId :: Frame -> Maybe Text
messageId = readHeader id "message-id"

receiptId :: Frame -> Maybe Text
receiptId = readHeader id "receipt-id"

message :: Frame -> Maybe Text
message = readHeader id "message"
