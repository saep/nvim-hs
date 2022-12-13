{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RecordWildCards #-}

{- |
Module      :  Neovim.RPC.FunctionCall
Description :  Functions for calling functions
Copyright   :  (c) Sebastian Witte
License     :  Apache-2.0

Maintainer  :  woozletoff@gmail.com
Stability   :  experimental
-}
module Neovim.RPC.FunctionCall (
    acall,
    scall,
    scall',
    scallThrow,
    atomically',
    wait,
    wait',
    respond,
) where

import Neovim.Classes
import Neovim.Context
import qualified Neovim.Context.Internal as Internal
import Neovim.Internal.RPC
import Neovim.Plugin.Classes (FunctionName)
import Neovim.Plugin.IPC.Classes
import qualified Neovim.RPC.Classes as MsgpackRPC

import Control.Applicative
import Control.Monad.Reader
import Data.MessagePack
import Data.Text (Text)

import UnliftIO (MonadUnliftIO, STM, atomically, newEmptyTMVarIO, readTMVar, throwIO)
import Prelude

-- | Helper function that concurrently puts a 'Message' in the event queue and returns an 'STM' action that returns the result.
acall ::
    (HasMsgpackRpcQueue m, MonadUnliftIO m, NvimObject result) =>
    FunctionName ->
    [Object] ->
    m (STM (Either NeovimException result))
acall fn parameters = do
    mv <- liftIO newEmptyTMVarIO
    timestamp <- liftIO getCurrentTime
    writeMsgpackRpcQueue q $ FunctionCall fn parameters mv timestamp
    return $ convertObject <$> readTMVar mv
  where
    convertObject ::
        (NvimObject result) =>
        Either Object Object ->
        Either NeovimException result
    convertObject = \case
        Left e -> Left $ ErrorResult (pretty fn) e
        Right o -> case fromObject o of
            Left e -> Left $ ErrorMessage e
            Right r -> Right r

{- | Call a neovim function synchronously. This function blocks until the
 result is available.
-}
scall ::
    (NvimObject result) =>
    FunctionName ->
    -- | Parameters in an 'Object' array
    [Object] ->
    -- | result value of the call or the thrown exception
    Neovim env (Either NeovimException result)
scall fn parameters = acall fn parameters >>= atomically'

-- | Similar to 'scall', but throw a 'NeovimException' instead of returning it.
scallThrow ::
    (NvimObject result) =>
    FunctionName ->
    [Object] ->
    Neovim env result
scallThrow fn parameters = scall fn parameters >>= either throwIO return

{- | Helper function similar to 'scall' that throws a runtime exception if the
 result is an error object.
-}
scall' :: NvimObject result => FunctionName -> [Object] -> Neovim env result
scall' fn = either throwIO pure <=< scall fn

-- | Lifted variant of 'atomically'.
atomically' :: (MonadIO io) => STM result -> io result
atomically' = liftIO . atomically

{- | Wait for the result of the STM action.

 This action possibly blocks as it is an alias for
 @ \ioSTM -> ioSTM >>= liftIO . atomically@.
-}
wait :: Neovim env (STM result) -> Neovim env result
wait = (=<<) atomically'

-- | Variant of 'wait' that discards the result.
wait' :: Neovim env (STM result) -> Neovim env ()
wait' = void . wait

-- | Send the result back to the neovim instance.
respond ::
    (HasMsgpackRpcQueue m, MonadUnliftIO m, NvimObject result) =>
    MsgpackRequest ->
    Either Text result ->
    m ()
respond MsgpackRequest{..} result =
    writeMsgpackRpcQueue $
        Response
            MsgpackResponse
                { responseRequestId = requestId
                , responseResult = toObject <$> result
                }
