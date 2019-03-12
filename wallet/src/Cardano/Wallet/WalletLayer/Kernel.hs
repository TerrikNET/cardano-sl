{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE RankNTypes          #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications    #-}

module Cardano.Wallet.WalletLayer.Kernel
    ( bracketPassiveWallet
    , bracketActiveWallet
    ) where

import           Universum hiding (for_)

import qualified Control.Concurrent.STM as STM
import           Control.Monad.IO.Unlift (MonadUnliftIO)
import qualified Data.ByteString.Char8 as BS
import qualified Data.List.NonEmpty as NE
import qualified Data.Text as T

import           Data.Foldable (for_)
import           Formatting ((%))
import qualified Formatting as F

import           Pos.Chain.Block (Blund, blockHeader, headerHash, prevBlockL)
import           Pos.Chain.Genesis (Config (..))
import           Pos.Chain.Txp (TxIn, TxOutAux)
import           Pos.Chain.Txp (toaOut, txOutAddress, txOutValue)
import           Pos.Chain.Update (HasUpdateConfiguration)
import           Pos.Core.Chrono (OldestFirst (..))
import           Pos.Core.Common (Address, Coin, addrToBase58, mkCoin,
                     unsafeAddCoin)
import           Pos.Core.NetworkMagic (makeNetworkMagic)
import           Pos.Crypto (EncryptedSecretKey, ProtocolMagic)
import           Pos.Infra.InjectFail (FInjects)
import           Pos.Util.CompileInfo (HasCompileInfo)
import           Pos.Util.Wlog (Severity (Debug, Warning))

import           Cardano.Wallet.API.V1.Types (V1 (V1), WalletBalance (..))
import qualified Cardano.Wallet.Kernel as Kernel
import qualified Cardano.Wallet.Kernel.Actions as Actions
import qualified Cardano.Wallet.Kernel.BListener as Kernel
import           Cardano.Wallet.Kernel.DB.AcidState (dbHdWallets)
import           Cardano.Wallet.Kernel.DB.HdWallet (eskToHdRootId, getHdRootId,
                     hdAccountRestorationState, hdRootId, hdWalletsRoots)
import           Cardano.Wallet.Kernel.DB.InDb (fromDb)
import qualified Cardano.Wallet.Kernel.DB.Read as Kernel
import qualified Cardano.Wallet.Kernel.DB.Util.IxSet as IxSet
import           Cardano.Wallet.Kernel.Decrypt (WalletDecrCredentials,
                     decryptAddress, eskToWalletDecrCredentials)
import           Cardano.Wallet.Kernel.Diffusion (WalletDiffusion (..))
import           Cardano.Wallet.Kernel.Internal (walletNode,
                     walletProtocolMagic)
import           Cardano.Wallet.Kernel.Keystore (Keystore)
import           Cardano.Wallet.Kernel.NodeStateAdaptor
import qualified Cardano.Wallet.Kernel.Read as Kernel
import qualified Cardano.Wallet.Kernel.Restore as Kernel
import           Cardano.Wallet.WalletLayer (ActiveWalletLayer (..),
                     PassiveWalletLayer (..))
import qualified Cardano.Wallet.WalletLayer.Kernel.Accounts as Accounts
import qualified Cardano.Wallet.WalletLayer.Kernel.Active as Active
import qualified Cardano.Wallet.WalletLayer.Kernel.Addresses as Addresses
import qualified Cardano.Wallet.WalletLayer.Kernel.Info as Info
import qualified Cardano.Wallet.WalletLayer.Kernel.Internal as Internal
import qualified Cardano.Wallet.WalletLayer.Kernel.Settings as Settings
import qualified Cardano.Wallet.WalletLayer.Kernel.Transactions as Transactions
import qualified Cardano.Wallet.WalletLayer.Kernel.Wallets as Wallets

-- | Initialize the passive wallet.
-- The passive wallet cannot send new transactions.
bracketPassiveWallet
    :: forall m n a. (MonadIO n, MonadUnliftIO m, MonadMask m)
    => ProtocolMagic
    -> Kernel.DatabaseMode
    -> (Severity -> Text -> IO ())
    -> Keystore
    -> NodeStateAdaptor IO
    -> FInjects IO
    -> (PassiveWalletLayer n -> Kernel.PassiveWallet -> m a) -> m a
bracketPassiveWallet pm mode logFunction keystore node fInjects f = do
    Kernel.bracketPassiveWallet pm mode logFunction keystore node fInjects $ \w -> do

      -- For each wallet in a restoration state, re-start the background
      -- restoration tasks.
      liftIO $ do
          snapshot <- Kernel.getWalletSnapshot w
          let wallets = snapshot ^. dbHdWallets . hdWalletsRoots
          for_ wallets $ \root -> do
              let accts      = Kernel.accountsByRootId snapshot (root ^. hdRootId)
                  restoring  = IxSet.findWithEvidence hdAccountRestorationState accts

              whenJust restoring $ \(src, tgt) -> do
                  (w ^. Kernel.walletLogMessage) Warning $
                      F.sformat ("bracketPassiveWallet: continuing restoration of " %
                       F.build %
                       " from checkpoint " % F.build %
                       " with target "     % F.build)
                       (root ^. hdRootId) (maybe "(genesis)" pretty src) (pretty tgt)
                  Kernel.continueRestoration w root src tgt

      -- Start the wallet worker
      let wai = Actions.WalletActionInterp
                 { Actions.applyBlocks = \blunds -> do
                    ls <- mapM (Wallets.blundToResolvedBlock node)
                        (toList (getOldestFirst blunds))
                    let mp = catMaybes ls
                    mapM_ (Kernel.applyBlock w) mp

                 , Actions.switchToFork = \_ (OldestFirst blunds) -> do
                     -- Get the hash of the last main block before this fork.
                     let almostOldest = fst (NE.head blunds)
                     gh     <- configGenesisHash <$> getCoreConfig node
                     oldest <- withNodeState node $ \_lock ->
                                 mostRecentMainBlock gh
                                   (almostOldest ^. blockHeader . prevBlockL)

                     bs <- catMaybes <$> mapM (Wallets.blundToResolvedBlock node)
                                             (NE.toList blunds)

                     Kernel.switchToFork w (headerHash <$> oldest) bs

                 , Actions.emit = logFunction Debug
                 }
      Actions.withWalletWorker wai $ \invoke -> do
         f (passiveWalletLayer w invoke) w

  where
    passiveWalletLayer :: Kernel.PassiveWallet
                       -> (Actions.WalletAction Blund -> STM ())
                       -> PassiveWalletLayer n
    passiveWalletLayer w invoke = PassiveWalletLayer
        { -- Operations that modify the wallet
          createWallet         = Wallets.createWallet         w
        , updateWallet         = Wallets.updateWallet         w
        , updateWalletPassword = Wallets.updateWalletPassword w
        , deleteWallet         = Wallets.deleteWallet         w
        , createAccount        = Accounts.createAccount       w
        , updateAccount        = Accounts.updateAccount       w
        , deleteAccount        = Accounts.deleteAccount       w
        , createAddress        = Addresses.createAddress      w
        , importAddresses      = Addresses.importAddresses    w
        , addUpdate            = Internal.addUpdate           w
        , nextUpdate           = Internal.nextUpdate          w
        , applyUpdate          = Internal.applyUpdate         w
        , postponeUpdate       = Internal.postponeUpdate      w
        , waitForUpdate        = Internal.waitForUpdate       w
        , resetWalletState     = Internal.resetWalletState    w
        , importWallet         = Internal.importWallet        w
        , applyBlocks          = invokeIO . Actions.ApplyBlocks
        , rollbackBlocks       = invokeIO . Actions.RollbackBlocks . length

          -- Read-only operations
        , getWallets           =                   join (ro $ Wallets.getWallets w)
        , getWallet            = \wId           -> join (ro $ Wallets.getWallet w wId)
        , getUtxos             = \wId           -> ro $ Wallets.getWalletUtxos wId
        , getAccounts          = \wId           -> ro $ Accounts.getAccounts         wId
        , getAccount           = \wId acc       -> ro $ Accounts.getAccount          wId acc
        , getAccountBalance    = \wId acc       -> ro $ Accounts.getAccountBalance   wId acc
        , getAccountAddresses  = \wId acc rp fo -> ro $ Accounts.getAccountAddresses wId acc rp fo
        , getAddresses         = \rp            -> ro $ Addresses.getAddresses rp
        , validateAddress      = \txt           -> ro $ Addresses.validateAddress txt
        , getTransactions      = Transactions.getTransactions w
        , getTxFromMeta        = Transactions.toTransaction w
        , getNodeSettings      = Settings.getNodeSettings w
        , queryWalletBalance   = xqueryWalletBalance w
        }
      where
        -- Read-only operations
        ro :: (Kernel.DB -> x) -> n x
        ro g = g <$> liftIO (Kernel.getWalletSnapshot w)

        invokeIO :: forall m'. MonadIO m' => Actions.WalletAction Blund -> m' ()
        invokeIO = liftIO . STM.atomically . invoke

-- a variant of isOurs, that accepts a pre-derived WalletDecrCredentials, to save cpu cycles
fastIsOurs :: WalletDecrCredentials -> Address -> Bool
fastIsOurs wdc addr = case decryptAddress wdc addr of
  Just _  -> True
  Nothing -> False

-- takes a WalletDecrCredentials and transaction, and returns the Coin output, if its ours
maybeReadcoin :: WalletDecrCredentials -> (TxIn, TxOutAux) -> Maybe Coin
maybeReadcoin wdc (_, txout) = case fastIsOurs wdc (txOutAddress . toaOut $ txout) of
  True  -> Just $ (txOutValue . toaOut) txout
  False -> Nothing

-- take a EncryptedSecretKey and return the sum of all utxo in the state, and the walletid
xqueryWalletBalance :: Kernel.PassiveWallet -> EncryptedSecretKey -> IO WalletBalance
xqueryWalletBalance w esk = do
  let
    nm = makeNetworkMagic (w ^. walletProtocolMagic)
  let
    rootid = eskToHdRootId nm esk
    wdc = eskToWalletDecrCredentials nm esk
  let
    withNode :: (HasCompileInfo, HasUpdateConfiguration) => Lock (WithNodeState IO) -> WithNodeState IO [Coin]
    withNode _lock = filterUtxo (maybeReadcoin wdc)
  my_coins <- withNodeState (w ^. walletNode) withNode
  let
    balance :: Coin
    balance = foldl' unsafeAddCoin (mkCoin 0) my_coins
    walletid = addrToBase58 $ view fromDb (getHdRootId rootid)
  pure $ WalletBalance (V1 balance) (T.pack $ BS.unpack walletid)

-- | Initialize the active wallet.
-- The active wallet is allowed to send transactions, as it has the full
-- 'WalletDiffusion' layer in scope.
bracketActiveWallet
    :: forall m n a. (MonadIO m, MonadMask m, MonadIO n)
    => PassiveWalletLayer n
    -> Kernel.PassiveWallet
    -> WalletDiffusion
    -> (ActiveWalletLayer n -> Kernel.ActiveWallet -> m a) -> m a
bracketActiveWallet walletPassiveLayer passiveWallet walletDiffusion runActiveLayer =
    Kernel.bracketActiveWallet passiveWallet walletDiffusion $ \w -> do
        bracket
          (return (activeWalletLayer w))
          (\_ -> return ())
          (flip runActiveLayer w)
  where
    activeWalletLayer :: Kernel.ActiveWallet -> ActiveWalletLayer n
    activeWalletLayer w = ActiveWalletLayer {
          walletPassiveLayer = walletPassiveLayer
        , pay                = Active.pay              w
        , estimateFees       = Active.estimateFees     w
        , redeemAda          = Active.redeemAda        w
        , getNodeInfo        = Info.getNodeInfo        w
        }
