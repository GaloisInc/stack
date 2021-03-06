{-# LANGUAGE ConstraintKinds       #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE RecordWildCards       #-}
{-# LANGUAGE TemplateHaskell       #-}
-- Perform a build
module Stack.Build.Execute
    ( printPlan
    , preFetch
    , executePlan
    -- TESTING
    , compareTestsComponents
    ) where

import           Control.Applicative            ((<$>), (<*>))
import           Control.Concurrent.Lifted (fork)
import           Control.Concurrent.Execute
import           Control.Concurrent.MVar.Lifted
import           Control.Concurrent.STM
import           Control.Exception.Lifted
import           Control.Monad                  (liftM, when, unless, void, join)
import           Control.Monad.Catch            (MonadCatch, MonadMask)
import           Control.Monad.IO.Class
import           Control.Monad.Logger
import           Control.Monad.Reader           (MonadReader, asks)
import           Control.Monad.Trans.Control    (liftBaseWith)
import           Control.Monad.Trans.Resource
import qualified Data.ByteString                as S
import           Data.ByteString                (ByteString)
import qualified Data.ByteString.Char8          as S8
import           Data.Conduit
import qualified Data.Conduit.Binary            as CB
import qualified Data.Conduit.List              as CL
import           Data.Foldable                  (forM_)
import           Data.Function
import           Data.List
import           Data.Map.Strict                (Map)
import qualified Data.Map.Strict                as Map
import           Data.Maybe
import           Data.Monoid                    ((<>))
import           Data.Set                       (Set)
import qualified Data.Set                       as Set
import           Data.Streaming.Process         hiding (callProcess, env)
import qualified Data.Streaming.Process         as Process
import           Data.Traversable               (forM)
import           Data.Text                      (Text)
import qualified Data.Text                      as T
import qualified Data.Text.Encoding             as T
import           Data.Text.Encoding             (encodeUtf8)
import           Distribution.System            (OS (Windows),
                                                 Platform (Platform))
import           Language.Haskell.TH            as TH (location)
import           Network.HTTP.Client.Conduit    (HasHttpManager)
import           Path
import           Path.IO
import           Prelude                        hiding (FilePath, writeFile)
import           Safe                           (lastMay)
import           Stack.Build.Cache
import           Stack.Build.Haddock
import           Stack.Build.Installed
import           Stack.Build.Source
import           Stack.Build.Types
import           Stack.Fetch                    as Fetch
import           Stack.GhcPkg
import           Stack.Package
import           Stack.Constants
import           Stack.Types
import           Stack.Types.StackT
import           Stack.Types.Internal
import qualified System.Directory               as D
import           System.Environment             (getExecutablePath)
import           System.Exit                    (ExitCode (ExitSuccess))
import qualified System.FilePath                as FP
import           System.IO
import           System.IO.Temp                 (withSystemTempDirectory)
import           System.Process.Internals       (createProcess_)
import           System.Process.Read
import           System.Process.Log             (showProcessArgDebug)

type M env m = (MonadIO m,MonadReader env m,HasHttpManager env,HasBuildConfig env,MonadLogger m,MonadBaseControl IO m,MonadCatch m,MonadMask m,HasLogLevel env,HasEnvConfig env,HasTerminal env)

preFetch :: M env m => Plan -> m ()
preFetch plan
    | Set.null idents = $logDebug "Nothing to fetch"
    | otherwise = do
        $logDebug $ T.pack $
            "Prefetching: " ++
            intercalate ", " (map packageIdentifierString $ Set.toList idents)
        menv <- getMinimalEnvOverride
        fetchPackages menv idents
  where
    idents = Set.unions $ map toIdent $ Map.toList $ planTasks plan

    toIdent (name, task) =
        case taskType task of
            TTLocal _ -> Set.empty
            TTUpstream package _ -> Set.singleton $ PackageIdentifier
                name
                (packageVersion package)

printPlan :: M env m
          => FinalAction
          -> Plan
          -> m ()
printPlan finalAction plan = do
    case Map.toList $ planUnregisterLocal plan of
        [] -> $logInfo "Nothing to unregister"
        xs -> do
            $logInfo "Would unregister locally:"
            forM_ xs $ \(gid, reason) -> $logInfo $ T.concat
                [ T.pack $ ghcPkgIdString gid
                , " ("
                , reason
                , ")"
                ]

    $logInfo ""

    case Map.elems $ planTasks plan of
        [] -> $logInfo "Nothing to build"
        xs -> do
            $logInfo "Would build:"
            mapM_ ($logInfo . displayTask) xs

    let mfinalLabel =
            case finalAction of
                DoNothing -> Nothing
                DoBenchmarks _ -> Just "benchmark"
                DoTests _ -> Just "test"
    case mfinalLabel of
        Nothing -> return ()
        Just finalLabel -> do
            $logInfo ""

            case Map.toList $ planFinals plan of
                [] -> $logInfo $ "Nothing to " <> finalLabel
                xs -> do
                    $logInfo $ "Would " <> finalLabel <> ":"
                    forM_ xs $ \(name, _) -> $logInfo $ packageNameText name

    $logInfo ""

    case Map.toList $ planInstallExes plan of
        [] -> $logInfo "No executables to be installed"
        xs -> do
            $logInfo "Would install executables:"
            forM_ xs $ \(name, loc) -> $logInfo $ T.concat
                [ name
                , " from "
                , case loc of
                    Snap -> "snapshot"
                    Local -> "local"
                , " database"
                ]

-- | For a dry run
displayTask :: Task -> Text
displayTask task = T.pack $ concat
    [ packageIdentifierString $ taskProvides task
    , ": database="
    , case taskLocation task of
        Snap -> "snapshot"
        Local -> "local"
    , ", source="
    , case taskType task of
        TTLocal lp -> concat
            [ toFilePath $ lpDir lp
            ]
        TTUpstream _ _ -> "package index"
    , if Set.null missing
        then ""
        else ", after: " ++ intercalate "," (map packageIdentifierString $ Set.toList missing)
    ]
  where
    missing = tcoMissing $ taskConfigOpts task

data ExecuteEnv = ExecuteEnv
    { eeEnvOverride    :: !EnvOverride
    , eeConfigureLock  :: !(MVar ())
    , eeInstallLock    :: !(MVar ())
    , eeBuildOpts      :: !BuildOpts
    , eeBaseConfigOpts :: !BaseConfigOpts
    , eeGhcPkgIds      :: !(TVar (Map PackageIdentifier Installed))
    , eeTempDir        :: !(Path Abs Dir)
    , eeSetupHs        :: !(Path Abs File)
    , eeCabalPkgVer    :: !Version
    , eeTotalWanted    :: !Int
    , eeWanted         :: !(Set PackageName)
    , eeLocals         :: ![LocalPackage]
    , eeSourceMap      :: !SourceMap
    , eeGlobalDB       :: !(Path Abs Dir)
    }

-- | Perform the actual plan
executePlan :: M env m
            => EnvOverride
            -> BuildOpts
            -> BaseConfigOpts
            -> [LocalPackage]
            -> SourceMap
            -> Plan
            -> m ()
executePlan menv bopts baseConfigOpts locals sourceMap plan = do
    withSystemTempDirectory stackProgName $ \tmpdir -> do
        tmpdir' <- parseAbsDir tmpdir
        configLock <- newMVar ()
        installLock <- newMVar ()
        idMap <- liftIO $ newTVarIO Map.empty
        let setupHs = tmpdir' </> $(mkRelFile "Setup.hs")
        liftIO $ writeFile (toFilePath setupHs) "import Distribution.Simple\nmain = defaultMain"
        cabalPkgVer <- asks (envConfigCabalVersion . getEnvConfig)
        globalDB <- getGlobalDB menv
        executePlan' plan ExecuteEnv
            { eeEnvOverride = menv
            , eeBuildOpts = bopts
             -- Uncertain as to why we cannot run configures in parallel. This appears
             -- to be a Cabal library bug. Original issue:
             -- https://github.com/fpco/stack/issues/84. Ideally we'd be able to remove
             -- this.
            , eeConfigureLock = configLock
            , eeInstallLock = installLock
            , eeBaseConfigOpts = baseConfigOpts
            , eeGhcPkgIds = idMap
            , eeTempDir = tmpdir'
            , eeSetupHs = setupHs
            , eeCabalPkgVer = cabalPkgVer
            , eeTotalWanted = length $ filter lpWanted locals
            , eeWanted = wantedLocalPackages locals
            , eeLocals = locals
            , eeSourceMap = sourceMap
            , eeGlobalDB = globalDB
            }

    unless (Map.null $ planInstallExes plan) $ do
        snapBin <- (</> bindirSuffix) `liftM` installationRootDeps
        localBin <- (</> bindirSuffix) `liftM` installationRootLocal
        destDir <- asks $ configLocalBin . getConfig
        createTree destDir

        let destDir' = toFilePath destDir
        when (not $ any (FP.equalFilePath destDir') (envSearchPath menv)) $
            $logWarn $ T.concat
                [ "Installation path "
                , T.pack destDir'
                , " not found in PATH environment variable"
                ]

        platform <- asks getPlatform
        let ext =
                case platform of
                    Platform _ Windows -> ".exe"
                    _ -> ""

        currExe <- liftIO getExecutablePath -- needed for windows, see below

        installed <- forM (Map.toList $ planInstallExes plan) $ \(name, loc) -> do
            let bindir =
                    case loc of
                        Snap -> snapBin
                        Local -> localBin
            mfp <- resolveFileMaybe bindir $ T.unpack name ++ ext
            case mfp of
                Nothing -> do
                    $logWarn $ T.concat
                        [ "Couldn't find executable "
                        , name
                        , " in directory "
                        , T.pack $ toFilePath bindir
                        ]
                    return Nothing
                Just file -> do
                    let destFile = destDir' FP.</> T.unpack name ++ ext
                    $logInfo $ T.concat
                        [ "Copying from "
                        , T.pack $ toFilePath file
                        , " to "
                        , T.pack destFile
                        ]

                    liftIO $ case platform of
                        Platform _ Windows | FP.equalFilePath destFile currExe ->
                            windowsRenameCopy (toFilePath file) destFile
                        _ -> D.copyFile (toFilePath file) destFile
                    return $ Just (destDir', [T.append name (T.pack ext)])

        let destToInstalled = Map.fromListWith (++) (catMaybes installed)
        unless (Map.null destToInstalled) $ $logInfo ""
        forM_ (Map.toList destToInstalled) $ \(dest, executables) -> do
            $logInfo $ T.concat
                [ "Installed executables to "
                , T.pack dest
                , ":"]
            forM_ executables $ \exe -> $logInfo $ T.append "- " exe

-- | Windows can't write over the current executable. Instead, we rename the
-- current executable to something else and then do the copy.
windowsRenameCopy :: FilePath -> FilePath -> IO ()
windowsRenameCopy src dest = do
    D.copyFile src new
    D.renameFile dest old
    D.renameFile new dest
  where
    new = dest ++ ".new"
    old = dest ++ ".old"

-- | Perform the actual plan (internal)
executePlan' :: M env m
             => Plan
             -> ExecuteEnv
             -> m ()
executePlan' plan ee@ExecuteEnv {..} = do
    case Map.toList $ planUnregisterLocal plan of
        [] -> return ()
        ids -> do
            localDB <- packageDatabaseLocal
            forM_ ids $ \(id', reason) -> do
                $logInfo $ T.concat
                    [ T.pack $ ghcPkgIdString id'
                    , ": unregistering ("
                    , reason
                    , ")"
                    ]
                unregisterGhcPkgId eeEnvOverride localDB id'

    -- Yes, we're explicitly discarding result values, which in general would
    -- be bad. monad-unlift does this all properly at the type system level,
    -- but I don't want to pull it in for this one use case, when we know that
    -- stack always using transformer stacks that are safe for this use case.
    runInBase <- liftBaseWith $ \run -> return (void . run)

    let actions = concatMap (toActions runInBase ee) $ Map.elems $ Map.mergeWithKey
            (\_ b f -> Just (Just b, Just f))
            (fmap (\b -> (Just b, Nothing)))
            (fmap (\f -> (Nothing, Just f)))
            (planTasks plan)
            (planFinals plan)
    threads <- asks $ configJobs . getConfig
    concurrentTests <- asks $ configConcurrentTests . getConfig
    let keepGoing =
            case boptsKeepGoing eeBuildOpts of
                Just kg -> kg
                Nothing ->
                    case boptsFinalAction eeBuildOpts of
                        DoNothing -> False
                        _ -> True
        concurrentFinal =
            case boptsFinalAction eeBuildOpts of
                DoTests _ -> concurrentTests
                _ -> True
    terminal <- asks getTerminal
    errs <- liftIO $ runActions threads keepGoing concurrentFinal actions $ \doneVar -> do
        let total = length actions
            loop prev
                | prev == total =
                    runInBase $ $logStickyDone ("Completed all " <> T.pack (show total) <> " actions.")
                | otherwise = do
                    when terminal $ runInBase $
                        $logSticky ("Progress: " <> T.pack (show prev) <> "/" <> T.pack (show total))
                    done <- atomically $ do
                        done <- readTVar doneVar
                        check $ done /= prev
                        return done
                    loop done
        if total > 1
            then loop 0
            else return ()
    unless (null errs) $ throwM $ ExecutionFailure errs
    when (boptsHaddock eeBuildOpts && not (null actions))
        (generateHaddockIndex eeEnvOverride eeBaseConfigOpts eeLocals)

toActions :: M env m
          => (m () -> IO ())
          -> ExecuteEnv
          -> (Maybe Task, Maybe Task) -- build and final
          -> [Action]
toActions runInBase ee (mbuild, mfinal) =
    abuild ++ afinal
  where
    abuild =
        case mbuild of
            Nothing -> []
            Just task@Task {..} ->
                [ Action
                    { actionId = ActionId taskProvides ATBuild
                    , actionDeps =
                        (Set.map (\ident -> ActionId ident ATBuild) (tcoMissing taskConfigOpts))
                    , actionDo = \ac -> runInBase $ singleBuild ac ee task
                    }
                ]
    afinal =
        case (,) <$> mfinal <*> mfunc of
            Just (task@Task {..}, (func, checkTask)) | checkTask task ->
                [ Action
                    { actionId = ActionId taskProvides ATFinal
                    , actionDeps = addBuild taskProvides $
                        (Set.map (\ident -> ActionId ident ATBuild) (tcoMissing taskConfigOpts))
                    , actionDo = \ac -> runInBase $ func ac ee task
                    }
                ]
            _ -> []
      where
        addBuild ident =
            case mbuild of
                Nothing -> id
                Just _ -> Set.insert $ ActionId ident ATBuild

    mfunc =
        case boptsFinalAction $ eeBuildOpts ee of
            DoNothing -> Nothing
            DoTests topts -> Just (singleTest topts, checkTest)
            DoBenchmarks beopts -> Just (singleBench beopts, checkBench)

    checkTest task =
        case taskType task of
            TTLocal lp -> not $ Set.null $ packageTests $ lpPackage lp
            _ -> assert False False

    checkBench task =
        case taskType task of
            TTLocal lp -> not $ Set.null $ packageBenchmarks $ lpPackage lp
            _ -> assert False False

-- | Ensure that the configuration for the package matches what is given
ensureConfig :: M env m
             => Path Abs Dir -- ^ package directory
             -> ExecuteEnv
             -> Task
             -> m () -- ^ announce
             -> (Bool -> [String] -> m ()) -- ^ cabal
             -> Path Abs File -- ^ .cabal file
             -> [Text]
             -> m (ConfigCache, Bool)
ensureConfig pkgDir ExecuteEnv {..} Task {..} announce cabal cabalfp extra = do
    -- Determine the old and new configuration in the local directory, to
    -- determine if we need to reconfigure.
    mOldConfigCache <- tryGetConfigCache pkgDir

    mOldCabalMod <- tryGetCabalMod pkgDir
    newCabalMod <- liftIO (fmap modTime (D.getModificationTime (toFilePath cabalfp)))

    idMap <- liftIO $ readTVarIO eeGhcPkgIds
    let getMissing ident =
            case Map.lookup ident idMap of
                Nothing -> error "singleBuild: invariant violated, missing package ID missing"
                Just (Library x) -> Just x
                Just (Executable _) -> Nothing
        missing' = Set.fromList $ mapMaybe getMissing $ Set.toList missing
        TaskConfigOpts missing mkOpts = taskConfigOpts
        configOpts = mkOpts missing' ++ extra
        allDeps = Set.union missing' taskPresent
        newConfigCache = ConfigCache
            { configCacheOpts = map encodeUtf8 configOpts
            , configCacheDeps = allDeps
            , configCacheComponents =
                case taskType of
                    TTLocal lp -> Set.map encodeUtf8 $ lpComponents lp
                    TTUpstream _ _ -> Set.empty
            , configCacheHaddock =
                shouldHaddockPackage eeBuildOpts eeWanted (packageIdentifierName taskProvides)
            }

    let needConfig = mOldConfigCache /= Just newConfigCache
                  || mOldCabalMod /= Just newCabalMod
    when needConfig $ withMVar eeConfigureLock $ \_ -> do
        deleteCaches pkgDir
        announce
        cabal False $ "configure" : map T.unpack configOpts
        writeConfigCache pkgDir newConfigCache
        writeCabalMod pkgDir newCabalMod

    return (newConfigCache, needConfig)

withSingleContext :: M env m
                  => ActionContext
                  -> ExecuteEnv
                  -> Task
                  -> (  Package
                     -> Path Abs File
                     -> Path Abs Dir
                     -> (Bool -> [String] -> m ())
                     -> (Text -> m ())
                     -> Bool
                     -> Maybe (Path Abs File, Handle)
                     -> m a)
                  -> m a
withSingleContext ActionContext {..} ExecuteEnv {..} task@Task {..} inner0 =
    withPackage $ \package cabalfp pkgDir ->
    withLogFile package $ \mlogFile ->
    withCabal package pkgDir mlogFile $ \cabal ->
    inner0 package cabalfp pkgDir cabal announce console mlogFile
  where
    announce x = $logInfo $ T.concat
        [ T.pack $ packageIdentifierString taskProvides
        , ": "
        , x
        ]

    wanted =
        case taskType of
            TTLocal lp -> lpWanted lp
            TTUpstream _ _ -> False

    console = wanted
           && all (\(ActionId ident _) -> ident == taskProvides) (Set.toList acRemaining)
           && eeTotalWanted == 1

    withPackage inner =
        case taskType of
            TTLocal lp -> inner (lpPackage lp) (lpCabalFile lp) (lpDir lp)
            TTUpstream package _ -> do
                mdist <- liftM Just distRelativeDir
                m <- unpackPackageIdents eeEnvOverride eeTempDir mdist $ Set.singleton taskProvides
                case Map.toList m of
                    [(ident, dir)]
                        | ident == taskProvides -> do
                            let name = packageIdentifierName taskProvides
                            cabalfpRel <- parseRelFile $ packageNameString name ++ ".cabal"
                            let cabalfp = dir </> cabalfpRel
                            inner package cabalfp dir
                    _ -> error $ "withPackage: invariant violated: " ++ show m

    withLogFile package inner
        | console = inner Nothing
        | otherwise = do
            logPath <- buildLogPath package -- TODO give a difference suffix for test, bench, etc?
            createTree (parent logPath)
            let fp = toFilePath logPath
            bracket
                (liftIO $ openBinaryFile fp WriteMode)
                (liftIO . hClose)
                $ \h -> inner (Just (logPath, h))

    withCabal package pkgDir mlogFile inner = do
        config <- asks getConfig
        menv <- liftIO $ configEnvOverride config EnvSettings
            { esIncludeLocals = taskLocation task == Local
            , esIncludeGhcPackagePath = False
            , esStackExe = False
            }
        exeName <- liftIO $ join $ findExecutable menv "runhaskell"
        distRelativeDir' <- distRelativeDir
        msetuphs <-
            -- Avoid broken Setup.hs files causing problems for simple build
            -- types, see:
            -- https://github.com/commercialhaskell/stack/issues/370
            if packageSimpleType package
                then return Nothing
                else liftIO $ getSetupHs pkgDir
        let setuphs = fromMaybe eeSetupHs msetuphs
        inner $ \stripTHLoading args -> do
            let fullArgs =
                      ("-package=" ++
                       packageIdentifierString
                           (PackageIdentifier cabalPackageName
                                              eeCabalPkgVer))
                    : "-clear-package-db"
                    : "-global-package-db"

                    -- This next line is debatable. It adds access to the
                    -- snapshot package database for Cabal. There are two
                    -- possible objections:
                    --
                    -- 1. This doesn't isolate the build enough; arbitrary
                    -- other packages available could cause the build to
                    -- succeed or fail.
                    --
                    -- 2. This doesn't provide enough packages: we should also
                    -- include the local database when building local packages.
                    --
                    -- One possible solution to these points would be to use
                    -- -hide-all-packages and explicitly list which packages
                    -- can be used by Setup.hs, and have that based on the
                    -- dependencies of the package itself.
                    : ("-package-db=" ++ toFilePath (bcoSnapDB eeBaseConfigOpts))

                    : toFilePath setuphs
                    : ("--builddir=" ++ toFilePath distRelativeDir')
                    : args
                cp0 = proc (toFilePath exeName) fullArgs
                cp = cp0
                    { cwd = Just $ toFilePath pkgDir
                    , Process.env = envHelper menv
                    , std_in = CreatePipe
                    , std_out =
                        case mlogFile of
                                Nothing -> CreatePipe
                                Just (_, h) -> UseHandle h
                    , std_err =
                        case mlogFile of
                            Nothing -> CreatePipe
                            Just (_, h) -> UseHandle h
                    }
            $logProcessRun (toFilePath exeName) fullArgs

            -- Use createProcess_ to avoid the log file being closed afterwards
            (Just inH, moutH, merrH, ph) <- liftIO $ createProcess_ "singleBuild" cp
            liftIO $ hClose inH
            maybePrintBuildOutput stripTHLoading LevelInfo mlogFile moutH
            maybePrintBuildOutput stripTHLoading LevelWarn mlogFile merrH
            ec <- liftIO $ waitForProcess ph
            case ec of
                ExitSuccess -> return ()
                _ -> do
                    bs <- liftIO $
                        case mlogFile of
                            Nothing -> return ""
                            Just (logFile, h) -> do
                                hClose h
                                S.readFile $ toFilePath logFile
                    throwM $ CabalExitedUnsuccessfully
                        ec
                        taskProvides
                        exeName
                        fullArgs
                        (fmap fst mlogFile)
                        bs

    maybePrintBuildOutput stripTHLoading level mlogFile mh =
        case mh of
            Just h ->
                case mlogFile of
                  Just{} -> return ()
                  Nothing -> printBuildOutput stripTHLoading level h
            Nothing -> return ()

singleBuild :: M env m
            => ActionContext
            -> ExecuteEnv
            -> Task
            -> m ()
singleBuild ac@ActionContext {..} ee@ExecuteEnv {..} task@Task {..} =
  withSingleContext ac ee task $ \package cabalfp pkgDir cabal announce console _mlogFile -> do
    (cache, _neededConfig) <- ensureConfig pkgDir ee task (announce "configure") cabal cabalfp []

    markExeNotInstalled (taskLocation task) taskProvides
    case taskType of
        TTLocal lp -> writeBuildCache pkgDir $ lpNewBuildCache lp
        TTUpstream _ _ -> return ()

    announce "build"
    config <- asks getConfig
    extraOpts <- extraBuildOptions
    cabal (console && configHideTHLoading config) $
        (case taskType of
            TTLocal lp -> "build" : map T.unpack (Set.toList $ lpComponents lp)
            TTUpstream _ _ -> ["build"]) ++ extraOpts

    let doHaddock = shouldHaddockPackage eeBuildOpts eeWanted (packageName package) &&
                    -- Works around haddock failing on bytestring-builder since it has no modules
                    -- when bytestring is new enough.
                    packageHasExposedModules package
    when doHaddock $ do
        announce "haddock"
        hscolourExists <- doesExecutableExist eeEnvOverride "hscolour"
        cabal False (concat [["haddock", "--html", "--hoogle", "--html-location=../$pkg-$version/"]
                            ,["--hyperlink-source" | hscolourExists]])

    withMVar eeInstallLock $ \() -> do
        announce "install"
        cabal False ["install"]

    let pkgDbs =
            case taskLocation task of
                Snap -> [bcoSnapDB eeBaseConfigOpts]
                Local ->
                    [ bcoSnapDB eeBaseConfigOpts
                    , bcoLocalDB eeBaseConfigOpts
                    ]
    mpkgid <- findGhcPkgId eeEnvOverride pkgDbs (packageName package)
    mpkgid' <- case (packageHasLibrary package, mpkgid) of
        (False, _) -> assert (isNothing mpkgid) $ do
            markExeInstalled (taskLocation task) taskProvides -- TODO unify somehow with writeFlagCache?
            return $ Executable $ PackageIdentifier
                (packageName package)
                (packageVersion package)
        (True, Nothing) -> throwM $ Couldn'tFindPkgId $ packageName package
        (True, Just pkgid) -> return $ Library pkgid
    writeFlagCache mpkgid' cache
    liftIO $ atomically $ modifyTVar eeGhcPkgIds $ Map.insert taskProvides mpkgid'

    when (doHaddock && shouldHaddockDeps eeBuildOpts) $
        copyDepHaddocks
            eeEnvOverride
            eeBaseConfigOpts
            (pkgDbs ++ [eeGlobalDB])
            (PackageIdentifier (packageName package) (packageVersion package))
            Set.empty

singleTest :: M env m
           => TestOpts
           -> ActionContext
           -> ExecuteEnv
           -> Task
           -> m ()
singleTest topts ac ee task =
    withSingleContext ac ee task $ \package cabalfp pkgDir cabal announce console mlogFile -> do
        (_cache, neededConfig) <- ensureConfig pkgDir ee task (announce "configure (test)") cabal cabalfp ["--enable-tests"]
        config <- asks getConfig

        testBuilt <- checkTestBuilt pkgDir

        let needBuild = neededConfig ||
                (case taskType task of
                    TTLocal lp -> lpDirtyFiles lp
                    _ -> assert False True) ||
                not testBuilt

            needHpc = toCoverage topts

            componentsRaw =
                case taskType task of
                    TTLocal lp -> Set.toList $ lpComponents lp
                    TTUpstream _ _ -> assert False []
            testsToRun = compareTestsComponents componentsRaw $ Set.toList $ packageTests package
            components = map (T.unpack . T.append "test:") testsToRun

        when needBuild $ do
            announce "build (test)"
            unsetTestBuilt pkgDir
            unsetTestSuccess pkgDir
            case taskType task of
                TTLocal lp -> writeBuildCache pkgDir $ lpNewBuildCache lp
                TTUpstream _ _ -> assert False $ return ()
            extraOpts <- extraBuildOptions
            cabal (console && configHideTHLoading config) $
                "build" : (extraOpts ++ components)
            setTestBuilt pkgDir

        toRun <-
            if toDisableRun topts
              then do
                  announce "Test running disabled by --no-run-tests flag."
                  return False
              else if toRerunTests topts
                  then return True
                  else do
                      success <- checkTestSuccess pkgDir
                      if success
                          then do
                              unless (null testsToRun) $ announce "skipping already passed test"
                              return False
                          else return True

        when toRun $ do
            bconfig <- asks getBuildConfig
            buildDir <- distDirFromDir pkgDir
            hpcDir <- hpcDirFromDir pkgDir
            when needHpc (createTree hpcDir)
            let exeExtension =
                    case configPlatform $ getConfig bconfig of
                        Platform _ Windows -> ".exe"
                        _ -> ""

            errs <- liftM Map.unions $ forM testsToRun $ \testName -> do
                nameDir <- parseRelDir $ T.unpack testName
                nameExe <- parseRelFile $ T.unpack testName ++ exeExtension
                nameTix <- liftM (pkgDir </>) $ parseRelFile $ T.unpack testName ++ ".tix"
                let exeName = buildDir </> $(mkRelDir "build") </> nameDir </> nameExe
                exists <- fileExists exeName
                menv <- liftIO $ configEnvOverride config EnvSettings
                    { esIncludeLocals = taskLocation task == Local
                    , esIncludeGhcPackagePath = True
                    , esStackExe = True
                    }
                if exists
                    then do
                        -- We clear out the .tix files before doing a run.
                        when needHpc $ do
                            tixexists <- fileExists nameTix
                            when tixexists $
                                $logWarn ("Removing HPC file " <> T.pack (toFilePath nameTix))
                            removeFileIfExists nameTix

                        let args = toAdditionalArgs topts
                            argsDisplay = case args of
                                            [] -> ""
                                            _ -> ", args: " <> T.intercalate " " (map showProcessArgDebug args)
                        announce $ "test (suite: " <> testName <> argsDisplay <> ")"
                        let cp = (proc (toFilePath exeName) args)
                                { cwd = Just $ toFilePath pkgDir
                                , Process.env = envHelper menv
                                , std_in = CreatePipe
                                , std_out =
                                    case mlogFile of
                                        Nothing -> Inherit
                                        Just (_, h) -> UseHandle h
                                , std_err =
                                    case mlogFile of
                                        Nothing -> Inherit
                                        Just (_, h) -> UseHandle h
                                }

                        -- Use createProcess_ to avoid the log file being closed afterwards
                        (Just inH, Nothing, Nothing, ph) <- liftIO $ createProcess_ "singleBuild.runTests" cp
                        liftIO $ hClose inH
                        ec <- liftIO $ waitForProcess ph
                        -- Move the .tix file out of the package directory
                        -- into the hpc work dir, for tidiness.
                        when needHpc $
                            moveFileIfExists nameTix hpcDir
                        return $ case ec of
                            ExitSuccess -> Map.empty
                            _ -> Map.singleton testName $ Just ec
                    else do
                        $logError $ T.concat
                            [ "Test suite "
                            , testName
                            , " executable not found for "
                            , packageNameText $ packageName package
                            ]
                        return $ Map.singleton testName Nothing

            when needHpc $ forM_ (lastMay testsToRun) $ \testName -> do
                let pkgName = packageNameText (packageName package)
                when (not $ null $ tail testsToRun) $ $logWarn $ T.concat
                    [ "Error: The --coverage flag does not yet support multiple test suites in a single cabal file. "
                    , "All of the tests have been run, however, the HPC report will only supply coverage info for "
                    , pkgName
                    , "'s last test, "
                    , testName
                    , "."
                    ]
                generateHpcReport pkgDir pkgName testName

            bs <- liftIO $
                case mlogFile of
                    Nothing -> return ""
                    Just (logFile, h) -> do
                        hClose h
                        S.readFile $ toFilePath logFile

            unless (Map.null errs) $ throwM $ TestSuiteFailure
                (taskProvides task)
                errs
                (fmap fst mlogFile)
                bs

            setTestSuccess pkgDir

-- | Determine the tests to be run based on the list of components.
compareTestsComponents :: [Text] -- ^ components
                       -> [Text] -- ^ all test names
                       -> [Text] -- ^ tests to be run
compareTestsComponents [] tests = tests -- no components -- all tests
compareTestsComponents comps tests2 =
    Set.toList $ Set.intersection tests1 $ Set.fromList tests2
  where
    tests1 = Set.unions $ map toSet comps

    toSet x =
        case T.break (== ':') x of
            (y, "") -> assert (x == y) (Set.singleton x)
            ("test", y) -> Set.singleton $ T.drop 1 y
            _ -> Set.empty

-- | Generate the HTML report and show a textual coverage summary.
generateHpcReport :: M env m => Path Abs Dir -> Text -> Text -> m ()
generateHpcReport pkgDir pkgName testName = do
    let whichTest = pkgName <> "'s test-suite \"" <> testName <> "\""
    hpcDir <- hpcDirFromDir pkgDir
    hpcRelDir <- (</> dotHpc) <$> hpcRelativeDir
    pkgDirs <- Map.keys . bcPackages <$> asks getBuildConfig
    let args =
            concatMap (\x -> ["--srcdir", toFilePath x]) pkgDirs ++
            ["--hpcdir", toFilePath hpcRelDir, "--reset-hpcdirs"]
    tixFile <- parseRelFile (T.unpack testName ++ ".tix")
    let tixFileAbs = hpcDir </> tixFile
    tixFileExists <- fileExists tixFileAbs
    if not tixFileExists
        then $logError $ T.concat
            [ "Didn't find .tix coverage file for "
            , whichTest
            , " - expected to find it at "
            , T.pack (toFilePath tixFileAbs)
            , "."
            ]
        else (`onException` $logError ("Error occurred while producing coverage report for " <> whichTest)) $ do
            menv <- getMinimalEnvOverride
            $logInfo $ "Generating HTML coverage report for " <> whichTest
            _ <- readProcessStdout (Just hpcDir) menv "hpc"
                ("markup" : toFilePath tixFileAbs : args)
            output <- readProcessStdout (Just hpcDir) menv "hpc"
                ("report" : toFilePath tixFileAbs : args)
            forM_ (S8.lines output) ($logInfo . T.decodeUtf8 . stripCharacterReturn)
            $logInfo
                ("The HTML coverage report for " <> whichTest <> " is available at " <>
                 T.pack (toFilePath (hpcDir </> $(mkRelFile "hpc_index.html"))))

singleBench :: M env m
            => BenchmarkOpts
            -> ActionContext
            -> ExecuteEnv
            -> Task
            -> m ()
singleBench beopts ac ee task =
    withSingleContext ac ee task $ \_package cabalfp pkgDir cabal announce console _mlogFile -> do
        (_cache, neededConfig) <- ensureConfig pkgDir ee task (announce "configure (benchmarks)") cabal cabalfp ["--enable-benchmarks"]

        benchBuilt <- checkBenchBuilt pkgDir

        let needBuild = neededConfig ||
                (case taskType task of
                    TTLocal lp -> lpDirtyFiles lp
                    _ -> assert False True) ||
                not benchBuilt
        when needBuild $ do
            announce "build (benchmarks)"
            unsetBenchBuilt pkgDir
            case taskType task of
                TTLocal lp -> writeBuildCache pkgDir $ lpNewBuildCache lp
                TTUpstream _ _ -> assert False $ return ()
            config <- asks getConfig
            extraOpts <- extraBuildOptions
            cabal (console && configHideTHLoading config) ("build" : extraOpts)
            setBenchBuilt pkgDir
        let args = maybe []
                         ((:[]) . ("--benchmark-options=" <>))
                         (beoAdditionalArgs beopts)
        announce "benchmarks"
        cabal False ("bench" : args)

-- | Grab all output from the given @Handle@ and print it to stdout, stripping
-- Template Haskell "Loading package" lines. Does work in a separate thread.
printBuildOutput :: (MonadIO m, MonadBaseControl IO m, MonadLogger m)
                 => Bool -> LogLevel -> Handle -> m ()
printBuildOutput excludeTHLoading level outH = void $ fork $
         CB.sourceHandle outH
    $$ CB.lines
    =$ CL.map stripCharacterReturn
    =$ CL.filter (not . isTHLoading)
    =$ CL.mapM_ (monadLoggerLog $(TH.location >>= liftLoc) "" level)
  where
    -- | Is this line a Template Haskell "Loading package" line
    -- ByteString
    isTHLoading :: S8.ByteString -> Bool
    isTHLoading _ | not excludeTHLoading = False
    isTHLoading bs =
        "Loading package " `S8.isPrefixOf` bs &&
        ("done." `S8.isSuffixOf` bs || "done.\r" `S8.isSuffixOf` bs)

-- | Strip a @\r@ character from the byte vector. Used because Windows.
stripCharacterReturn :: ByteString -> ByteString
stripCharacterReturn = S8.filter (not . (=='\r'))

taskLocation :: Task -> InstallLocation
taskLocation task =
    case taskType task of
        TTLocal _ -> Local
        TTUpstream _ loc -> loc

-- | Ensure Setup.hs exists in the given directory. Returns an action
-- to remove it later.
getSetupHs :: Path Abs Dir -- ^ project directory
           -> IO (Maybe (Path Abs File))
getSetupHs dir = do
    exists1 <- fileExists fp1
    if exists1
        then return $ Just fp1
        else do
            exists2 <- fileExists fp2
            if exists2
                then return $ Just fp2
                else return Nothing
  where
    fp1 = dir </> $(mkRelFile "Setup.hs")
    fp2 = dir </> $(mkRelFile "Setup.lhs")

extraBuildOptions :: M env m => m [String]
extraBuildOptions = do
    hpcIndexDir <- toFilePath . (</> dotHpc) <$> hpcRelativeDir
    return ["--ghc-options", "-hpcdir " ++ hpcIndexDir]
