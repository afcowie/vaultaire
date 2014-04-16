{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE RecordWildCards       #-}

module Vaultaire.Writer
(
    startWriter,
    -- Testing
    processEvents,
    processPoints,
    appendExtended,
    appendSimple,
    batchStateNow,
    BatchState(..),
    Event(..),
) where

import Control.Applicative
import Control.Concurrent (threadDelay)
import qualified Control.Concurrent.Async as Async
import Control.Concurrent.STM
import Control.Monad
import Control.Monad.State.Strict
import Data.Bits
import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as BS
import Data.ByteString.Lazy (toStrict)
import Data.ByteString.Lazy.Builder
import Data.HashMap.Strict (HashMap)
import qualified Data.HashMap.Strict as HashMap
import Data.Monoid
import Data.Packer
import Data.Time
import Data.Traversable (for)
import Data.Word (Word64)
import Pipes hiding (for)
import Pipes.Concurrent
import Pipes.Lift
import System.Rados.Monadic hiding (async)
import Text.Printf
import Vaultaire.Daemon
import Vaultaire.DayMap
import Vaultaire.OriginMap
import Vaultaire.RollOver

type Address = Word64
type Payload = Word64
type Bucket  = Word64

type DispatchMap = OriginMap (Output Event)

type EpochMap = HashMap Epoch
type BucketMap = HashMap Bucket

data BatchState = BatchState
    { replyFs  :: [Response -> Daemon ()]
    , normal   :: EpochMap (BucketMap Builder)
    , extended :: EpochMap (BucketMap Builder)
    , pending  :: EpochMap (BucketMap (Word64, [Word64 -> Builder]))
    , dayMaps  :: (DayMap, DayMap) -- Simple, extended
    , start    :: UTCTime
    }

data Event = Msg Message | Tick

-- | Start a writer daemon, never returns.
startWriter :: String           -- ^ Broker
            -> Maybe ByteString -- ^ Username for Ceph
            -> ByteString       -- ^ Pool name for Ceph
            -> NominalDiffTime
            -> IO ()
startWriter broker user pool batch_period = runDaemon broker user pool $ do
    runEffect $ lift nextMessage
             >~ evalStateP emptyOriginMap (dispatch batch_period)
    error "startWriter: impossible"

-- If the incoming message currently has a processing thread running for that
-- origin, feed the message into that thread. Otherwise create a new one and
-- feed it in.
dispatch :: NominalDiffTime
         -> Consumer Message (StateT DispatchMap Daemon) ()
dispatch batch_period = do
    m@(Message _ origin' _) <- await
    let event = Msg m
    dispatch_map <- get
    case originLookup origin' dispatch_map of
        Just output -> do
            sent <- send' output event
            -- If it wasn't sent, the thread has shut itself down.
            if sent
                then startThread origin' dispatch_map event
                else dispatch batch_period
        Nothing   -> startThread origin' dispatch_map event
  where
    send' o = liftIO . atomically . send o

    startThread origin' dispatch_map m = do
        (output, seal, input) <- liftIO $ spawn' Single

        liftIO $ Async.async $ feedTicks output

        lift . lift $
            async (processBatch batch_period origin' seal input)
            >>= liftIO . Async.link

        must_send <- send' output m
        unless must_send $ error "thread died immediately, bailing"
        lift . put $ originInsert origin' output dispatch_map
        dispatch batch_period

batchStateNow :: (DayMap, DayMap) -> IO BatchState
batchStateNow dms =
    BatchState mempty mempty mempty mempty dms <$> getCurrentTime

-- | The dispatcher has done the hard work for us and sorted incoming bursts by
-- origin. Now we simply need to process these messages with local state,
-- writing to ceph when our collection time has elapsed.
processBatch :: NominalDiffTime -> Origin -> Input Event -> STM () -> Daemon ()
processBatch batch_period origin' input seal = do
    refreshOriginDays origin'
    simple_dm <- withSimpleDayMap origin' id
    extended_dm  <- withExtendedDayMap origin' id
    case (,) <$> simple_dm <*> extended_dm of
        Nothing ->
            -- Reply to first message with an error, try again on the next
            -- message. This is a potential DOS of sorts, however is needed
            -- unless we know when to expire
            runEffect $ fromInput input >-> badOrigin
        Just dms -> do
            -- Process for a batch period
            start_state <- liftIO $ batchStateNow dms
            runEffect $ fromInput input
                    >-> evalStateP start_state (processEvents batch_period)
                    >-> write origin'
            liftIO $ atomically seal

badOrigin :: Consumer Event Daemon ()
badOrigin = do
    event <- await
    case event of
        Msg (Message reply_f _ _) ->
            lift $ reply_f $ Failure "No such origin"
        Tick -> badOrigin

feedTicks :: Output Event -> IO ()
feedTicks o = runEffect $ tickStream >-> toOutput o
  where tickStream = forever $ lift (threadDelay tickRate) >> yield Tick
        tickRate   = 10000000 `div` 100 -- 100ms

-- | Place a message into state or flush if appropriate.
processEvents :: (MonadState BatchState m, MonadIO m)
               => NominalDiffTime -> Pipe Event BatchState m ()
processEvents batch_period = do
    event <- await
    s <- get
    case event of
        Msg (Message rf origin' payload') -> do
            -- Most messages simply need to be placed into the correct epoch and
            -- bucket, extended ones are a little more complex in that they have to be
            -- stored as an offset to a pending write to the extended buckets.
            -- Append the replyf for this message
            put s{replyFs = rf:replyFs s}

            lift $ processPoints 0 payload' (dayMaps s) origin'

            processEvents batch_period
        Tick -> do
            now <- liftIO getCurrentTime
            if batch_period `addUTCTime` start s < now
                then get >>= yield
                else processEvents batch_period

processPoints :: MonadState BatchState m
              => Word64 -> ByteString -> (DayMap, DayMap) -> Origin -> m ()
processPoints offset message day_maps origin
    | fromIntegral offset >= BS.length message = return ()
    | otherwise = do
        let (address, time, payload) = runUnpacking (parseMessageAt offset) message
        let (simple_epoch, simple_buckets) = lookupBoth time (fst day_maps)

        let masked_address = address `clearBit` 0
        let simple_bucket = masked_address `mod` simple_buckets

        -- The LSB of the address lets us know if it is an extended message or
        -- not. Set means extended.
        if address `testBit` 0
            then do
                let len = fromIntegral payload
                let str = runUnpacking (getBytesAt (offset + 24) len) message
                let (ext_epoch, ext_buckets) = lookupBoth time (fst day_maps)
                let ext_bucket = masked_address `mod` ext_buckets
                appendExtended ext_epoch ext_bucket address time len str
                processPoints (offset + 24 + len) message day_maps origin
            else do
                let message_bytes = runUnpacking (getBytesAt offset 24) message
                appendSimple simple_epoch simple_bucket message_bytes
                processPoints (offset + 24) message day_maps origin

parseMessageAt :: Word64 -> Unpacking (Address, Time, Payload)
parseMessageAt offset = do
    unpackSetPosition (fromIntegral offset)
    (,,) <$> getWord64LE <*> getWord64LE <*> getWord64LE

getBytesAt :: Word64 -> Word64 -> Unpacking ByteString
getBytesAt offset len = do
    unpackSetPosition (fromIntegral offset)
    getBytes (fromIntegral len)

-- | This one is pretty simple, simply append to the builder within the bucket
-- map, which is within an epoch map itself. Yes, this is two map lookups per
-- insert.
appendSimple :: MonadState BatchState m
             => Epoch -> Bucket -> ByteString -> m ()
appendSimple epoch bucket bytes = do
    s <- get
    let builder = byteString bytes
    let simple_map = HashMap.lookupDefault HashMap.empty epoch (normal s)
    let simple_map' = HashMap.insertWith (flip (<>)) bucket builder simple_map
    let normal' = HashMap.insert epoch simple_map' (normal s)
    put $ s { normal = normal' }

appendExtended :: MonadState BatchState m
               => Epoch -> Bucket -> Address -> Time -> Word64 -> ByteString -> m ()
appendExtended epoch bucket address time len string = do
    s <- get

    -- First we write to the simple bucket, inserting a closure that will
    -- return a builder given an offset of the extended bucket write.
    let pending_map = HashMap.lookupDefault HashMap.empty epoch (pending s)

    -- Starting from zero, we write to the current offset and point the next
    -- extended point to the end of that write.
    let (os, fs) = HashMap.lookupDefault (0, []) bucket pending_map
    let os' = os + len

    -- Create the closure for the pointer to the extended bucket
    let prefix = word64LE address <> word64LE time
    let fs' = (\base_offset -> prefix <> word64LE (base_offset + os)):fs

    -- Update the bucket,
    let pending_map' = HashMap.insert bucket (os', fs') pending_map
    let pending' = HashMap.insert epoch pending_map' (pending s)

    -- Now the data goes into the extended bucket.
    let builder = word64LE len <> byteString string
    let ext_map= HashMap.lookupDefault HashMap.empty epoch (extended s)
    let ext_map' = HashMap.insertWith (flip (<>)) bucket builder ext_map
    let extended' = HashMap.insert epoch ext_map' (extended s)

    put $ s { pending = pending', extended = extended' }

-- | Write happens in three stages:
--   1. Extended buckets are written to disk and the offset is noted.
--   2. Simple buckets are written to disk with the pending writes applied.
--   3. Acks are sent
--   4. Any rollovers are done
write :: Origin -> Consumer BatchState Daemon ()
write origin' = do
    s <- await
    (offsets, extended_rollover) <- stepOne s
    simple_buckets  <- applyOffsets offsets s
    simple_rollover <- stepTwo simple_buckets
    -- Send the acks
    lift $ mapM_ ($ Success) (replyFs s)
    when simple_rollover (lift $ rollOverSimpleDay origin')
    when extended_rollover (lift $ rollOverExtendedDay origin')
  where
    -- 1. Write extended buckets. We lock the entire origin for write as we
    -- will be operating on most buckets most of the time.
    stepOne s =
        lift . withExLock (writeLockOID origin') $ liftPool $ do
            -- First pass to get current offsets
            offsets <- forWithKey (extended s) $ \epoch buckets -> do

                -- Make requests for the entire epoch
                stats <- forWithKey buckets $ \bucket _ ->
                    extendedOffset origin' epoch bucket

                -- Then extract the fileSize from those requests
                for stats $ \async_stat -> do
                    result <- look async_stat
                    case result of
                        Left (NoEntity{..}) ->
                            return 0
                        Left e ->
                            error $ "extended bucket read: " ++ show e
                        Right st ->
                            return $ fileSize st

            -- Second pass to write the extended data
            _ <- forWithKey (extended s) $ \epoch buckets -> do
                writes <- forWithKey buckets $ \bucket builder -> do
                    let payload = toStrict $ toLazyByteString builder
                    writeExtended origin' epoch bucket payload
                for writes $ \async_write -> do
                    result <- waitSafe async_write
                    case result of
                        Just e -> error $ "extended bucket write: " ++ show e
                        Nothing -> return ()

            -- TODO: Update max

            return (offsets, findMax offsets > bucketSize)

    -- Given two maps, one of offsets and one of closures, we walk through
    -- applying one to the other. We then append that to the map of simple
    -- writes in order to achieve one write.
    applyOffsets offset_map s = lift $ liftPool $
        forWithKey (normal s) $ \epoch buckets -> do
            let pending_buckets = HashMap.lookup epoch (pending s)
            let offset_buckets  = HashMap.lookup epoch offset_map
            forWithKey buckets $ \bucket builder -> do
                let pendings = pending_buckets >>= HashMap.lookup bucket
                let offsets  = offset_buckets >>= HashMap.lookup bucket
                case pendings of
                    -- No associated extended points, just simple points
                    Nothing -> return builder
                    -- Otherwise apply the offsets and concatenate
                    Just fs -> return $ case offsets of
                        Nothing -> error "No offset for extended point!"
                        Just os ->
                            let ext = mconcat $ reverse $ map ($os) (snd fs)
                            in builder <> ext

    -- Final write,
    stepTwo simple_buckets = lift $ liftPool $ do
        offsets <- forWithKey simple_buckets $ \epoch buckets -> do
            writes <- forWithKey buckets $ \bucket builder -> do
                let payload = toStrict $ toLazyByteString builder
                writeSimple origin' epoch bucket payload
            for writes $ \(async_stat, async_write) -> do
                w <- waitSafe async_write
                case w of
                    Just e -> error $ "simple bucket write: " ++ show e
                    Nothing -> do
                        r <- look async_stat
                        case r of
                            Left NoEntity{} -> return 0
                            Left e   -> error $ "simple bucket read" ++ show e
                            Right st -> return $ fileSize st
        return $ findMax offsets > bucketSize

    forWithKey = flip HashMap.traverseWithKey
    findMax = HashMap.foldr max 0 . HashMap.map (HashMap.foldr max 0)

bucketSize :: Word64
bucketSize = 4194304

extendedOffset :: Origin -> Epoch -> Bucket -> Pool (AsyncRead StatResult)
extendedOffset o e b =
    runAsync $ runObject (bucketOID o e b "extended") stat

writeExtended :: Origin -> Epoch -> Bucket -> ByteString -> Pool AsyncWrite
writeExtended o e b payload =
    runAsync $ runObject (bucketOID o e b "extended") (append payload)

writeSimple :: Origin -> Epoch -> Bucket -> ByteString -> Pool (AsyncRead StatResult, AsyncWrite)
writeSimple o e b payload=
    runAsync $ runObject (bucketOID o e b "simple") $
        (,) <$> stat <*> writeFull payload

writeLockOID :: Origin -> ByteString
writeLockOID o = "02_" `BS.append` o `BS.append` "_write_lock"

bucketOID :: Origin -> Epoch -> Bucket -> String -> ByteString
bucketOID origin epoch bucket kind = BS.pack $ printf "02_%s_%020d_%020d_%s"
                                                      (BS.unpack origin)
                                                      bucket
                                                      epoch
                                                      kind
