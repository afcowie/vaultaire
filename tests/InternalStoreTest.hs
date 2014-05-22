{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections     #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

module Main where

import Control.Applicative
import Control.Monad
import Control.Monad.State.Strict
import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as BS
import Data.Locator
import Pipes.Parse
import Test.Hspec
import Test.Hspec.QuickCheck
import Test.QuickCheck
import Test.QuickCheck.Monadic (assert, monadicIO, run)
import TestHelpers
import Vaultaire.CoreTypes
import Vaultaire.Daemon
import Vaultaire.InternalStore (enumerateOrigin, readFrom, writeTo)

instance Arbitrary ByteString where
    arbitrary = BS.pack <$> arbitrary

instance Arbitrary Origin where
    -- suchThat condition should be removed once locators package is fixed
    arbitrary = Origin . BS.pack . toLocator16a 6 <$> arbitrary `suchThat` (>0)

instance Arbitrary Address where
    arbitrary = Address <$> arbitrary

main :: IO ()
main = hspec suite

suite :: Spec
suite = do
    describe "writing" $ do
        it "writes simple bucket correctly" $ do
            runTestDaemon "tcp://localhost:1234" $ writeTo (Origin "PONY") (Address 4) "Hai"
            readObject "02_PONY_INTERNAL_00000000000000000004_00000000000000000000_simple"
            >>= (`shouldBe` Right "\x04\x00\x00\x00\x00\x00\x00\x00\
                                  \\x00\x00\x00\x00\x00\x00\x00\x00\
                                  \\x00\x00\x00\x00\x00\x00\x00\x00")

        it "writes extended bucket correctly" $ do
            runTestDaemon "tcp://localhost:1234" $ writeTo (Origin "PONY") (Address 4) "Hai"
            readObject "02_PONY_INTERNAL_00000000000000000004_00000000000000000000_extended"
            >>= (`shouldBe` Right "\x03\x00\x00\x00\x00\x00\x00\x00\&Hai")

    describe "reading" $
        it "reads a write" $ -- Use the same write, as we have already shown it correct
            runTestDaemon "tcp://localhost:1234"
                (do writeTo (Origin "PONY") (Address 4) "Hai"
                    readFrom (Origin "PONY") (Address 4))
            >>= (`shouldBe` Just "Hai")

    describe "enumeration" $
        it "enumerates two writes" $ do
            addrs <- runTestDaemon "tcp://localhost:1234" $ do
                writeTo (Origin "PONY") (Address 128) "Hai1"
                writeTo (Origin "PONY") (Address 0) "Hai2"
                writeTo (Origin "PONY") (Address 128) "Hai3" -- overwrite

                evalStateT drawAll (enumerateOrigin "PONY")
            addrs `shouldBe` [(Address 0, "Hai2"), (Address 128, "Hai3")]

    describe "identity QuickCheck" $
        it "writes then reads" $ property propWriteThenRead

propWriteThenRead :: (Origin, Address, ByteString) -> Property
propWriteThenRead arb@(_,_,payload) = monadicIO $ do
    (enumeration, read') <- run $ runTestDaemon "tcp://localhost:1234" $ writeThenRead arb
    assert $ (enumeration == read') && (read' == payload)

writeThenRead :: (Origin, Address, ByteString) -> Daemon (ByteString, ByteString)
writeThenRead (o,a,p) = do
        writeTo o a p
        [(a', e)] <- evalStateT drawAll (enumerateOrigin o)
        unless (a' == a) $ error "invalid address from enumeration"
        r <- readFrom o a >>= maybe (error "no value") return
        return (e,r)
