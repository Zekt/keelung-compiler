module Test.BooleanRelations (tests, run) where

import Control.Monad.Except
import Control.Monad.State
import Keelung.Compiler.Compile.Error (Error)
import Keelung.Compiler.Compile.Relations.BooleanRelations (BooleanRelations)
import Keelung.Compiler.Compile.Relations.BooleanRelations qualified as BooleanRelations
import Keelung.Compiler.Constraint (RefB (..))
import Keelung.Field (GF181)
import Test.Hspec (SpecWith, describe, hspec, it)
import Test.Hspec.Expectations.Lifted
import Test.QuickCheck (Arbitrary (arbitrary))
import Test.QuickCheck.Arbitrary qualified as Arbitrary

run :: IO ()
run = hspec tests

tests :: SpecWith ()
tests = do
  describe "BooleanRelations" $ do
    describe "bindToValue" $ do
      it "x = True" $
        runM $ do
          RefB 0 `bindToValue` True

          assertBinding (RefB 0) (Just True)

      it "x = False" $
        runM $ do
          RefB 0 `bindToValue` False

          assertBinding (RefB 0) (Just False)

    describe "relate" $ do
      it "x = y" $
        runM $ do
          RefB 0 `relate` (True, RefB 1)

          assertRelation (RefB 0) (RefB 1) (Just True)
          assertRelation (RefB 1) (RefB 0) (Just True)

      it "x = y = True" $
        runM $ do
          RefB 0 `relate` (True, RefB 1)
          RefB 1 `bindToValue` True

          assertRelation (RefB 0) (RefB 1) (Just True)
          assertRelation (RefB 1) (RefB 0) (Just True)
          assertBinding (RefB 0) (Just True)
          assertBinding (RefB 1) (Just True)

      it "x = y = z" $
        runM $ do
          RefB 0 `relate` (True, RefB 1)
          RefB 1 `relate` (True, RefB 2)

          assertRelation (RefB 0) (RefB 1) (Just True)
          assertRelation (RefB 0) (RefB 2) (Just True)
          assertRelation (RefB 1) (RefB 0) (Just True)
          assertRelation (RefB 1) (RefB 2) (Just True)
          assertRelation (RefB 2) (RefB 0) (Just True)
          assertRelation (RefB 2) (RefB 1) (Just True)

      it "x = ¬y" $
        runM $ do
          RefB 0 `relate` (False, RefB 1)

          assertRelation (RefB 0) (RefB 1) (Just False)
          assertRelation (RefB 1) (RefB 0) (Just False)

      it "x = ¬y = True" $
        runM $ do
          RefB 0 `relate` (False, RefB 1)
          RefB 0 `bindToValue` True

          assertRelation (RefB 0) (RefB 1) (Just False)
          assertRelation (RefB 1) (RefB 0) (Just False)
          assertBinding (RefB 0) (Just True)
          assertBinding (RefB 1) (Just False)

      it "x = ¬y, z = True" $
        runM $ do
          RefB 0 `relate` (False, RefB 1)
          RefB 2 `bindToValue` True

          assertRelation (RefB 0) (RefB 1) (Just False)
          assertRelation (RefB 0) (RefB 2) Nothing
          assertRelation (RefB 1) (RefB 0) (Just False)
          assertRelation (RefB 1) (RefB 2) Nothing
          assertRelation (RefB 2) (RefB 0) Nothing
          assertRelation (RefB 2) (RefB 1) Nothing
          assertBinding (RefB 0) Nothing
          assertBinding (RefB 1) Nothing
          assertBinding (RefB 2) (Just True)

type M = StateT BooleanRelations IO

runM :: M a -> IO a
runM p = evalStateT p BooleanRelations.new

relate :: RefB -> (Bool, RefB) -> M ()
relate var (polarity, val) = do
  xs <- get
  case runExcept (BooleanRelations.relate var polarity val xs) of
    Left err -> error $ show (err :: Error GF181)
    Right result -> put result

bindToValue :: RefB -> Bool -> M ()
bindToValue var val = do
  xs <- get
  case runExcept (BooleanRelations.assign var val xs) of
    Left err -> error $ show (err :: Error GF181)
    Right result -> put result

-- | Assert that `var1 = slope * var2 + intercept`
assertRelation :: RefB -> RefB -> Maybe Bool -> M ()
assertRelation var1 var2 result = do
  xs <- get
  BooleanRelations.relationBetween var1 var2 xs `shouldBe` result

assertBinding :: RefB -> Maybe Bool -> M ()
assertBinding var val = do
  xs <- get
  case BooleanRelations.lookup var xs of
    BooleanRelations.Value value -> val `shouldBe` Just value
    _ -> val `shouldBe` Nothing

------------------------------------------------------------------------

instance Arbitrary BooleanRelations where
  arbitrary = do
    relations <- Arbitrary.vector 100

    return $ foldl go BooleanRelations.new relations
    where
      go xs (var, polarity, ref) = case runExcept (BooleanRelations.relate var polarity ref xs) of
        Left err -> error $ show (err :: Error GF181)
        Right result -> result

instance Arbitrary RefB where
  arbitrary = RefB <$> arbitrary