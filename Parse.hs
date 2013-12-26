{-# LANGUAGE OverloadedStrings #-}

module Parse where

import Stomp
import Data.ByteString.Char8 (ByteString, pack)
import qualified Data.Attoparsec.ByteString.Char8 as C
import Data.Text (Text)
import Data.Text.Read (decimal)
import qualified Data.Attoparsec.Text as T
import qualified Data.Text.Encoding as T
import qualified Data.Attoparsec.Combinator as A
import Data.Attoparsec (Parser, parse, feed)
import Control.Applicative
import qualified Data.Map as M

type ChunkParser = C.Result [Frame]

type Header = (Key, Value)

stream :: Parser [Frame]
stream = A.many1 frame

frame :: Parser Frame
frame = do
    cmd <- command <* C.endOfLine
    headPairs <- many (header  <* C.endOfLine) <* C.endOfLine
    let headers = M.fromList (reverse headPairs) -- reverse because first item of duplicates should take precedence
    let cLength = findContentLength headers
    let body = maybe (simpleBody) (bodyWithLength) cLength
    dat <- body <* C.char '\0'
    many C.endOfLine
    let frm = either (clientFrame headers dat) (serverFrame headers dat) cmd
    return frm

findContentLength :: Headers -> Maybe Int
findContentLength headers = M.lookup "content-length" headers >>=
    either (const Nothing) (return . fst) . decimal

simpleBody :: Parser ByteString
simpleBody = C.takeWhile (/= '\0')

bodyWithLength :: Int -> Parser ByteString
bodyWithLength = C.take

command :: Parser (Either ClientCommand ServerCommand)
command = A.eitherP (C.try clientCommand) (C.try serverCommand)

clientCommand :: Parser ClientCommand
clientCommand = (C.string "SEND" >> return Send)
    <|> (C.string "SUBSCRIBE" >> return Subscribe)
    <|> (C.string "UNSUBSCRIBE" >> return Unsubscribe)
    <|> (C.string "BEGIN" >> return Begin)
    <|> (C.string "COMMIT" >> return Commit)
    <|> (C.string "ABORT" >> return Abort)
    <|> (C.string "ACK" >> return Ack)
    <|> (C.string "NACK" >> return Nack)
    <|> (C.string "DISCONNECT" >> return Disconnect)
    <|> (C.string "CONNECT" >> return Connect)
    <|> (C.string "STOMP" >> return Stomp)
    <|> fail "no such command"

serverCommand :: Parser ServerCommand
serverCommand = (C.string "CONNECTED" >> return Connected)
    <|> (C.string "MESSAGE" >> return Message)
    <|> (C.string "RECEIPT" >> return Receipt)
    <|> (C.string "ERROR" >> return Error)
    <|> fail "no such command"

header :: Parser Header
header = (,) <$> headerName <* C.char ':' <*> headerValue

notHeaderSep :: Char -> Bool
notHeaderSep c = (c /= ':') && (c /= '\r') && (c /= '\n')

headerName :: Parser Key
headerName = T.decodeUtf8 <$> C.takeWhile1 notHeaderSep

headerValue :: Parser Value
headerValue = T.decodeUtf8 <$> C.takeWhile notHeaderSep
