{-| This module provides @pipes@ utilities for \"byte streams\", which are
    streams of strict 'BS.ByteString's chunks.  Use byte streams to interact
    with both 'Handle's and lazy 'ByteString's.

    To stream from 'Handle's, use 'readHandleS' or 'writeHandleD' to convert
    them into the equivalent proxies.  For example, the following program copies
    data from one file to another:

> import Control.Proxy
> import Pipes.ByteString
>
> main =
>     withFile "inFile.txt"  ReadMode  $ \hIn  ->
>     withFile "outFile.txt" WriteMode $ \hOut ->
>     runProxy $ readHandleS hIn >-> writeHandleD hOut

    You can also stream to and from 'stdin' and 'stdout' using the predefined
    'stdinS' and 'stdoutD' proxies, like in the following \"echo\" program:

> main = runProxy $ stdinS >-> stdoutD

    You can also translate pure lazy 'BL.ByteString's to and from proxies:

> import qualified Data.ByteString.Lazy.Char8 as BL
>
> main = runProxy $ fromLazyS (BL.pack "Hello, world!\n") >-> stdoutD

    In addition, this module provides many functions equivalent to lazy
    'ByteString' functions so that you can transform byte streams.
-}

module Pipes.ByteString (
    -- * Introducing and Eliminating ByteStrings
    fromLazy,
    toLazy,

    -- * Basic Interface
    Pipes.ByteString.head,
    head_,
    Pipes.ByteString.last,
    Pipes.ByteString.tail,
    Pipes.ByteString.init,
    Pipes.ByteString.null,
    null_,
    Pipes.ByteString.length,

    -- * Transforming ByteStrings
    Pipes.ByteString.map,
    intersperse,

    -- * Reducing ByteStrings (folds)
    foldl',
    Pipes.ByteString.foldr,

    -- ** Special folds
    Pipes.ByteString.concatMap,
    Pipes.ByteString.any,
    any_,
    Pipes.ByteString.all,
    all_,

    -- * Substrings
    -- ** Breaking strings
    Pipes.ByteString.take,
    Pipes.ByteString.drop,
    Pipes.ByteString.takeWhile,
    Pipes.ByteString.dropWhile,
    group,
    groupBy,

    -- ** Breaking into many substrings
    split,
    splitWith,

    -- * Searching ByteStrings
    -- ** Searching by equality
    Pipes.ByteString.elem,
    elem_,
    Pipes.ByteString.notElem,

    -- ** Searching with a predicate
    find,
    find_,
    Pipes.ByteString.filter,

    -- * Indexing ByteStrings
    index,
    index_,
    elemIndex,
    elemIndex_,
    elemIndices,
    findIndex,
    findIndex_,
    findIndices,
    count,

    -- * I/O with ByteStrings
    -- ** Standard input and output
    Pipes.ByteString.stdin,
    Pipes.ByteString.stdout,

    -- ** I/O with Handles
    readHandle,
    writeHandle,
    hGetSome,
    hGetSome_,
    hGet,
    hGet_,

    -- * Parsers
    drawAllBytes,
    passBytesUpTo,
    drawBytesUpTo,
    skipBytesUpTo
    ) where

import Control.Monad (forever)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Writer.Strict (WriterT, tell)
import Control.Monad.Trans.State.Strict (StateT(..))
import Pipes ((>->))
import qualified Pipes as P
import qualified Pipes.Prelude as P
import Control.Proxy.Parse (draw, unDraw, drawAll)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString.Lazy.Internal as BLI
import qualified Data.ByteString.Unsafe as BU
import Data.Foldable (forM_)
import qualified Data.Monoid as M
import Data.Int (Int64)
import Data.Word (Word8)
import System.IO (Handle, hIsEOF, stdin, stdout)

{-| Convert a lazy 'BL.ByteString' into a 'P.Producer' of strict
    'BS.ByteString's

> fromLazy
>  :: (Monad m, Proxy p)
>  => Lazy.ByteString -> () -> Producer p Strict.ByteString m ()
-}
fromLazy
    :: Monad m => BL.ByteString -> r -> P.Proxy x' x y' BS.ByteString m r
fromLazy bs r =
    BLI.foldrChunks (\e a -> P.respond e >> a) (return r) bs

{-| Fold strict 'BS.ByteString's flowing \'@D@\'ownstream into a lazy
    'BL.ByteString'.

    The fold generates a difference 'BL.ByteString' that you must apply to
    'BS.empty'.

> toLazy
>     :: Monad m
>     => () -> Pipe (WriterT (Endo Lazy.ByteString)) p Strict.ByteString Strict.ByteString m r
-}
toLazy
    :: Monad m
    => () -> P.Proxy () BS.ByteString () BS.ByteString (WriterT (M.Endo BL.ByteString) m) r
toLazy = P.foldr BLI.Chunk

-- | Store the 'M.First' 'Word8' that flows \'@D@\'ownstream
head
    :: Monad m
    => () -> P.Proxy () BS.ByteString () BS.ByteString (WriterT (M.First Word8) m) r
head = P.fold (\bs -> M.First $
    if (BS.null bs)
        then Nothing
        else Just $ BU.unsafeHead bs )

{-| Store the 'M.First' 'Word8' that flows \'@D@\'ownstream

    Terminates after receiving a single 'Word8'. -}
head_
    :: Monad m
    => x -> P.Proxy x BS.ByteString x BS.ByteString (WriterT (M.First Word8) m) ()
head_ = go where
    go x = do
        bs <- P.request x
        if (BS.null bs)
            then do
                x2 <- P.respond bs
                go x2
            else lift . tell . M.First . Just $ BU.unsafeHead bs

-- | Store the 'M.Last' 'Word8' that flows \'@D@\'ownstream
last
    :: Monad m
    => () -> P.Proxy () BS.ByteString () BS.ByteString (WriterT (M.Last Word8) m) r
last = P.fold (\bs -> M.Last $
    if (BS.null bs)
        then Nothing
        else Just $ BS.last bs )

-- | Drop the first byte in the stream
tail :: Monad m => x -> P.Proxy x BS.ByteString x BS.ByteString m r
tail = go where
    go x = do
        bs <- P.request x
        if (BS.null bs)
            then do
                x2 <- P.respond bs
                go x2
            else do
                x2 <- P.respond (BU.unsafeTail bs)
                P.pull x2

-- | Pass along all but the last byte in the stream
init :: Monad m => x -> P.Proxy x BS.ByteString x BS.ByteString m r
init = go0 where
    go0 x = do
        bs <- P.request x
        if (BS.null bs)
            then do
                x2 <- P.respond bs
                go0 x2
            else do
                x2 <- P.respond (BS.init bs)
                go1 (BS.last bs) x2
    go1 w8 x = do
        bs <- P.request x
        if (BS.null bs)
            then do
                x2 <- P.respond bs
                go1 w8 x2
            else do
                x2 <- P.respond (BS.cons w8 (BS.init bs))
                go1 (BS.last bs) x2

-- | Store whether 'M.All' received 'ByteString's are empty
null
    :: Monad m
    => () -> P.Proxy () BS.ByteString () BS.ByteString (WriterT M.All m) r
null = P.fold (M.All . BS.null)

{-| Store whether 'M.All' received 'ByteString's are empty

    'null_' terminates on the first non-empty 'ByteString'. -}
null_
    :: Monad m
    => () -> P.Proxy () BS.ByteString () BS.ByteString (WriterT M.All m) ()
null_ = go where
    go x = do
        bs <- P.request x
        if (BS.null bs)
            then do
                x2 <- P.respond bs
                go x2
            else lift $ tell (M.All False)

-- | Store the length of all input flowing \'@D@\'ownstream
length
    :: Monad m
    => () -> P.Proxy () BS.ByteString () BS.ByteString (WriterT (M.Sum Int) m) r
length = P.fold (M.Sum . BS.length)

-- | Apply a transformation to each 'Word8' in the stream
map
    :: Monad m
    => (Word8 -> Word8) -> () -> P.Proxy () BS.ByteString () BS.ByteString m r
map f = P.map (BS.map f)

-- | Intersperse a 'Word8' between each byte in the stream
intersperse
    :: Monad m
    => Word8 -> () -> P.Proxy () BS.ByteString () BS.ByteString m r
intersperse w8 = go0 where
    go0 x = do
        bs0 <- P.request x
        x2  <- P.respond (BS.intersperse w8 bs0)
        go1 x2
    go1 x = do
        bs <- P.request x
        x2 <- P.respond (BS.cons w8 (BS.intersperse w8 bs))
        go1 x2

-- | Reduce the stream of bytes using a strict left fold
foldl'
    :: Monad m
    => (s -> Word8 -> s) -> x -> P.Proxy x BS.ByteString x BS.ByteString (StateT s m) r
foldl' f = go
  where
    go x = do
        bs <- P.request x
        lift (StateT $ \s ->
                let s' = BS.foldl' f s bs
                in s' `seq` return ((), s'))
        x2 <- P.respond bs
        go x2

-- | Reduce the stream of bytes using a right fold
foldr
    :: Monad m
    => (Word8 -> w -> w)
    -> () -> P.Proxy () BS.ByteString () BS.ByteString (WriterT (M.Endo w) m) r
foldr f = P.foldr (\e w -> BS.foldr f w e)

-- | Map a function over the byte stream and concatenate the results
concatMap
    :: Monad m
    => (Word8 -> BS.ByteString) -> () -> P.Proxy () BS.ByteString () BS.ByteString m r
concatMap f = P.map (BS.concatMap f)

-- | Fold that returns whether 'M.Any' received 'Word8's satisfy the predicate
any
    :: Monad m
    => (Word8 -> Bool)
    -> () -> P.Proxy () BS.ByteString () BS.ByteString (WriterT M.Any m) r
any pred = P.fold (M.Any . BS.any pred)

{-| Fold that returns whether 'M.Any' received 'Word8's satisfy the predicate

    'anyD_' terminates on the first 'Word8' that satisfies the predicate. -}
any_
    :: Monad m
    => (Word8 -> Bool)
    -> x -> P.Proxy x BS.ByteString x BS.ByteString (WriterT M.Any m) ()
any_ pred = go where
    go x = do
        bs <- P.request x
        if (BS.any pred bs)
            then lift $ tell (M.Any True)
            else do
                x2 <- P.respond bs
                go x2

-- | Fold that returns whether 'M.All' received 'Word8's satisfy the predicate
all
    :: Monad m
    => (Word8 -> Bool)
    -> () -> P.Proxy () BS.ByteString () BS.ByteString (WriterT M.All m) r
all pred = P.fold (M.All . BS.all pred)

{-| Fold that returns whether 'M.All' received 'Word8's satisfy the predicate

    'allD_' terminates on the first 'Word8' that fails the predicate. -}
all_
    :: Monad m
    => (Word8 -> Bool)
    -> x -> P.Proxy x BS.ByteString x BS.ByteString (WriterT M.All m) ()
all_ pred = go where
    go x = do
        bs <- P.request x
        if (BS.all pred bs)
            then do
                x2 <- P.respond bs
                go x2
            else lift $ tell (M.All False)

{-
newtype Maximum a = Maximum { getMaximum :: Maybe a }

instance (Ord a) => Monoid (Maximum a) where
    mempty = Maximum Nothing
    mappend m1 (Maximum Nothing) = m1
    mappend (Maximum Nothing) m2 = m2
    mappend (Maximum (Just a1)) (Maximum (Just a2)) = Maximum (Just (max a1 a2))

maximumD
 :: Monad m
 => x -> p x BS.ByteString x BS.ByteString (WriterT (Maximum Word8) m) r
maximumD = P.fold (\bs -> Maximum $
    if (BS.null bs)
        then Nothing
        else Just $ BS.maximum bs )

newtype Minimum a = Minimum { getMinimum :: Maybe a }

instance (Ord a) => Monoid (Minimum a) where
    mempty = Minimum Nothing
    mappend m1 (Minimum Nothing) = m1
    mappend (Minimum Nothing) m2 = m2
    mappend (Minimum (Just a1)) (Minimum (Just a2)) = Minimum (Just (min a1 a2))

minimumD
 :: Monad m
 => x -> p x BS.ByteString x BS.ByteString (WriterT (Minimum Word8) m) r
minimumD = P.fold (\bs -> Minimum $
    if (BS.null bs)
        then Nothing
        else Just $ BS.minimum bs )
-}

-- | @(takeD n)@ only allows @n@ bytes to flow \'@D@\'ownstream
take
    :: Monad m
    => Int64 -> x -> P.Proxy x BS.ByteString x BS.ByteString m ()
take n0 = go n0 where
    go n
        | n <= 0 = \_ -> return ()
        | otherwise = \x -> do
            bs <- P.request x
            let len = fromIntegral $ BS.length bs
            if (len > n)
                then do
                    P.respond (BU.unsafeTake (fromIntegral n) bs)
                    return ()
                else do
                    x2 <- P.respond bs
                    go (n - len) x2

-- | @(dropD n)@ drops the first @n@ bytes flowing \'@D@\'ownstream
drop
    :: Monad m
    => Int64 -> () -> P.Pipe BS.ByteString BS.ByteString m r
drop n0 () = go n0 where
    go n
        | n <= 0 = P.pull ()
        | otherwise = do
            bs <- P.request ()
            let len = fromIntegral $ BS.length bs
            if (len >= n)
                then do
                    P.respond (BU.unsafeDrop (fromIntegral n) bs)
                    P.pull ()
                else go (n - len)

-- | Take bytes until they fail the predicate
takeWhile
    :: Monad m
    => (Word8 -> Bool) -> x -> P.Proxy x BS.ByteString x BS.ByteString m ()
takeWhile pred = go where
    go x = do
        bs <- P.request x
        case BS.findIndex (not . pred) bs of
            Nothing -> do
                x2 <- P.respond bs
                go x2
            Just i -> do
                P.respond (BU.unsafeTake i bs)
                return ()

-- | Drop bytes until they fail the predicate
dropWhile
    :: Monad m
    => (Word8 -> Bool) -> () -> P.Pipe BS.ByteString BS.ByteString m r
dropWhile pred () = go where
    go = do
        bs <- P.request ()
        case BS.findIndex (not . pred) bs of
            Nothing -> go
            Just i -> do
                P.respond (BU.unsafeDrop i bs)
                P.pull ()

-- | Group 'Nothing'-delimited streams of bytes into segments of equal bytes
group
    :: Monad m
    => () -> P.Pipe (Maybe BS.ByteString) BS.ByteString m r
group = groupBy (==)

{-| Group 'Nothing'-delimited streams of bytes using the supplied equality
    function -}
groupBy
    :: Monad m
    => (Word8 -> Word8 -> Bool)
    -> () -> P.Pipe (Maybe BS.ByteString) BS.ByteString m r
groupBy eq () = go1 where
    go1 = do
        mbs <- P.request ()
        case mbs of
            Nothing -> go1
            Just bs
                | BS.null bs -> go1
                | otherwise -> do
                    let groups = BS.groupBy eq bs
                    mapM_ P.respond (Prelude.init groups)
                    go2 (Prelude.last groups)
    go2 group0 = do
        mbs <- P.request ()
        case mbs of
            Nothing -> do
                P.respond group0
                go1
            Just bs
                | BS.null bs -> go2 group0
                | otherwise -> do
                    let groups = BS.groupBy eq bs
                    case groups of
                        []              -> go2 group0
                        [group1]        -> go2 (BS.append group0 group1)
                        gs@(group1:gs') -> do
                            if (BS.head group0 == BS.head group1)
                                then do
                                    P.respond (BS.append group0 group1)
                                    mapM_ P.respond (Prelude.init gs')
                                    go2 (Prelude.last gs')
                                else do
                                    P.respond group0
                                    mapM_ P.respond (Prelude.init gs )
                                    go2 (Prelude.last gs )

-- | Split 'Nothing'-delimited streams of bytes using the given 'Word8' boundary
split
    :: Monad m
    => Word8 -> () -> P.Pipe (Maybe BS.ByteString) BS.ByteString m r
split w8 = splitWith (w8 ==)

{-| Split 'Nothing'-delimited streams of bytes using the given predicate to
    define boundaries -}
splitWith
    :: Monad m
    => (Word8 -> Bool) -> () -> P.Pipe (Maybe BS.ByteString) BS.ByteString m r
splitWith pred () = go1 where
    go1 = do
        mbs <- P.request ()
        case mbs of
            Nothing -> go1
            Just bs -> case BS.splitWith pred bs of
                [] -> go1
                gs -> do
                    mapM_ P.respond (Prelude.init gs)
                    go2 (Prelude.last gs)
    go2 group0 = do
        mbs <- P.request ()
        case mbs of
            Nothing -> do
                P.respond group0
                go1
            Just bs -> case BS.splitWith pred bs of
                []        -> go2 group0
                [group1]  -> go2 (BS.append group0 group1)
                group1:gs -> do
                    P.respond (BS.append group0 group1)
                    mapM_ P.respond (Prelude.init gs)
                    go2 (Prelude.last gs)

-- | Store whether 'M.Any' element in the byte stream matches the given 'Word8'
elem
    :: Monad m
    => Word8 -> () -> P.Proxy () BS.ByteString () BS.ByteString (WriterT M.Any m) r
elem w8 = P.fold (M.Any . BS.elem w8)

{-| Store whether 'M.Any' element in the byte stream matches the given 'Word8'

    'elemD_' terminates once a single 'Word8' matches the predicate. -}
elem_
    :: Monad m
    => Word8 -> x -> P.Proxy x BS.ByteString x BS.ByteString (WriterT M.Any m) ()
elem_ w8 = go where
    go x = do
        bs <- P.request x
        if (BS.elem w8 bs)
            then lift $ tell (M.Any True)
            else do
                x2 <- P.respond bs
                go x2

{-| Store whether 'M.All' elements in the byte stream do not match the given
    'Word8' -}
notElem
    :: Monad m
    => Word8 -> () -> P.Proxy () BS.ByteString () BS.ByteString (WriterT M.All m) r
notElem w8 = P.fold (M.All . BS.notElem w8)

-- | Store the 'M.First' element in the stream that matches the predicate
find
    :: Monad m
    => (Word8 -> Bool)
    -> () -> P.Proxy () BS.ByteString () BS.ByteString (WriterT (M.First Word8) m) r
find pred = P.fold (M.First . BS.find pred)

{-| Store the 'M.First' element in the stream that matches the predicate

    'findD_' terminates when a 'Word8' matches the predicate -}
find_
    :: Monad m
    => (Word8 -> Bool)
    -> x -> P.Proxy x BS.ByteString x BS.ByteString (WriterT (M.First Word8) m) ()
find_ pred = go where
    go x = do
        bs <- P.request x
        case BS.find pred bs of
            Nothing -> do
                x2 <- P.respond bs
                go x2
            Just w8 -> lift . tell . M.First $ Just w8

-- | Only allows 'Word8's to pass if they satisfy the predicate
filter
    :: Monad m
    => (Word8 -> Bool) -> () -> P.Proxy () BS.ByteString () BS.ByteString m r
filter pred = P.map (BS.filter pred)

-- | Stores the element located at a given index, starting from 0
index
    :: Monad m
    => Int64
    -> x -> P.Proxy x BS.ByteString x BS.ByteString (WriterT (M.First Word8) m) r
index n = go n where
    go n x = do
        bs <- P.request x
        let len = fromIntegral $ BS.length bs
        if (len <= n)
            then do
                x2 <- P.respond bs
                go (n - len) x2
            else do
                lift . tell . M.First . Just . BS.index bs $ fromIntegral n
                x2 <- P.respond bs
                P.pull x2

{-| Stores the element located at a given index, starting from 0

    'indexD_' terminates once it reaches the given index. -}
index_
    :: Monad m
    => Int64
    -> x -> P.Proxy x BS.ByteString x BS.ByteString (WriterT (M.First Word8) m) ()
index_ n = go n where
    go n x = do
        bs <- P.request x
        let len = fromIntegral $ BS.length bs
        if (len <= n)
            then do
                x2 <- P.respond bs
                go (n - len) x2
            else lift . tell . M.First . Just . BS.index bs $ fromIntegral n

-- | Stores the 'M.First' index of an element that matches the given 'Word8'
elemIndex
    :: Monad m
    => Word8
    -> x -> P.Proxy x BS.ByteString x BS.ByteString (WriterT (M.First Int64) m) r
elemIndex w8 = go 0 where
    go n x = do
        bs <- P.request x
        case BS.elemIndex w8 bs of
            Nothing -> do
                x2 <- P.respond bs
                go (n + fromIntegral (BS.length bs)) x2
            Just i  -> do
                lift . tell . M.First . Just $ n + fromIntegral i
                x2 <- P.respond bs
                P.pull x2

{-| Stores the 'M.First' index of an element that matches the given 'Word8'

    'elemIndexD_' terminates when it encounters a matching 'Word8' -}
elemIndex_
    :: Monad m
    => Word8
    -> x -> P.Proxy x BS.ByteString x BS.ByteString (WriterT (M.First Int64) m) ()
elemIndex_ w8 = go 0 where
    go n x = do
        bs <- P.request x
        case BS.elemIndex w8 bs of
            Nothing -> do
                x2 <- P.respond bs
                go (n + fromIntegral (BS.length bs)) x2
            Just i  -> lift . tell . M.First . Just $ n + fromIntegral i

-- | Store a list of all indices whose elements match the given 'Word8'
elemIndices
    :: Monad m
    => Word8
    -> () -> P.Proxy () BS.ByteString () BS.ByteString (WriterT [Int64] m) r
elemIndices w8 = P.fold (Prelude.map fromIntegral . BS.elemIndices w8)

-- | Store the 'M.First' index of an element that satisfies the predicate
findIndex
    :: Monad m
    => (Word8 -> Bool)
    -> x -> P.Proxy x BS.ByteString x BS.ByteString (WriterT (M.First Int64) m) r
findIndex pred = go 0 where
    go n x = do
        bs <- P.request x
        case BS.findIndex pred bs of
            Nothing -> do
                x2 <- P.respond bs
                go (n + fromIntegral (BS.length bs)) x2
            Just i  -> do
                lift . tell . M.First . Just $ n + fromIntegral i
                x2 <- P.respond bs
                P.pull x2

{-| Store the 'M.First' index of an element that satisfies the predicate

    'findIndexD_' terminates when an element satisfies the predicate -}
findIndex_
    :: Monad m
    => (Word8 -> Bool)
    -> x -> P.Proxy x BS.ByteString x BS.ByteString (WriterT (M.First Int64) m) ()
findIndex_ pred = go 0 where
    go n x = do
        bs <- P.request x
        case BS.findIndex pred bs of
            Nothing -> do
                x2 <- P.respond bs
                go (n + fromIntegral (BS.length bs)) x2
            Just i  -> lift . tell . M.First . Just $ n + fromIntegral i

-- | Store a list of all indices whose elements satisfy the given predicate
findIndices
    :: Monad m
    => (Word8 -> Bool)
    -> x -> P.Proxy x BS.ByteString x BS.ByteString (WriterT [Int64] m) r
findIndices pred = go 0 where
    go n x = do
        bs <- P.request x
        lift . tell . Prelude.map (\i -> n + fromIntegral i) $
          BS.findIndices pred bs
        x2 <- P.respond bs
        go (n + fromIntegral (BS.length bs)) x2

-- | Store a tally of how many elements match the given 'Word8'
count
    :: Monad m
    => Word8 -> () -> P.Proxy () BS.ByteString () BS.ByteString (WriterT (M.Sum Int64) m) r
count w8 = P.fold (M.Sum . fromIntegral . BS.count w8)

-- | Stream bytes from 'stdin'
stdin :: () -> P.Producer BS.ByteString IO ()
stdin = readHandle System.IO.stdin

-- | Stream bytes to 'stdout'
stdout :: x -> P.Proxy x BS.ByteString x BS.ByteString IO ()
stdout = writeHandle System.IO.stdout

-- | Convert a 'Handle' into a byte stream
readHandle :: Handle -> () -> P.Producer BS.ByteString IO ()
readHandle = hGetSome BLI.defaultChunkSize

-- | Convert a byte stream into a 'Handle'
writeHandle
    :: Handle -> x -> P.Proxy x BS.ByteString x BS.ByteString IO ()
writeHandle h x = P.request x >>= lift . BS.hPut h

-- | Convert a handle into a byte stream using a fixed chunk size
hGetSome
    :: Int -> Handle -> () -> P.Producer BS.ByteString IO ()
hGetSome size h () = go where
    go = do
        eof <- lift $ hIsEOF h
        if eof
            then return ()
            else do
                bs <- lift $ BS.hGetSome h size
                P.respond bs
                go

-- | Convert a handle into a byte stream that serves variable chunk sizes
hGetSome_ :: Handle -> Int -> P.Server Int BS.ByteString IO ()
hGetSome_ h = go where
    go size = do
        eof <- lift $ hIsEOF h
        if eof
            then return ()
            else do
                bs <- lift $ BS.hGetSome h size
                size2 <- P.respond bs
                go size2

-- | Convert a handle into a byte stream using a fixed chunk size
hGet
    :: Int -> Handle -> () -> P.Producer BS.ByteString IO ()
hGet size h () = go where
    go = do
        eof <- lift $ hIsEOF h
        if eof
            then return ()
            else do
                bs <- lift $ BS.hGet h size
                P.respond bs
                go

-- | Convert a handle into a byte stream that serves variable chunk sizes
hGet_ :: Handle -> Int -> P.Server Int BS.ByteString IO ()
hGet_ h = go where
    go size = do
        eof <- lift $ hIsEOF h
        if eof
            then return ()
            else do
                bs <- lift $ BS.hGet h size
                size2 <- P.respond bs
                go size2

-- | @drawAllBytes@ folds all input bytes, both upstream and in the pushback
-- buffer, into a single strict 'BS.ByteString'
drawAllBytes
    :: Monad m
    => ()
    -> P.Proxy () (Maybe BS.ByteString) y' y (StateT [BS.ByteString] m) BS.ByteString
drawAllBytes = fmap BS.concat . drawAll

-- | @passBytesUpTo n@ responds with at-most @n@ bytes from upstream and the
-- pushback buffer.
passBytesUpTo
    :: Monad m
    => Int
    -> ()
    -> P.Pipe (Maybe BS.ByteString) (Maybe BS.ByteString) (StateT [BS.ByteString] m) r
passBytesUpTo n0 = \() -> go n0
  where
    go n =
        if (n <= 0)
        then forever $ P.respond Nothing
        else do
            mbs <- draw
            case mbs of
                Nothing -> forever $ P.respond Nothing
                Just bs -> do
                    let len = BS.length bs
                    if (len <= n)
                        then do
                            P.respond (Just bs)
                            go (n - len)
                        else do
                            let (prefix, suffix) = BS.splitAt n bs
                            unDraw suffix
                            P.respond (Just prefix)
                            forever $ P.respond Nothing

-- Draw at most @n@ bytes from both upstream and the pushback buffer.
drawBytesUpTo :: Monad m =>
    Int -> P.Proxy () (Maybe BS.ByteString) y' y (StateT [BS.ByteString] m) BS.ByteString
drawBytesUpTo n = (passBytesUpTo n >-> const go) ()
  where
    go = P.request () >>= maybe (return BS.empty) (\x -> fmap (BS.append x) go)

-- Skip at most @n@ bytes from both upstream and the pushback buffer.
skipBytesUpTo :: Monad m =>
    Int -> P.Proxy () (Maybe BS.ByteString) y' y (StateT [BS.ByteString] m) ()
skipBytesUpTo n = (passBytesUpTo n >-> const go) ()
  where go = P.request () >>= maybe (return ()) (const go)
