<meta charset="utf-8">
<link rel="stylesheet" href="https://tonyday567.github.io/other/lhs.css">
<script type="text/javascript" async
  src="https://cdn.mathjax.org/mathjax/latest/MathJax.js?config=TeX-MML-AM_CHTML">
</script>

[perf](https://tonyday567.github.io/perf/index.html)
===

[![Build Status](https://travis-ci.org/tonyday567/perf.svg)](https://travis-ci.org/tonyday567/perf) [![Hackage](https://img.shields.io/hackage/v/perf.svg)](https://hackage.haskell.org/package/perf) [![lts](https://www.stackage.org/package/perf/badge/lts)](http://stackage.org/lts/package/perf) [![nightly](https://www.stackage.org/package/perf/badge/nightly)](http://stackage.org/nightly/package/perf)

[repo](https://github.com/tonyday567/perf)

If you want to make stuff very fast in haskell, you need to dig down below the criterion abstraction-level and start counting cycles using the [rdtsc](https://en.wikipedia.org/wiki/Time_Stamp_Counter) register on x86.

These examples are experiments in measuring cycles (or ticks), a development of intuition about what is going on at the very fast level.

The interface is subject to change as intuition develops and rabbit holes explored.

> {-# OPTIONS_GHC -Wall #-}
> {-# OPTIONS_GHC -fno-warn-type-defaults #-}
> {-# LANGUAGE OverloadedStrings #-}
> {-# LANGUAGE DataKinds #-}
> import Data.Text (pack, intercalate)
> import Data.Text.IO (writeFile)
> import Formatting
> import Protolude hiding ((%), intercalate)
> import Data.List ((!!))
> import Data.TDigest
> import System.Random.MWC.Probability
> import Options.Generic
> import qualified Control.Foldl as L
> import qualified Data.Vector as V
> import qualified Data.Vector.Unboxed as U
> import qualified Data.Vector.Storable as S
> import Chart
> import Diagrams.Prelude
> 

The examples below mostly use `Perf.Cycles`.  There is also a monad layer in `Perf` which has been used in `other/summing.lhs`.

> import Perf

All the imports that are needed for charts

command line
---

> data Opts = Opts
>   { runs :: Maybe Int    -- <?> "number of runs"
>   , sumTo :: [Double] -- <?> "sum to this number"
>   , chartNum :: Maybe Int
>   , truncAt :: Maybe Double
>   }
>   deriving (Generic, Show)
> 
> instance ParseRecord Opts

main
---

> main :: IO ()
> main = do
>   o :: Opts <- getRecord "a random bit of text"
>   let n = fromMaybe 10000 (runs o)
>   let as = case sumTo o of
>         [] -> [1,10,100,1000,10000]
>         x -> x
>   let trunc = fromMaybe 5 (truncAt o)
>   let numChart = min (length as) $ fromMaybe 3 (chartNum o)

For reference, based on a 2.6G machine one cycle is = 0.38 𝛈s

`tick_` taps the register twice to get a sense of the cost.

>   onetick <- tick_
>   ticks' <- replicateM 10 tick_
>   avtick <- replicateM 1000000 tick_
>   let average cs = L.fold ((/) <$> L.sum <*> L.genericLength) cs
>   writeFile "other/onetick.md" $ code
>     [ "one tick_: " <> pack (show onetick) <> " cycles"
>     , "next 10: " <> pack (show ticks')
>     , "average over 1m: " <>
>       pack (show $ average (fromIntegral <$> avtick)) <> " cycles"
>     ]

```include
other/onetick.md
```

Before we actually measure something, lets take a closer look at tick_.

A pattern I see on my machine are shifts by multiples of 4, which correspond to roughly the L1 [cache latency](http://stackoverflow.com/questions/1126529/what-is-the-cost-of-an-l1-cache-miss).

It pays to look at the whole distribution, and a compact way of doing that is to calculate quantiles:

>   -- warmup 100
>   xs <- replicateM 10000 tick_
>   writeFile "other/tick_.md" $ code $
>         (["[min, 10th, 20th, .. 90th, max]:"] :: [Text]) <>
>         [mconcat (sformat (" " % prec 3) <$> deciles 5 (fromIntegral <$> xs))]

```include
other/tick_.md
```

The important cycle count for most work is around the 30th to 50th percentile, where you get a clean measure, hopefully free of GC activity and cache miss-fires.

The quantile print of tick_ sometimes shows a 12 to 14 point jump around the 90th percential, and this is in the zone of an L2 access.  Without a warmup, one or more larger values occur at the start, and often are in the zone of an L2 miss. Sometimes there's also a few large hiccoughs at around 2k cycles.

summing
===

Let's measure something.  The simplest something I could think of was summing.

The helper function `reportQuantiles` utilises `spins` which takes n measurements of a function application over a range of values to apply.

>   let f :: Double -> Double
>       f x = foldl' (+) 0 [1..x]
>   _ <- warmup 100
>   (cs,_) <- spins n tick f as
>   reportQuantiles cs as "other/spin.md"
> 

```include
other/spin.md
```

Each row represents summing to a certain point: 1 up to 10000, and each column is a decile: min, 10th .. 90th, max. The values in each cell are the number of cycles divided by the number of runs and the number of sumTo.

The first row (summing to 1) represents the cost of setting up the sum, so we're looking at about (692 - 128) = 560 cycles every run.

Overall, the computation looks like it's running in O(n) where n is the number of runs * nuber of sumTo.  Specifically, I would write down the order at about:

    123 * o(n) + 560 * o(1)

The exception is the 70th to 90th zone, where the number of cycles creeps up to 194 for 1k sumTo at the 90th percentile.

Charting the 1k sumTo:

>   let xs_0 = fromIntegral <$> take 10000 (cs!!numChart) -- summing to 1000
>   let xs1 = (\x -> min x (trunc*deciles 5 xs_0 !! 5)) <$> xs_0
>   fileSvg "other/spin1k.svg" (750,250) $ pad 1.1 $ histLine xs1

![](other/spin1k.svg)

Switching to a solo experiment gives:

~~~
stack exec "ghc" -- -O2 -rtsopts examples/summing.lhs
./examples/summing +RTS -s -RTS --runs 10000 --sumTo 1000 --chart --chartName other/sum1e3.svg --truncAt 4
~~~

![](other/sum1e3.svg)

Executable complexity has changed the profile of the overall computation.  Both measurements have the same value, however, up to around the 30th percentile.


generic vector
---

Using vector to sum:

>   let asv :: [V.Vector Double] = (\x -> V.generate (floor x) fromIntegral) <$> as
>   let sumv :: V.Vector Double -> Double
>       sumv x = V.foldl (+) 0 x
>   (csv,_) <- spins n tick sumv asv
>   reportQuantiles csv as "other/vectorGen.md"
> 

```include
other/vectorGen.md
```

randomizing data
---

To avoid ghc (and fusion) trickiness, it's often a good idea to use random numbers instead of simple progressions.  One day, a compiler will discover `x(x+1)/2` and then we'll be in real trouble.

>   mwc <- create
>   !asr <- (fmap V.fromList <$>) <$> sequence $ (\x -> samples x uniform mwc) . floor <$> as
>   void $ warmup 100
>   (csr,_) <- spins n tick sumv asr
>   reportQuantiles csr as "other/vectorr.md"
> 

```include
other/vectorr.md
```

Charting the 1k sumTo:

>   let csr0 = fromIntegral <$> take 10000 (csr!!numChart) -- summing to 1000
>   let csr1 = (\x -> min x (trunc*deciles 5 csr0 !! 5)) <$> csr0
>   fileSvg "other/vector1k.svg" (750,250) $ pad 1.1 $ histLine csr1

![](other/vector1k.svg)

unboxed
---

>   !asu <- (fmap U.fromList <$>) <$> sequence $ (\x -> samples x uniform mwc) . floor <$> as
>   let sumu :: U.Vector Double -> Double
>       sumu x = U.foldl (+) 0 x
>   void $ warmup 100
>   (csu,_) <- spins n tick sumu asu
>   reportQuantiles csu as "other/vectoru.md"
> 

```include
other/vectoru.md
```

Charting the 1k sumTo:

>   let csu0 = fromIntegral <$> take 10000 (csu!!numChart) -- summing to 1000
>   let csu1 = (\x -> min x (trunc*deciles 5 csu0 !! 5)) <$> csu0
>   fileSvg "other/vectoru1k.svg" (750,250) $ pad 1.1 $ histLine csu1

![](other/vectoru1k.svg)

storable
---

>   !ass <- (fmap S.fromList <$>) <$> sequence $ (\x -> samples x uniform mwc) . floor <$> as
>   let sums :: S.Vector Double -> Double
>       sums x = S.foldl (+) 0 x
>   void $ warmup 100
>   (css,_) <- spins n tick sums ass
>   reportQuantiles css as "other/vectors.md"
> 

```include
other/vectors.md
```

Charting the 1k sumTo:

>   let css0 = fromIntegral <$> take 10000 (css!!numChart) -- summing to 1000
>   let css1 = (\x -> min x (trunc*deciles 5 css0 !! 5)) <$> css0
>   fileSvg "other/vectors1k.svg" (750,250) $ pad 1.1 $ histLine css1

![](other/vectors1k.svg)

tickf, ticka, tickfa
---

These functions attempt to discriminate between cycles used to compute `f a` (ie to apply the function f), and cycles used to force `a`.  In experiments so far, this act of observation tends to change the number of cycles.

Separation of the `f` and `a` effects in `f a`

>   void $ warmup 100
>   (csr2,_) <- spins n tick sumv asr
>   (csvf,_) <- spins n tickf sumv asr
>   (csva,_) <- spins n ticka sumv asr
>   (csvfa,_) <- spins n tickfa sumv asr
>   reportQuantiles csr2 as "other/vectorr2.md"
>   reportQuantiles csvf as "other/vectorf.md"
>   reportQuantiles csva as "other/vectora.md"
>   reportQuantiles (fmap fst <$> csvfa) as "other/vectorfaf.md"
>   reportQuantiles (fmap snd <$> csvfa) as "other/vectorfaa.md"
> 

a full tick

```include
other/vectorr2.md
```

just function application

```include
other/vectorf.md
```

just forcing `a`:

```include
other/vectora.md
```

the f splice of f a

```include
other/vectorfaf.md
```

the a slice of fa

```include
other/vectorfaa.md
```

>   pure ()
> 

helpers
---

> showxs :: [Double] -> Double -> Text
> showxs qs m =
>           sformat (" " % Formatting.expt 2) m <> ": " <>
>           mconcat (sformat (" " % prec 3) <$> ((/m) <$> qs))
> 
> deciles :: (Foldable f) => Int -> f Double -> [Double]
> deciles n xs =
>   (\x -> fromMaybe 0 $
>       quantile x (tdigest xs :: TDigest 25)) <$>
>       ((/fromIntegral n) . fromIntegral <$> [0..n]) :: [Double]
> 
> reportQuantiles ::  [[Cycles]] -> [Double] -> FilePath -> IO ()
> reportQuantiles css as name =
>   writeFile name $ code $ zipWith showxs (deciles 5 . fmap fromIntegral <$> css) as
> 
> code :: [Text] -> Text
> code cs = "\n~~~\n" <> intercalate "\n" cs <> "\n~~~\n"
> 
> histLine :: [Double] -> Chart' a
> histLine xs =
>     lineChart_ (repeat (LineConfig 0.002 (Color 0 0 1 0.1))) widescreen
>      (zipWith (\x y -> [Pair x 0,Pair x y]) [0..] xs) <>
>      axes
>      ( chartAspect .~ widescreen
>      $ chartRange .~ Just
>        (Ranges
>          (Range 0.0 (fromIntegral $ length xs))
>          (Range 0 (L.fold (L.Fold max 0 identity) xs)))
>      $ def)
