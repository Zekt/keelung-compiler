{-# LANGUAGE DataKinds #-}

module Main where

import qualified AggregateSignature.Program.Keelung as Keelung
import qualified AggregateSignature.Program.Snarkl as Snarkl
import AggregateSignature.Util
import qualified Basic
import qualified Data.IntMap as IntMap
import Keelung
import qualified Snarkl
import Test.Hspec

-- | (1) Compile to R1CS.
--   (2) Generate a satisfying assignment, 'w'.
--   (3) Check whether 'w' satisfies the constraint system produced in (1).
--   (4) Check whether the R1CS result matches the interpreter result.
execute :: (GaloisField n, Bounded n, Integral n, Erase ty) => Comp ty n -> [n] -> Either String n
execute prog inputs = do
  elaborated <- elaborate prog
  let constraintSystem = compile elaborated
  let r1cs = fromConstraintSystem constraintSystem

  let outputVar = r1csOutputVar r1cs
  witness <- witnessOfR1CS inputs r1cs

  -- extract the output value from the witness
  actualOutput <- case IntMap.lookup outputVar witness of
    Nothing ->
      Left $
        "output variable "
          ++ show outputVar
          ++ "is not mapped in\n  "
          ++ show witness
    Just value -> return value

  -- interpret the program to see if the output value is correct
  expectedOutput <- interpret elaborated inputs

  if actualOutput == expectedOutput && satisfyR1CS witness r1cs
    then return actualOutput
    else
      Left $
        "interpreter result "
          ++ show expectedOutput
          ++ " differs from actual result "
          ++ show actualOutput

-- return $ Result result nw ng out r1cs

runSnarklAggSig :: Int -> Int -> GF181
runSnarklAggSig dimension numberOfSignatures =
  let settings =
        Settings
          { enableAggSigChecking = True,
            enableBitStringSizeChecking = True,
            enableBitStringValueChecking = True,
            enableSigSquareChecking = True,
            enableSigLengthChecking = True
          }
      setup = makeSetup dimension numberOfSignatures 42 settings :: Setup GF181
   in Snarkl.resultResult $
        Snarkl.execute
          Snarkl.Simplify
          (Snarkl.aggregateSignature setup :: Snarkl.Comp 'Snarkl.TBool GF181)
          (genInputFromSetup setup)

runKeelungAggSig :: Int -> Int -> Maybe GF181
runKeelungAggSig dimension numberOfSignatures =
  let settings =
        Settings
          { enableAggSigChecking = True,
            enableBitStringSizeChecking = True,
            enableBitStringValueChecking = True,
            enableSigSquareChecking = True,
            enableSigLengthChecking = True
          }
      setup = makeSetup dimension numberOfSignatures 42 settings :: Setup GF181
      result =
        execute
          (Keelung.aggregateSignature setup :: Comp 'Bool GF181)
          (genInputFromSetup setup)
   in case result of
        Left _ -> Nothing
        Right val -> Just val

main :: IO ()
main = hspec $ do
  describe "Aggregate Signature" $ do
    describe "Snarkl" $ do
      it "dim:1 sig:1" $
        runSnarklAggSig 1 1 `shouldBe` 1
      it "dim:1 sig:10" $
        runSnarklAggSig 1 10 `shouldBe` 1
      it "dim:10 sig:1" $
        runSnarklAggSig 10 1 `shouldBe` 1
      it "dim:10 sig:10" $
        runSnarklAggSig 10 10 `shouldBe` 1
    describe "Keelung" $ do
      it "dim:1 sig:1" $
        runSnarklAggSig 1 1 `shouldBe` 1
      it "dim:1 sig:10" $
        runSnarklAggSig 1 10 `shouldBe` 1
      it "dim:10 sig:1" $
        runSnarklAggSig 10 1 `shouldBe` 1
      it "dim:10 sig:10" $
        runSnarklAggSig 10 10 `shouldBe` 1

  describe "Basic" $ do
    it "identity (Num)" $
      execute Basic.identity [42] `shouldBe` Right 42
    it "identity (Bool)" $
      execute Basic.identityB [1] `shouldBe` Right 1
    it "identity (Bool)" $
      execute Basic.identityB [0] `shouldBe` Right 0
    it "add3" $
      execute Basic.add3 [0] `shouldBe` Right 3
    it "eq1 1" $
      execute Basic.eq1 [0] `shouldBe` Right 0
    it "eq1 2" $
      execute Basic.eq1 [3] `shouldBe` Right 1
    it "cond 1" $
      execute Basic.cond [0] `shouldBe` Right 789
    -- it "cond 2" $
    --   execute Basic.cond [3] `shouldBe` Right 12