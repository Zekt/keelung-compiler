{-# LANGUAGE DataKinds #-}

module Main where

import Basic qualified
-- import Control.Arrow (ArrowChoice (right), left)

import Control.Arrow (ArrowChoice (..))
import Data.Sequence qualified as Seq
import Data.Vector qualified as Vector
import Keelung
import Keelung.Compiler
import Keelung.Compiler qualified as Compiler
import Keelung.Compiler.Relocated (cadd)
import Keelung.Compiler.Syntax.Inputs qualified as Inputs
import Keelung.Constraint.R1CS (R1CS)
import Keelung.Data.Bindings qualified as Bindings
import Keelung.Data.Polynomial (Poly)
import Keelung.Data.Polynomial qualified as Poly
import Keelung.Data.Struct qualified as Bindings
import Keelung.Syntax.Counters
import Test.Compilation qualified as Compilation
import Test.ConstraintMinimizer qualified as ConstraintMinimizer
import Test.Hspec
import Test.Interpreter qualified as Interpreter
import Test.Optimization qualified as Optimization
import Test.VarLayout qualified as VarBookkeep

main :: IO ()
main = hspec $ do
  describe "Constraint Minimization" ConstraintMinimizer.tests

  describe "Interpreter" Interpreter.tests

  describe "Compilation" Compilation.tests

  describe "Optimization" Optimization.tests

  describe "Variable Bookkeeping" VarBookkeep.tests

  describe "Poly" $ do
    it "instance Eq 1" $ Poly.buildEither 42 [(1, 1)] `shouldBe` (Poly.buildEither 42 [(1, 1)] :: Either GF181 (Poly GF181))
    it "instance Eq 2" $ Poly.buildEither 42 [(1, 1)] `shouldBe` (Poly.buildEither (-42) [(1, -1)] :: Either GF181 (Poly GF181))

  describe "Constraint Generation" $ do
    it "assertToBe42" $
      let cs =
            RelocatedConstraintSystem
              { csConstraints =
                  Seq.fromList $
                    cadd (-42 :: GF181) [(0, 1)],
                csCounters = addCount OfPublicInput OfField 1 mempty
              }
       in Compiler.compileOnly Basic.assertToBe42 `shouldBe` Right cs

  describe "Witness generation" $ do
    it "Program with public and private inputs" $ do
      let program = do
            x <- inputField Public
            y <- inputField Private
            return [x, y]
      let actual = generateWitness program [1 :: GF181] [2]
      let expected = do
            cs <- Compiler.compile program
            let witness =
                  Bindings.OIX
                    mempty
                    (Bindings.Struct (Vector.fromList [1]) mempty mempty)
                    (Bindings.Struct (Vector.fromList [2]) mempty mempty)
                    mempty
            return (Inputs.deserialize (csCounters cs) [1] [2], [1, 2], witness)
      actual `shouldBe` expected

  describe "Keelung `compile`" $ do
    it "Program that throws ElabError.IndexOutOfBoundsError" $ do
      let expected = left show ((toR1CS :: RelocatedConstraintSystem GF181 -> R1CS GF181) <$> Compiler.compile Basic.outOfBound)
      actual <- right (fmap fromInteger) . left show <$> Keelung.compile GF181 Basic.outOfBound
      actual `shouldBe` expected

    it "Program that throws ElabError.EmptyArrayError" $ do
      let expected = left show ((toR1CS :: RelocatedConstraintSystem GF181 -> R1CS GF181) <$> Compiler.compile Basic.emptyArray)
      actual <- right (fmap fromInteger) . left show <$> Keelung.compile GF181 Basic.emptyArray
      actual `shouldBe` expected

    it "Program that compiles successfully" $ do
      let expected = left show ((toR1CS :: RelocatedConstraintSystem GF181 -> R1CS GF181) <$> Compiler.compile Basic.identity)
      actual <- right (fmap fromInteger) . left show <$> Keelung.compile GF181 Basic.identity
      actual `shouldBe` expected

  describe "Keelung `interpret`" $ do
    it "Program that throws ElabError.IndexOutOfBoundsError" $ do
      let expected = left show (Compiler.interpret Basic.outOfBound ([] :: [GF181]) ([] :: [GF181]))
      actual <- left show <$> Keelung.interpret_ GF181 Basic.outOfBound [] []
      actual `shouldBe` expected

    it "Program that throws ElabError.EmptyArrayError" $ do
      let expected = left show (Compiler.interpret Basic.emptyArray ([] :: [GF181]) ([] :: [GF181]))
      actual <- left show <$> Keelung.interpret_ GF181 Basic.emptyArray [] []
      actual `shouldBe` expected

    it "Basic.eq1 1" $ do
      let expected = left show (Compiler.interpret Basic.eq1 ([0] :: [GF181]) ([] :: [GF181]))
      actual <- left show <$> Keelung.interpret_ GF181 Basic.eq1 [0] []
      actual `shouldBe` expected

    it "Basic.eq1 2" $ do
      let expected = left show (Compiler.interpret Basic.eq1 ([3] :: [GF181]) ([] :: [GF181]))
      actual <- left show <$> Keelung.interpret_ GF181 Basic.eq1 [3] []
      actual `shouldBe` expected
