{-# LANGUAGE DataKinds #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Test.Compilation.UInt.Multiplication (tests, run) where

import Control.Monad
import Data.Word
import Keelung hiding (compile)
import Test.Hspec
import Test.QuickCheck hiding ((.&.))
import Test.Util

run :: IO ()
run = hspec tests

--------------------------------------------------------------------------------

tests :: SpecWith ()
tests = describe "Multiplication" $ do
  describe "Single-width" $ do
    it "2 constants / Byte" $ do
      let program x y = return $ x * (y :: UInt 8)
      property $ \(x, y :: Word8) -> do
        let expected = [toInteger (x * y)]
        forM_ [gf181, Prime 17, Binary 7] $ \field -> check field (program (fromIntegral x) (fromIntegral y)) [] [] expected

    it "2 positive variables / Byte" $ do
      let program = do
            x <- input Public :: Comp (UInt 8)
            y <- input Public
            return $ x * y
      property $ \(x, y :: Word8) -> do
        let expected = [toInteger (x * y)]
        forM_ [gf181, Prime 17, Binary 7] $ \field -> check field program (map toInteger [x, y]) [] expected

    it "1 constant + 1 variable / Byte" $ do
      let program x = do
            y <- input Public :: Comp (UInt 8)
            return $ x * y
      property $ \(x, y :: Word8) -> do
        let expected = [toInteger (x * y)]
        forM_ [gf181, Prime 17, Binary 7] $ \field -> check field (program (fromIntegral x)) [toInteger y] [] expected

    it "1 variable + 1 constant / Byte" $ do
      let program y = do
            x <- input Public :: Comp (UInt 8)
            return $ x * y
      property $ \(x, y :: Word8) -> do
        let expected = [toInteger (x * y)]
        forM_ [gf181, Prime 17, Binary 7] $ \field -> check field (program (fromIntegral y)) [toInteger x] [] expected

    it "with addition / Byte" $ do
      let program = do
            x <- input Public :: Comp (UInt 8)
            y <- input Public
            z <- input Public
            return $ x * y + z
      property $ \(x, y, z :: Word8) -> do
        let expected = [toInteger (x * y + z)]
        forM_ [gf181, Prime 257, Prime 17, Binary 7] $ \field -> check field program (map toInteger [x, y, z]) [] expected

    it "with subtraction / Byte" $ do
      let program = do
            x <- input Public :: Comp (UInt 8)
            y <- input Public
            z <- input Public
            return $ x * y - z
      property $ \(x, y, z :: Word8) -> do
        let expected = [toInteger (x * y - z)]
        forM_ [gf181, Prime 257, Prime 17, Binary 7] $ \field -> check field program (map toInteger [x, y, z]) [] expected
  describe "Double-width" $ do
    it "2 constants / Byte -> UInt 16" $ do
      let program x y = return $ x `mulD` (y :: UInt 8)
      property $ \(x :: Word8, y :: Word8) -> do
        let expected = [(toInteger x * toInteger y) `mod` 65536]
        forM_ [gf181, Prime 17, Binary 7] $ \field -> check field (program (fromIntegral x) (fromIntegral y)) [] [] expected

    it "2 positive variables / Byte -> UInt 16" $ do
      let program = do
            x <- input Public :: Comp (UInt 8)
            y <- input Public
            return $ x `mulD` y

      property $ \(x, y :: Word8) -> do
        let expected = [(toInteger x * toInteger y) `mod` 65536]
        forM_ [gf181, Prime 4099, Binary 7] $ \field ->
          check field program (map toInteger [x, y]) [] expected

    it "1 constant + 1 variable / Byte -> UInt 16" $ do
      let program x = do
            y <- input Public :: Comp (UInt 8)
            return $ x `mulD` y
      property $ \(x :: Word8, y :: Word8) -> do
        let expected = [(toInteger x * toInteger y) `mod` 65536]
        check gf181 (program (fromIntegral x)) [toInteger y] [] expected
        check (Prime 17) (program (fromIntegral x)) [toInteger y] [] expected
        check (Binary 7) (program (fromIntegral x)) [toInteger y] [] expected

    it "with addition / Byte -> UInt 16" $ do
      let program = do
            x <- input Public :: Comp (UInt 8)
            y <- input Public
            z <- input Public
            return $ x `mulD` y + z
      property $ \(x, y, z :: Word8) -> do
        let expected = [(toInteger x * toInteger y + toInteger z) `mod` 65536]
        forM_ [gf181, Prime 257, Prime 17, Binary 7] $ \field -> check field program (map toInteger [x, y, z]) [] expected

    it "with subtraction / Byte -> UInt 16" $ do
      let program = do
            x <- input Public :: Comp (UInt 8)
            y <- input Public
            z <- input Public
            return $ x `mulD` y - z
      property $ \(x, y, z :: Word8) -> do
        let expected = [(toInteger x * toInteger y - toInteger z) `mod` 65536]
        forM_ [gf181, Prime 257, Prime 17, Binary 7] $ \field -> check field program (map toInteger [x, y, z]) [] expected

  describe "Variable-width" $ do
    it "2 constants / Byte -> UInt 6" $ do
      let program x y = return $ x `mulV` (y :: UInt 8) :: Comp (UInt 6)
      property $ \(x :: Word8, y :: Word8) -> do
        let expected = [(toInteger x * toInteger y) `mod` 64]
        forM_ [gf181, Prime 17, Binary 7] $ \field -> check field (program (fromIntegral x) (fromIntegral y)) [] [] expected

    it "2 constants / Byte -> UInt 10" $ do
      let program x y = return $ x `mulV` (y :: UInt 8) :: Comp (UInt 10)
      property $ \(x :: Word8, y :: Word8) -> do
        let expected = [(toInteger x * toInteger y) `mod` 1024]
        forM_ [gf181, Prime 17, Binary 7] $ \field -> check field (program (fromIntegral x) (fromIntegral y)) [] [] expected

    it "2 positive variables / Byte -> UInt 6" $ do
      let program = do
            x <- input Public :: Comp (UInt 8)
            y <- input Public
            return $ x `mulV` y :: Comp (UInt 6)

      property $ \(x, y :: Word8) -> do
        let expected = [(toInteger x * toInteger y) `mod` 64]
        forM_ [gf181, Prime 17, Binary 7] $ \field ->
          check field program (map toInteger [x, y]) [] expected

    it "2 positive variables / Byte -> UInt 10" $ do
      let program = do
            x <- input Public :: Comp (UInt 8)
            y <- input Public
            return $ x `mulV` y :: Comp (UInt 10)

      property $ \(x, y :: Word8) -> do
        let expected = [(toInteger x * toInteger y) `mod` 1024]
        forM_ [gf181, Prime 17, Binary 7] $ \field ->
          check field program (map toInteger [x, y]) [] expected

    it "1 constant + 1 variable / Byte -> UInt 6" $ do
      let program x = do
            y <- input Public :: Comp (UInt 8)
            return $ x `mulV` y :: Comp (UInt 6)
      property $ \(x :: Word8, y :: Word8) -> do
        let expected = [(toInteger x * toInteger y) `mod` 64]
        check gf181 (program (fromIntegral x)) [toInteger y] [] expected
        check (Prime 17) (program (fromIntegral x)) [toInteger y] [] expected
        check (Binary 7) (program (fromIntegral x)) [toInteger y] [] expected

    it "1 constant + 1 variable / Byte -> UInt 10" $ do
      let program x = do
            y <- input Public :: Comp (UInt 8)
            return $ x `mulV` y :: Comp (UInt 10)
      property $ \(x :: Word8, y :: Word8) -> do
        let expected = [(toInteger x * toInteger y) `mod` 1024]
        check gf181 (program (fromIntegral x)) [toInteger y] [] expected
        check (Prime 17) (program (fromIntegral x)) [toInteger y] [] expected
        check (Binary 7) (program (fromIntegral x)) [toInteger y] [] expected