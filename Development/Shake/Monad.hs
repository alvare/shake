{-# LANGUAGE GeneralizedNewtypeDeriving #-}

module Development.Shake.Monad(
    RAW, runRAW, Capture, runCaptureRAW,
    getRO, getRW, getsRO, getsRW, putRW, modifyRW,
    withRO, withRW,
    catchRAW, tryRAW, throwRAW,
    evalRAW, unmodifyRW, captureRAW,
    ) where

import Control.Applicative
import Control.Concurrent
import Control.Exception as E
import Control.Monad
import Control.Monad.IO.Class
import Control.Monad.Trans.Cont
import Control.Monad.Trans.Reader
import Data.IORef


data S ro rw = S
    {handler :: IORef (SomeException -> IO ())
    ,ro :: ro
    ,rww :: IORef rw -- Read/Write Writeable var (rww)
    }

newtype RAW ro rw a = RAW {fromRAW :: ReaderT (S ro rw) (ContT () IO) a}
    deriving (Functor, Applicative, Monad, MonadIO)

type Capture a = (a -> IO ()) -> IO ()


-- | Run and then call a continuation.
runCaptureRAW :: ro -> rw -> RAW ro rw a -> Capture (Either SomeException a)
runCaptureRAW ro rw m k = do
    rww <- newIORef rw
    handler <- newIORef $ k . Left
    fromRAW m `runReaderT` S handler ro rww `runContT` (k . Right)
        `E.catch` \e -> ($ e) =<< readIORef handler


-- | Run on this thread until the first IO, then wait til the second.
runRAW :: ro -> rw -> RAW ro rw a -> IO (IO a)
runRAW ro rw m = do
    res <- newEmptyMVar
    runCaptureRAW ro rw m $ void . tryPutMVar res
    return $ either throwIO return =<< readMVar res


---------------------------------------------------------------------
-- STANDARD

getRO :: RAW ro rw ro
getRO = RAW $ asks ro

getRW :: RAW ro rw rw
getRW = RAW $ liftIO . readIORef =<< asks rww

getsRO :: (ro -> a) -> RAW ro rw a
getsRO f = fmap f getRO

getsRW :: (rw -> a) -> RAW ro rw a
getsRW f = fmap f getRW

-- | Strict version
putRW :: rw -> RAW ro rw ()
putRW rw = rw `seq` RAW $ liftIO . flip writeIORef rw =<< asks rww

withRAW :: (S ro rw -> S ro2 rw2) -> RAW ro2 rw2 a -> RAW ro rw a
withRAW f m = RAW $ withReaderT f $ fromRAW m

modifyRW :: (rw -> rw) -> RAW ro rw ()
modifyRW f = do x <- getRW; putRW $ f x

withRO :: (ro -> ro2) -> RAW ro2 rw a -> RAW ro rw a
withRO f = withRAW $ \s -> s{ro=f $ ro s}

withRW :: (rw -> rw2) -> RAW ro rw2 a -> RAW ro rw a
withRW f m = do
    rw <- getRW
    rww <- liftIO $ newIORef $ f rw
    withRAW (\s -> s{rww=rww}) m


---------------------------------------------------------------------
-- EXCEPTIONS

catchRAW :: RAW ro rw a -> (SomeException -> RAW ro rw a) -> RAW ro rw a
catchRAW m hdl = RAW $ ReaderT $ \s -> ContT $ \k -> do
    old <- readIORef $ handler s
    writeIORef (handler s) $ \e -> do
        writeIORef (handler s) old
        fromRAW (hdl $ toException e) `runReaderT` s `runContT` k `E.catch`
            \e -> ($ e) =<< readIORef (handler s)
    fromRAW m `runReaderT` s `runContT` \v -> do
        writeIORef (handler s) old
        k v


tryRAW :: RAW ro rw a -> RAW ro rw (Either SomeException a)
tryRAW m = catchRAW (fmap Right m) (return . Left)

throwRAW :: Exception e => e -> RAW ro rw a
throwRAW = liftIO . throwIO


---------------------------------------------------------------------
-- WEIRD STUFF

-- | Given an action, produce a 'RAW' that runs fast, containing
--   an 'IO' that runs slowly (the bulk of the work) and a 'RAW'
--   that runs fast. The resulting IO/RAW should each be run exactly once.
evalRAW :: RAW ro rw a -> RAW ro rw (IO (RAW ro rw a))
evalRAW m = do
    ro <- getRO
    rw <- getRW
    return $ do
        (a,rw) <- join $ runRAW ro rw $ liftA2 (,) m getRW
        return $ do
            putRW rw
            return a


-- | Apply a modification, run an action, then undo the changes after.
unmodifyRW :: (rw -> (rw, rw -> rw)) -> RAW ro rw a -> RAW ro rw a
unmodifyRW f m = do
    (s2,undo) <- fmap f getRW
    putRW s2
    res <- m
    modifyRW undo
    return res


-- | Capture a continuation. The continuation must be called exactly once, either with an
--   exception, or with a result.
captureRAW :: Capture (Either SomeException a) -> RAW ro rw a
captureRAW f = RAW $ ReaderT $ \s -> ContT $ \k -> do
    f $ \x -> case x of
        Left e -> do hdl <- readIORef (handler s); hdl e
        Right v -> k v `E.catch` \e -> ($ e) =<< readIORef (handler s)
