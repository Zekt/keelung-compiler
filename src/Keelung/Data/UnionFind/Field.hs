{-# HLINT ignore "Use list comprehension" #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# OPTIONS_GHC -Wno-unrecognised-pragmas #-}

module Keelung.Data.UnionFind.Field
  ( -- * Wrapper
    Wrapper (..),

    -- * Construction
    UnionFind,
    UnionFind.new,

    -- * Operations
    UnionFind.assign,
    UnionFind.relate,

    -- * Conversions,
    export,
    renderFamilies,

    -- * Queries
    UnionFind.Lookup (..),
    UnionFind.lookup,
    UnionFind.size,

    -- * Linear Relations
    LinRel (..),

    -- * Testing
    UnionFind.Error (..),
    UnionFind.validate,
    UnionFind.isValid,
  )
where

import Control.DeepSeq (NFData)
import Data.Field.Galois (GaloisField)
import Data.IntMap.Strict (IntMap)
import Data.IntMap.Strict qualified as IntMap
import Data.Serialize (Serialize)
import GHC.Generics (Generic)
import Keelung.Data.UnionFind qualified as UnionFind
import Keelung.Data.UnionFind.Relation (Relation (..))
import Keelung.Data.UnionFind.Relation qualified as Relation
import Prelude hiding (lookup)

--------------------------------------------------------------------------------

-- | Type synonym for the specialized UnionFind on GaloisField n with linear relations
type UnionFind n = UnionFind.UnionFind (Wrapper n) (LinRel n)

-- | Wrapper for GaloisField elements
newtype Wrapper n = Wrapper {unwrap :: n}
  deriving (Show, Eq, NFData, Generic)

instance (Serialize n) => Serialize (Wrapper n)

instance (Ord n) => Ord (Wrapper n) where
  compare (Wrapper x) (Wrapper y) = compare x y

--------------------------------------------------------------------------------

-- | Exports the UnionFind as a pair of:
--    1. a map from the constant variables to their values
--    2. a map from the root variables to their children with the relation `(slope, intercept)`
export ::
  UnionFind n ->
  ( IntMap n, -- constants
    IntMap (IntMap (n, n)) -- families
  )
export (UnionFind.UnionFind relations) = (constants, roots)
  where
    constants = IntMap.mapMaybe toConstant relations
    roots = IntMap.mapMaybe toRoot relations

    toConstant (UnionFind.IsConstant (Wrapper value)) = Just value
    toConstant _ = Nothing

    toRoot (UnionFind.IsRoot _ children) = Just $ IntMap.map fromLinRel children
    toRoot _ = Nothing

-- | Helper function to render the families resulted from `export`
renderFamilies :: (GaloisField n, Integral n) => IntMap (IntMap (n, n)) -> String
renderFamilies families = mconcat (map (<> "\n") (concatMap toString (IntMap.toList families)))
  where
    showVar var = let varString = "$" <> show var in "  " <> varString <> replicate (8 - length varString) ' '
    toString (root, toChildren) = case map (uncurry Relation.renderWithVar) (IntMap.toList (fmap (uncurry LinRel) toChildren)) of
      [] -> [showVar root <> " = []"] -- should never happen
      (x : xs) -> showVar root <> " = " <> x : map ("           = " <>) xs

--------------------------------------------------------------------------------

-- | Relation representing a linear function between two variables, i.e. x = ay + b
data LinRel n
  = LinRel
      n -- slope
      n -- intercept
  deriving (Show, Eq, NFData, Generic, Functor)

-- | x ~a~ y & y ~b~ z => x ~a<>b~ z
instance (Num n) => Semigroup (LinRel n) where
  -- x = a1 * y + b1
  -- y = a2 * z + b2
  -- =>
  -- x = a1 * (a2 * z + b2) + b1
  --   = (a1 * a2) * z + (a1 * b2 + b1)
  LinRel a1 b1 <> LinRel a2 b2 = LinRel (a1 * a2) (a1 * b2 + b1)

instance (Num n) => Monoid (LinRel n) where
  mempty = LinRel 1 0

instance (Serialize n) => Serialize (LinRel n)

instance (NFData n) => NFData (UnionFind.Status n (LinRel n))

-- | Extracts the coefficients from a LinRel
fromLinRel :: LinRel n -> (n, n)
fromLinRel (LinRel a b) = (a, b)

instance (GaloisField n, Integral n) => Relation (LinRel n) (Wrapper n) where
  -- Computes the inverse of a relation
  --      x = ay + b
  --        =>
  --      y = (1/a) x + (-b/a)
  invert (LinRel a b) = LinRel (recip a) ((-b) / a)

  -- `execute relation parent = child`
  execute (LinRel a b) (Wrapper value) = Wrapper (a * value + b)

  renderWithVar var rel = go (Relation.invert rel)
    where
      var' = "$" <> show var

      go (LinRel (-1) 1) = "¬" <> var'
      go (LinRel a b) =
        let slope = case a of
              1 -> var'
              (-1) -> "-" <> var'
              _ -> show a <> var'
            intercept = case b of
              0 -> ""
              _ -> " + " <> show b
         in -- if N.isPositive b
            --   then " + " <> show (N b)
            --   else " - " <> show (N (-b))
            slope <> intercept

--------------------------------------------------------------------------------

instance (Ord n, Num n) => UnionFind.HasRange (Wrapper n) where
  isWithinRange (UnionFind.Range Nothing) _ = True
  isWithinRange (UnionFind.Range (Just (Wrapper l, Wrapper u))) (Wrapper x) =
    (l >= u) || (l <= x && x < u)

  execRelOnRange _ (UnionFind.Range Nothing) = UnionFind.Range Nothing
  execRelOnRange relation (UnionFind.Range (Just (l, u))) = UnionFind.Range (Just (Relation.execute relation l, Relation.execute relation u))