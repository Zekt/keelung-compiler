-- For RefU Limb segement reference counting
{-# LANGUAGE DeriveGeneric #-}

module Keelung.Data.IntervalSet
  ( -- * Construction
    IntervalSet,
    new,

    -- * Operations
    adjust,

    -- * Conversion
    toIntervalTable,

    -- * Query
    intervalsWithin,
    totalCount,
    lookup,
    member,
    isValid,
  )
where

import Control.DeepSeq (NFData)
import Data.IntMap.Strict (IntMap)
import Data.IntMap.Strict qualified as IntMap
import Data.List qualified as List
import Data.Sequence (Seq)
import Data.Sequence qualified as Seq
import GHC.Generics (Generic)
import Keelung.Compiler.Util (showList')
import Keelung.Data.IntervalTable (IntervalTable (IntervalTable))
import Prelude hiding (lookup)

-- | Key: start of an interval
--   Value: (end of the interval, count of the interval)
--    invariant: no two intervals overlap
newtype IntervalSet n = IntervalSet (IntMap (Int, n)) deriving (Eq, Generic)

instance (Eq n, Show n, Num n) => Show (IntervalSet n) where
  show (IntervalSet xs) =
    showList'
      $ map
        ( \(start, (end, count)) ->
            if end - start == 1 && count /= 0
              then (if count == 1 then "" else show count) <> "$" <> show start
              else
                ( if count == 1
                    then "$" <> show start <> " ~ $" <> show (end - 1)
                    else show count <> "($" <> show start <> " ~ $" <> show (end - 1) <> ")"
                )
        )
      $ IntMap.toList xs

instance (NFData n) => NFData (IntervalSet n)

type Interval = (Int, Int) -- (start, end)

-- | O(1): Create an empty interval set
new :: IntervalSet n
new = IntervalSet mempty

-- | O(min(n, W)): Adjust the count of an interval.
adjust :: (Num n, Eq n) => Interval -> n -> IntervalSet n -> IntervalSet n
adjust interval count (IntervalSet xs) =
  let actions = calculateAction interval count (IntervalSet xs)
   in executeActions actions (IntervalSet xs)

-- | O(n): Compute the total count of all intervals (for testing purposes)
totalCount :: (Num n) => IntervalSet n -> n
totalCount (IntervalSet xs) = IntMap.foldlWithKey' (\acc start (end, count) -> acc + count * fromIntegral (end - start)) 0 xs

-- | O(n). To an IntervalTable
toIntervalTable :: Int -> IntervalSet Int -> IntervalTable
toIntervalTable domainSize (IntervalSet intervals) =
  let FoldState table occupiedSize = IntMap.foldlWithKey' step (FoldState mempty 0) intervals
   in IntervalTable domainSize occupiedSize table
  where
    step :: FoldState -> Int -> (Int, Int) -> FoldState
    step (FoldState acc occupiedSize) start (end, _) =
      FoldState
        (IntMap.insert start (end, start - occupiedSize) acc) -- insert the total size of "holes" before this interval
        (occupiedSize + end - start)

-- | O(min(n, W)): Look up the count of a variable in the interval set
lookup :: IntervalSet n -> Int -> Maybe n
lookup (IntervalSet xs) x = case IntMap.lookupLE x xs of
  Nothing -> Nothing
  Just (_, (end, count)) -> if x < end then Just count else Nothing

-- | O(min(n, W)): Check if a variable occurred (i.e. count /= 0) in the interval set
member :: (Eq n, Num n) => IntervalSet n -> Int -> Bool
member (IntervalSet xs) x = case IntMap.lookupLE x xs of
  Nothing -> False
  Just (_, (end, count)) -> x < end && count /= 0

-- | Given an interval, return a list of intervals that occurred (i.e. count /= 0) in this interval
intervalsWithin :: (Eq n, Num n) => IntervalSet n -> (Int, Int) -> Seq (Int, Int)
intervalsWithin (IntervalSet xs) (start, end) =
  let (_, rest) = split (IntervalSet xs) start
      (IntervalSet middle, _) = split rest end
   in Seq.fromList $ map (\(start', (end', _)) -> (start', end')) $ IntMap.toList middle

-- | Split an IntervalSet into two at a given point
split :: (Eq n, Num n) => IntervalSet n -> Int -> (IntervalSet n, IntervalSet n)
split (IntervalSet xs) pos =
  let -- split the map into three parts: before "pos", at "pos", after "pos"
      (before, middle, after) = IntMap.splitLookup pos xs
   in case middle of
        Just (moddleEnd, middleCount) ->
          -- there happens to be an interval at "pos"
          (IntervalSet before, IntervalSet $ IntMap.insert pos (moddleEnd, middleCount) after)
        Nothing ->
          -- see if there is an interval in the "before" part that overlaps with "pos"
          case IntMap.maxViewWithKey before of
            Just ((start, (end, count)), beforeBefore) ->
              if end > pos && count /= 0
                then (IntervalSet (IntMap.insert start (pos, count) beforeBefore), IntervalSet (IntMap.insert pos (end, count) after))
                else (IntervalSet before, IntervalSet after)
            Nothing ->
              (IntervalSet mempty, IntervalSet xs) -- no interval before "pos"

-- | O(n): Check if these intervals are valid (for testing purposes)
--   Invariants:
--      1. no two intervals overlap
--      2. no interval has zero length
--      3. no interval has 0 count
isValid :: (Eq n, Num n) => IntervalSet n -> Bool
isValid (IntervalSet xs) = fst $ IntMap.foldlWithKey' step (True, 0) xs
  where
    step :: (Eq n, Num n) => (Bool, Int) -> Int -> (Int, n) -> (Bool, Int)
    step (valid, previousEnd) start (end, count) =
      ( valid && start < end && previousEnd <= start && count /= 0,
        end
      )

--------------------------------------------------------------------------------

-- | Actions to be executed on an interval set
data Action n
  = InsertNew
      Interval -- interval to be inserted
      n -- count
  | RemoveExisting
      (Int, Int) -- interval of existing interval to be removed
  deriving (Eq, Show)

-- | Calculate the actions needed to insert an interval into an interval set
calculateAction :: (Num n) => Interval -> n -> IntervalSet n -> [Action n]
calculateAction inserted@(start, end) count (IntervalSet xs) = case IntMap.lookupLT start xs of
  Nothing ->
    --   inserted      ├─────────────────┤
    --   existing
    calculateActionAfter inserted count (IntervalSet xs)
  Just (existingStart, (existingEnd, existingAmount)) ->
    if start >= existingEnd
      then --
      -- inserted                  ├─────┤
      -- existing      ├─────┤
        calculateActionAfter inserted count (IntervalSet xs)
      else
        if end >= existingEnd
          then --
          -- inserted            ├───────────┤
          -- existing      ├───────────┤
          --            =>
          -- inserted            ╠═════╣─────┤
          -- existing      ├─────╠═════╣
          --    parts         1     2

            let removeExisting = RemoveExisting (existingStart, existingEnd)
                insertPart1 = InsertNew (existingStart, start) existingAmount
                insertPart2 = InsertNew (start, existingEnd) (existingAmount + count)
                restActions = calculateActionAfter (existingEnd, end) count (IntervalSet xs)
             in removeExisting : insertPart1 : insertPart2 : restActions
          else --
          -- inserted            ├─────┤
          -- existing      ├─────────────────┤
          --            =>
          -- inserted            ╠═════╣
          -- existing      ├─────╠═════╣─────┤
          --    parts         1     2     3

            let removeExisting = RemoveExisting (existingStart, existingEnd)
                insertPart1 = InsertNew (existingStart, start) existingAmount
                insertPart2 = InsertNew (start, end) (existingAmount + count)
                insertPart3 = InsertNew (end, existingEnd) existingAmount
             in [removeExisting, insertPart1, insertPart2, insertPart3]

-- | Calculate the actions needed to insert an interval into an interval set with existing intervals after it
calculateActionAfter :: (Num n) => Interval -> n -> IntervalSet n -> [Action n]
calculateActionAfter inserted@(start, end) count (IntervalSet xs) = case IntMap.lookupGE start xs of
  Nothing ->
    -- inserted          ├─────────────────┤
    -- existing
    [InsertNew inserted count]
  Just (existingStart, (existingEnd, existingAmount))
    | end <= existingStart ->
        -- inserted      ├─────┤
        -- existing                  ├─────┤
        [InsertNew inserted count]
    | end <= existingEnd ->
        -- inserted      ├───────────┤
        -- existing            ├───────────┤
        --            =>
        -- inserted      ├─────╠═════╣
        -- existing            ╠═════╣─────┤
        --    parts         1     2     3
        let removeExisting = RemoveExisting (existingStart, existingEnd)
            insertPart1 = InsertNew (start, existingStart) count
            insertPart2 = InsertNew (existingStart, end) (existingAmount + count)
            insertPart3 = InsertNew (end, existingEnd) existingAmount
         in [removeExisting, insertPart1, insertPart2, insertPart3]
    | otherwise -> -- end > existingEnd
    --     inserted      ├─────────────────┤
    --     existing            ├─────┤
    --                =>
    --     inserted      ├─────╠═════╣─────┤
    --     existing            ╠═════╣
    --        parts         1     2     3
        let removeExisting = RemoveExisting (existingStart, existingEnd)
            insertPart1 = InsertNew (start, existingStart) count
            insertPart2 = InsertNew (existingStart, existingEnd) (existingAmount + count)
            restActions = calculateActionAfter (existingEnd, end) count (IntervalSet xs)
         in removeExisting : insertPart1 : insertPart2 : restActions

-- | Execute a list of actions on an interval set
executeActions :: (Eq n, Num n) => [Action n] -> IntervalSet n -> IntervalSet n
executeActions actions (IntervalSet set) = IntervalSet $ List.foldl' step set actions
  where
    step :: (Eq n, Num n) => IntMap (Int, n) -> Action n -> IntMap (Int, n)
    step xs (InsertNew (start, end) count) =
      if start == end || count == 0
        then xs
        else IntMap.insert start (end, count) xs
    step xs (RemoveExisting (start, end)) = case IntMap.lookup start xs of
      Nothing -> error "[ panic ] IntervalSet: trying to remove non-existing interval"
      Just (existingEnd, existingAmount) ->
        if existingEnd <= end
          then IntMap.delete start xs
          else IntMap.insert end (existingEnd, existingAmount) (IntMap.delete start xs)

--------------------------------------------------------------------------------

-- | Temporary data structure for constructing an IntervalTable
data FoldState = FoldState
  { -- | The resulting table
    _stateTable :: IntMap (Int, Int),
    -- | The total size of intervals so far
    _stateEndOfLastInterval :: Int
  }
