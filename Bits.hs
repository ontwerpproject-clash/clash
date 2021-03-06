{-# LANGUAGE FlexibleContexts,GADTs,ExistentialQuantification,LiberalTypeSynonyms,TemplateHaskell, DeriveDataTypeable #-}

module Bits where

-- import qualified Data.Param.TFVec as TFVec
-- import qualified Types
import Language.Haskell.TH.Lift

import Data.Typeable

--class Signal a where
--	hwand :: a -> a -> a
--	hwor  :: a -> a -> a
--	hwxor :: a -> a -> a
--	hwnot :: a -> a
--
--	-- Prettyprint a signal. We're not extending Show here, since show must
--	-- return a valid haskell syntax
--	displaysig :: a -> String

hwand :: Bit -> Bit -> Bit
hwor  :: Bit -> Bit -> Bit
hwxor :: Bit -> Bit -> Bit
hwnot :: Bit -> Bit

-- Prettyprint Bit signal. We're not extending Show here, since show must
-- return Bit valid haskell syntax
displaysig :: Bit -> String

--instance Signal Bit where
High `hwand` High = High
_ `hwand` _ = Low

High `hwor` _  = High
_ `hwor` High  = High
Low `hwor` Low = Low

High `hwxor` Low = High
Low `hwxor` High = High
_ `hwxor` _      = Low

hwnot High = Low
hwnot Low  = High

displaysig High = "1" 
displaysig Low  = "0"

-- The plain Bit type
data Bit = High | Low
  deriving (Show, Eq, Read, Typeable)

$(deriveLift1 ''Bit)

-- A function to prettyprint a bitvector

--displaysigs :: (Signal s) => [s] -> String
-- displaysigs :: [Bit] -> String
-- displaysigs = (foldl (++) "") . (map displaysig)

-- type Stream a = [a]

-- An infinite streams of highs or lows
-- lows  = Low : lows
-- highs = High : highs
-- 
-- type BitVec len = TFVec.TFVec len Bit

-- vim: set ts=8 sw=2 sts=2 expandtab:
