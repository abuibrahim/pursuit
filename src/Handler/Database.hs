
module Handler.Database
  ( lookupPackage
  , availableVersionsFor
  , insertPackage
  , insertPendingVerification
  , verifyPackage
  , verificationKeyExists
  , VerifyResult(..)
  , generateKey
  ) where

import Import
import qualified Data.Aeson as A
import qualified Data.ByteString.Char8 as BC8
import qualified Data.ByteString.Lazy as BL
import qualified Data.Text as T
import Data.Version (Version, showVersion)
import Crypto.Random
import qualified Data.ByteString.Base64.URL as Base64
import System.Directory (doesDirectoryExist, doesFileExist,
                         getDirectoryContents, createDirectoryIfMissing,
                         removeFile)
import System.FilePath (takeDirectory)

import Web.Bower.PackageMeta (PackageName, runPackageName)
import qualified Language.PureScript.Docs as D

lookupPackage :: PackageName -> Version -> Handler (Maybe D.VerifiedPackage)
lookupPackage pkgName version = do
  file <- packageVersionFileFor pkgName version
  mcontents <- liftIO (readFileMay file)
  case mcontents of
    Nothing       -> return Nothing
    Just contents -> Just <$> decodeVerifiedPackageFile file contents

availableVersionsFor :: PackageName -> Handler (Maybe [Version])
availableVersionsFor pkgName = do
  dir <- packageDirFor pkgName
  exists <- liftIO (doesDirectoryExist dir)
  if (not exists)
    then return Nothing
    else do
      files <- liftIO (getDirectoryContents dir)
      return $ Just $ mapMaybe (stripSuffix ".json" >=> D.parseVersion') files

-- | Insert a package at a specific version into the database.
insertPackage :: D.VerifiedPackage -> Handler ()
insertPackage pkg@D.Package{..} = do
  let pkgName = D.packageName pkg
  file <- packageVersionFileFor pkgName pkgVersion
  liftIO $ do
    createDirectoryIfMissing True (takeDirectory file)
    BL.writeFile file (A.encode pkg)

-- | Insert an uploaded package, pending verification. The second argument
-- is the verification key, which is also used as the file name.
insertPendingVerification :: D.UploadedPackage -> VerificationKey -> Handler ()
insertPendingVerification pkg key = do
  file <- pendingVerificationFileFor key
  liftIO $ do
    createDirectoryIfMissing True (takeDirectory file)
    BL.writeFile file (A.encode pkg)

verificationKeyExists :: VerificationKey -> Handler Bool
verificationKeyExists key = do
  file <- pendingVerificationFileFor key
  liftIO (doesFileExist file)

verifyPackage :: VerificationKey -> D.GithubUser -> Handler VerifyResult
verifyPackage key user = do
  file <- pendingVerificationFileFor key
  mcontents <- liftIO (readFileMay file)
  case mcontents of
    Nothing -> return VerifyUnknownKey
    Just contents -> do
      pkg <- decodeUploadedPackageFile file contents
      let pkg' = D.verifyPackage user pkg
      insertPackage pkg'
      liftIO $ removeFile file
      return (VerifySuccess pkg')

getDataDir :: Handler String
getDataDir = appDataDir . appSettings <$> getYesod

packageDirFor :: PackageName -> Handler String
packageDirFor pkgName = do
  dir <- getDataDir
  return (dir ++ "/verified/" ++ runPackageName pkgName)

packageVersionFileFor :: PackageName -> Version -> Handler String
packageVersionFileFor pkgName version = do
  dir <- packageDirFor pkgName
  return (dir ++ "/" ++ showVersion version ++ ".json")

pendingVerificationFileFor :: VerificationKey -> Handler String
pendingVerificationFileFor key = do
  dir <- getDataDir
  return (dir ++ "/uploaded/" ++ BC8.unpack (runVerificationKey key) ++ ".json")

decodeVerifiedPackageFile :: String -> BL.ByteString -> Handler D.VerifiedPackage
decodeVerifiedPackageFile filepath contents =
  decodePackageFile filepath contents

decodeUploadedPackageFile :: String -> BL.ByteString -> Handler D.UploadedPackage
decodeUploadedPackageFile filepath contents =
  decodePackageFile filepath contents

-- | Prefer decodeVerifiedPackageFile or decodeUploadedPackageFile to this
-- function.
decodePackageFile :: (A.FromJSON a) => String -> BL.ByteString -> Handler (D.Package a)
decodePackageFile filepath contents = do
  case A.eitherDecode contents of
    Left err -> do
      $logError (T.pack ("Invalid JSON in: " ++ show filepath ++
                         ", error: " ++ show err))
      sendResponseStatus internalServerError500 ("" :: String)
    Right pkg ->
      return pkg

-- | Read the file at the given path as a lazy ByteString, or return Nothing
-- if no such file exists.
readFileMay :: String -> IO (Maybe BL.ByteString)
readFileMay file =
  catchJust selectDoesNotExist
            (Just <$> BL.readFile file)
            (const (return Nothing))
  where
  selectDoesNotExist e
    | isDoesNotExistErrorType (ioeGetErrorType e) = Just ()
    | otherwise = Nothing

------------------------
-- Verification

data VerifyResult
  = VerifySuccess D.VerifiedPackage
  | VerifyUnknownKey
  deriving (Show, Eq, Ord)

keyLength :: Int
keyLength = 60

generateKey :: Handler VerificationKey
generateKey = do
  genVar <- appCPRNG <$> getYesod
  bytes <- liftIO $ atomically $ do
    gen <- readTVar genVar
    let (bytes, gen') = cprgGenerate keyLength gen
    writeTVar genVar gen'
    return bytes

  return (VerificationKey (Base64.encode bytes))
