{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE UndecidableInstances #-}
{-# OPTIONS_GHC -Wno-unused-imports #-}

module Test.Data.UnionFind.Field (run, tests) where

import Control.Monad (forM_)
import Data.Field.Galois (Binary, GaloisField, Prime)
import Data.IntMap qualified as IntMap
import Data.Maybe qualified as Maybe
import Keelung (GF181, N (N), Var)
import Keelung.Data.UnionFind (UnionFind)
import Keelung.Data.UnionFind qualified as UnionFind
import Keelung.Data.UnionFind.Field qualified as Field
import Test.HUnit
import Test.Hspec
import Test.QuickCheck

run :: IO ()
run = hspec tests

tests :: SpecWith ()
tests = describe "Field UnionFind" $ do
  describe "operations" $ do
    return ()

--     it "relate" $ do
--       property $ \relates -> do
--         let xs = foldl applyRelate UnionFind.new (relates :: [Relate (Prime 17)]) :: Field.UnionFind (Prime 17)
--         Field.validate xs `shouldBe` []

--   --   it "relate and then assign" $ do
--   --     property $ \(relates, assignments) -> do
--   --       let xs = foldl applyRelate UnionFind.new (relates :: [Relate (Prime 17)])
--   --       let xs' =
--   --             foldr
--   --               ( \(Assign target val) acc -> case UnionFind.lookup target acc of
--   --                   UnionFind.Constant _ -> acc
--   --                   _ -> applyAssign acc (Assign target val)
--   --               )
--   --               xs
--   --               (assignments :: [Assign (Prime 17)])

--   --       Field.validate xs' `shouldBe` []

--   --   it "concrete case 1 / Binary 7" $ do
--   --     let xs =
--   --           foldl
--   --             applyRelate
--   --             UnionFind.new
--   --             ( [ Relate 4 1 51 0,
--   --                 Relate 5 1 52 1,
--   --                 Relate 4 2 5 1
--   --               ] ::
--   --                 [Relate (Binary 7)]
--   --             )
--   --     Field.validate xs `shouldBe` []
--   --     UnionFind.lookup 52 xs `shouldBe` UnionFind.ChildOf 4 (Field.LinRel 3 2)

--   --   it "concrete case 1 / Prime 7" $ do
--   --     let xs =
--   --           foldl
--   --             applyRelate
--   --             UnionFind.new
--   --             ( [ Relate 4 1 51 0,
--   --                 Relate 5 1 52 1,
--   --                 Relate 4 2 5 1
--   --               ] ::
--   --                 [Relate (Prime 7)]
--   --             )
--   --     Field.validate xs `shouldBe` []
--   --     UnionFind.lookup 52 xs `shouldBe` UnionFind.ChildOf 4 (Field.LinRel 4 2)

--   -- describe "symmetricity" $ do
--   --   it "relate and then assign" $ do
--   --     property $ \xs -> do
--   --       let (_assignments, families) = Field.export (xs :: Field.UnionFind GF181)
--   --       forM_ (IntMap.toList families) $ \(root, family) -> do
--   --         UnionFind.lookup root xs `shouldBe` UnionFind.Root
--   --         forM_ (IntMap.toList family) $ \(child, (slope, intercept)) -> do
--   --           UnionFind.lookup child xs `shouldBe` UnionFind.ChildOf root (Field.LinRel slope intercept)

--   -- describe "LinRel" $ do
--   --   describe "invertLinRel . invertLinRel = id" $ do
--   --     it "GF181" $ do
--   --       property $ \rel -> do
--   --         (Field.invertLinRel . Field.invertLinRel) rel `shouldBe` (rel :: Field.LinRel GF181)
--   --     it "Prime 17" $ do
--   --       property $ \rel -> do
--   --         (Field.invertLinRel . Field.invertLinRel) rel `shouldBe` (rel :: Field.LinRel (Prime 17))
--   --     it "Binary 7" $ do
--   --       property $ \rel -> do
--   --         (Field.invertLinRel . Field.invertLinRel) rel `shouldBe` (rel :: Field.LinRel (Binary 7))

--   --   describe "execLinRel invertLinRel rel . execLinRel rel = id" $ do
--   --     it "GF181" $ do
--   --       property $ \(rel, points) -> do
--   --         map (Field.execLinRel (Field.invertLinRel rel) . Field.execLinRel rel) points `shouldBe` (points :: [GF181])
--   --     it "Prime 17" $ do
--   --       property $ \(rel, points) -> do
--   --         map (Field.execLinRel (Field.invertLinRel rel) . Field.execLinRel rel) points `shouldBe` (points :: [Prime 17])
--   --     it "Binary 7" $ do
--   --       property $ \(rel, points) -> do
--   --         map (Field.execLinRel (Field.invertLinRel rel) . Field.execLinRel rel) points `shouldBe` (points :: [Binary 7])

------------------------------------------------------------

data Relate var val = Relate var var (UnionFind.Rel val) -- var1 = slope * var2 + intercept

instance (GaloisField val, Integral val, Show var, Show (UnionFind.Rel val)) => Show (Relate var val) where
  -- show (Relate var1 var2 relation) = "$" <> show var1 <> " = " <> show (N slope) <> " * $" <> show var2 <> " + " <> show (N intercept)
  show (Relate var1 var2 relation) = "$" <> show var1 <> " = " <> show relation <> "  $" <> show var2

instance (GaloisField val, Integral val, Arbitrary (UnionFind.Rel val)) => Arbitrary (Relate Var val) where
  arbitrary =
    Relate
      <$> chooseInt (0, 100) -- var1
      -- <*> (arbitrary `suchThat` (/= 0))
      <*> chooseInt (0, 100) -- var2
      <*> arbitrary

-- instance (GaloisField val, Integral val, Arbitrary var, Arbitrary (UnionFind.Rel val)) => Arbitrary (Relate var val) where
--   arbitrary =
--     Relate
--       <$> arbitrary -- var1
--       <*> arbitrary -- var2
--       <*> arbitrary

data Assign var val = Assign var val
  deriving (Show)

instance (GaloisField val, Integral val) => Arbitrary (Assign Var val) where
  arbitrary = Assign <$> chooseInt (0, 100) <*> arbitrary

-- instance (GaloisField val, Integral val, Arbitrary var) => Arbitrary (Assign var val) where
--   arbitrary = Assign <$> arbitrary <*> arbitrary

instance (GaloisField val, Integral val) => Arbitrary (Field.LinRel val) where
  arbitrary = Field.LinRel <$> (arbitrary `suchThat` (/= 0)) <*> arbitrary

------------------------------------------------------------

instance (GaloisField val, Integral val, UnionFind var val, Arbitrary var, Arbitrary (UnionFind.Rel val), Arbitrary (Relate var val), Arbitrary (Assign var val)) => Arbitrary (UnionFind.Map var val) where
  arbitrary = do
    relates <- arbitrary :: Gen [Relate var val]
    assignments <- arbitrary :: Gen [Assign var val]
    let xs = foldl applyRelate UnionFind.new relates
    return $
      foldr
        ( \(Assign target val) acc -> case UnionFind.lookup target acc of
            UnionFind.Constant _ -> acc
            _ -> applyAssign acc (Assign target val)
        )
        xs
        assignments

------------------------------------------------------------

applyRelate :: (GaloisField val, Integral val, UnionFind var val) => UnionFind.Map var val -> Relate var val -> UnionFind.Map var val
applyRelate xs (Relate var1 var2 relation) = Maybe.fromMaybe xs (UnionFind.relate var1 var2 relation xs)

applyAssign :: (GaloisField val, Integral val, UnionFind var val) => UnionFind.Map var val -> Assign var val -> UnionFind.Map var val
applyAssign xs (Assign var value) = Maybe.fromMaybe xs (UnionFind.assign var value xs)