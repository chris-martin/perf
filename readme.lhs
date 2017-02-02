```
other/header.md
```

[perf](https://tonyday567.github.io/perf/index.html) [![Build Status](https://travis-ci.org/tonyday567/perf.png)](https://travis-ci.org/tonyday567/perf)
===

If you want to make stuff very fast in haskell, you need to dig down below the criterion abstraction-level and start counting cycles using the [rdtsc](https://en.wikipedia.org/wiki/Time_Stamp_Counter) register on x86.

> {-# LANGUAGE OverloadedStrings #-}
> import Protolude hiding ((%))
> import qualified Data.Text.IO as Text
> import qualified Data.Text as Text
> import Formatting
> import qualified Control.Foldl as L
> import Math.Combinatorics.Exact.Primes
> import Perf.Cycles
> import Perf.Quantiles
> import Control.Lens
> import Data.Default
> import qualified Data.Vector as V
> import qualified Data.Vector.Unboxed as U
> import Data.List
> import Linear
> import Data.Primitive.MutVar
>

main
---

> main :: IO ()
> main = do

`tick_` taps the register twice to get a sense of the cost.

>   onetick <- tick_
>   ticks <- replicateM 10 tick_
>   avtick <- replicateM 1000000 tick_
>   let average cs = L.fold ((/) <$> L.sum <*> L.genericLength) cs
>   Text.writeFile "other/onetick.md" $ code
>     [ "one tick_: " <> Text.pack (show onetick) <> " cycles"
>     , "next 10: " <> Text.pack (show ticks)
>     , "average over 1m: " <>
>       Text.pack (show $ average (fromIntegral <$> avtick)) <> " cycles"
>     ]
>
>

```include
other/onetick.md
```

It often makes sense to give tick_ a few spins before measuring something, to warm everything up.

A pattern I see on my machine are shifts by multiples of 4, which correspond to roughly the L1 [cache latency](http://stackoverflow.com/questions/1126529/what-is-the-cost-of-an-l1-cache-miss).

It pays to look at the whole distribution, and a compact way of doing that is to calculate quantiles:

>   _ <- warmup 100
>   xs' <- replicateM 10000 tick_
>   let xs = fromIntegral <$> xs' :: [Double]
>   let qs = L.fold (quantiles' 11) xs
>   writeFile "other/quantiles.md" $
>         "\n    [min, 10th, 20th, .. 90th, max]:" <>
>         mconcat (sformat (" " % prec 3) <$> qs)
>

```include
other/quantiles.md
```

The important cycle count for most work is around the 30th to 50th percentile, where you get a clean measure, hopefully free of cache missing.

The quantile print of tick_ often shows a 12 to 14 point jump around the 70th to 90th percential, and this is probably a L2 miss, and then a few large brain farts at around 2k cycles.

For reference, based on a 2.6G machine one cycle is = 0.38 𝛈s

spin
===

Let's measure something.  The simplest something I could think of was summing.

`spin` takes n measurements of whatever part you want to measure.

>   let f :: Double -> Double
>       f x = foldl' (+) 0 [1..x]
>   let ms = [1, 10, 100, 1000, 10000, 100000]
>   let n = 100
>   (xs, _) <- runTick f tick ms n "other/spin.md"
>

```include
other/spin.md
```

vector
---

Using vector to sum:

>   let f :: Double -> Double
>       f x = V.foldl (+) 0 $ V.replicate (floor x) 1
>   _ <- runTick f tickf ms n "other/vector1.md"
>

```include
other/vector1.md
```

unboxed vector
---

Using unboxed vector to sum Ints:

>   let f :: Double -> Double
>       f x = U.foldl' (+) (0::Double) $ U.replicate (floor x) 1
>   (xs, _) <- runTick f tickf ms n "other/vector2.md"
>

```include
other/vector2.md
```

the `!f` and the `!a`
---

Same unboxed Int vector, looking at `tickfa`:

>   _ <- warmup 100
>   let f x = U.foldl' (+) (0::Int) $ U.replicate x 1
>   let ms = [1, 10, 100, 1000, 10000, 100000]
>   let n = 100
>   res <- sequence $ spin n tickfa f <$> ms
>   res' <- sequence $ spin n tick f <$> ms
>   let xsf = fmap (fromIntegral . fst) <$> (fst <$> res) :: [[Double]]
>   let xsa = fmap (fromIntegral . snd) <$> (fst <$> res) :: [[Double]]
>   let xsb = fmap fromIntegral <$> (fst <$> res') :: [[Double]]
>   let qssf = L.fold (quantiles' 11) <$> xsf
>   let qssa = L.fold (quantiles' 11) <$> xsa
>   let qssb = L.fold (quantiles' 11) <$> xsb
>   let showxs :: [Double] -> Double -> Text
>       showxs qs m =
>           show m <> ": " <>
>           mconcat (sformat (" " % prec 3) <$> ((/m) <$> qs))
>   Text.writeFile "other/f.md" $ code $
>       zipWith showxs qssf (fromIntegral <$> ms)
>   Text.writeFile "other/a.md" $ code $
>       zipWith showxs qssa (fromIntegral <$> ms)
>   Text.writeFile "other/b.md" $ code $
>       zipWith showxs qssb (fromIntegral <$> ms)

function application effect

```include
other/f.md
```

instantiation effect

```include
other/a.md
```

both effects

```include
other/b.md
```

mutation
---

Mutable summer of Doubles:

>   _ <- warmup 100
>   let f x = L.foldM mutFold $ V.replicate x (1::Int)
>   let ms = [1, 10, 100, 1000, 10000, 100000]
>   let n = 100
>   res <- sequence $ spinM n tickfM f <$> ms
>   let xs = fmap fromIntegral <$> (fst <$> res) :: [[Double]]
>   let xsres = snd <$> res :: [Int]
>   print $ L.fold (L.Fold (+) 0 Protolude.identity) xsres
>   let qss = L.fold (quantiles' 11) <$> xs
>   let showxs :: [Double] -> Double -> Text
>       showxs qs m =
>           show m <> ": " <>
>           mconcat (sformat (" " % prec 3) <$> ((/m) <$> qs))
>   Text.writeFile "other/mutable.md" $ code $
>       zipWith showxs qss (fromIntegral <$> ms)
>

```include
other/mutable.md
```

I had to rewrite the code to actually use the eventual values, or else it's a noop in IO.

No major difference between mutability and immutablility. Something else is happening...


helpers
---

>
>
> runTick f t ms n name = do
>     _ <- warmup 100
>     res <- sequence $ spin n t f <$> ms
>     let xs = fmap fromIntegral <$> (fst <$> res) :: [[Double]]
>     let qs = L.fold (quantiles' 11) <$> xs
>     Text.writeFile name $ code $ zipWith showxs qs ms
>     return (qs, xs)
>   where
>       showxs :: [Double] -> Double -> Text
>       showxs qs m =
>           show m <> ": " <>
>           mconcat (sformat (" " % prec 3) <$> ((/m) <$> qs))
>
> code cs = mconcat $ (<> "\n") . ("    " <>) <$> cs
>

> mutFold :: L.FoldM IO Int Int
> mutFold = L.FoldM step begin done
>   where
>     step x a = modifyMutVar' x (+a) >> pure x
>     begin = newMutVar 0
>     done = readMutVar

rdpmc
---

A first-cousin of rdtsc, [rdpmc](https://software.intel.com/en-us/forums/software-tuning-performance-optimization-platform-monitoring/topic/595214), offers the possibility to track page faults, cache misses and other such beasties, but lacks an easy entry-point c library.

workflow
---

~~~
stack install && readme && pandoc -f markdown+lhs -t html -i readme.lhs -o index.html --filter pandoc-include
~~~

time
---

[Optimising haskell for a tight inner loop](http://neilmitchell.blogspot.co.uk/2014/01/optimising-haskell-for-tight-inner-loop.html)

[Tools for analysing performance](http://stackoverflow.com/questions/3276240/tools-for-analyzing-performance-of-a-haskell-program/3276557#3276557)

[Write haskell as fast as c](https://donsbot.wordpress.com/2008/05/06/write-haskell-as-fast-as-c-exploiting-strictness-laziness-and-recursion/)

[Reading ghc core](http://stackoverflow.com/questions/6121146/reading-ghc-core)

space
---

[Chasing space leaks in shake](http://neilmitchell.blogspot.com.au/2013/02/chasing-space-leak-in-shake.html)

[Space leak zoo](http://blog.ezyang.com/2011/05/space-leak-zoo/)

[Anatomy of a thunk leak](http://blog.ezyang.com/2011/05/anatomy-of-a-thunk-leak/)

[An insufficiently lazy map](http://blog.ezyang.com/2011/05/an-insufficiently-lazy-map/)

[Pinpointing space leaks in big programs](http://blog.ezyang.com/2011/06/pinpointing-space-leaks-in-big-programs/)

checklist
---

- compile with rtsopts flag

~~~
find . -name '*.o' -type f -print -delete
find . -name '*.hl' -type f -print -delete
ghc -O2 --make example/example.hs -fforce-recomp -isrc:example -rtsopts
~~~

- check GC

~~~
example +RTS -s
~~~

- enabling profiling

1. a normal ghc

~~~
    ghc -fforce-recomp --make -O2 -isrc example/example.hs
~~~

2. profile enabled automatically


~~~
  ghc -prof -auto -auto-all -fforce-recomp --make -O2 -isrc:dev A.hs
~~~

3. if template haskell

~~~
  ghc -osuf p_o -prof -auto -auto-all -fforce-recomp --make -O2 -isrc:dev A.hs
~~~


creates an A.prof on execution:

~~~
  time A +RTS -p
~~~

- visual-profile

~~~
  /Users/tonyday/git/VisualProf/dist/build/visual-prof/visual-prof -th dev/Reuters/A.hs dev/Reuters/A "test/data/reuters-100k.txt"
~~~

- space

~~~
  time dev/Reuters/A "test/data/reuters-100k.txt" +RTS -p -hc
  hp2ps -e8in -c A.hp
~~~

    hy = types
    hd = constructors

- strictness pragma?

~~~

  :: {-# UNPACK
~~~

- space leaks

~~~
+RTS -s - additional memory
+RTS -xt -hy
~~~

- example ghc command

~~~
  ghc -O2 &#x2013;make test/TestSerialize.hs -fforce-recomp -isrc:test -package-db .cabal-sandbox/\*-ghc-7.8.2-packages.conf.d/ -rtsopts -auto -auto-all -prof -threaded -main-is testBinaryController
~~~
