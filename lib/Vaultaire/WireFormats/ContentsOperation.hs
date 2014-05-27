--
-- Data vault for metrics
--
--
-- Copyright © 2013-2014 Anchor Systems, Pty Ltd and Others
--
-- The code in this file, and the program it is a part of, is
-- made available to you by its authors as open source software:
-- you can redistribute it and/or modify it under the terms of
-- the BSD licence.
--

{-# LANGUAGE OverloadedStrings #-}
module Vaultaire.WireFormats.ContentsOperation
(
    ContentsOperation(..),
    SourceDict,
    module Vaultaire.WireFormats.Class
) where

import Control.Applicative ((<$>), (<*>))
import qualified Data.ByteString as S
import Data.Packer (getBytes, getWord64LE, putBytes, putWord64LE, runPacking,
                    tryUnpacking)
import Vaultaire.CoreTypes (Address (..))
import Vaultaire.WireFormats.Class
import Vaultaire.WireFormats.SourceDict (SourceDict)

data ContentsOperation = ContentsListRequest
                       | GenerateNewAddress
                       | UpdateSourceTag Address SourceDict
                       | RemoveSourceTag Address SourceDict
  deriving (Show, Eq)

instance WireFormat ContentsOperation where
    fromWire bs = flip tryUnpacking bs $ do
        header <- getWord64LE
        case header of
            0x0 -> return ContentsListRequest
            0x1 -> return GenerateNewAddress
            0x2 -> UpdateSourceTag <$> getAddr <*> getSourceDict
            0x3 -> RemoveSourceTag <$> getAddr <*> getSourceDict
            _   -> fail "Illegal op code"
      where
        getAddr = Address <$> getWord64LE
        getSourceDict = do
            len <- fromIntegral <$> getWord64LE
            fromWire <$> getBytes len >>= either (fail . show) return

    toWire op =
        case op of
            ContentsListRequest   -> "\x00\x00\x00\x00\x00\x00\x00\x00"
            GenerateNewAddress    -> "\x01\x00\x00\x00\x00\x00\x00\x00"
            UpdateSourceTag addr dict -> sourceOpToWire 0x2 addr dict
            RemoveSourceTag addr dict -> sourceOpToWire 0x3 addr dict
      where
        sourceOpToWire header (Address addr) dict =
            let dict_bytes = toWire dict in
            let dict_len = S.length dict_bytes in
            runPacking (24 + dict_len) $ do
                putWord64LE header
                putWord64LE addr
                putWord64LE (fromIntegral dict_len)
                putBytes dict_bytes
