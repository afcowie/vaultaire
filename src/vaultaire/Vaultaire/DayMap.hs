module Vaultaire.DayMap
(
    DayMap,
    NoBuckets,
    Epoch,
    Time,
    lookupEpoch,
    lookupNoBuckets,
    loadDayMap
) where

import Data.Word(Word64)
import Data.Map (Map)
import qualified Data.Map as Map
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import Control.Applicative
import Data.Packer

type Epoch = Word64
type NoBuckets = Word64

type Time = Word64
type DayMap = Map Epoch NoBuckets

lookupEpoch :: DayMap -> Time -> Epoch
lookupEpoch = undefined

lookupNoBuckets :: DayMap -> Time -> NoBuckets
lookupNoBuckets = undefined

loadDayMap :: ByteString -> Either String DayMap
loadDayMap bs
    | BS.length bs `rem` 16 /= 0 = Left "corrupt"
    | otherwise = Right $ mustLoadDayMap bs

mustLoadDayMap :: ByteString -> DayMap
mustLoadDayMap =
    Map.fromList . runUnpacking (many ((,) <$> getWord64LE <*> getWord64LE))
