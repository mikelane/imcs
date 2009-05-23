--- Copyright © 2009 Bart Massey
--- ALL RIGHTS RESERVED
--- [This program is licensed under the "MIT License"]
--- Please see the file COPYING in the source
--- distribution of this software for license terms.

module Service (
  ServiceState,
  initService,
  initServiceState,
  doCommands) where

import Prelude hiding (catch)

import Control.Concurrent.Chan
import Control.Concurrent.MVar
import Control.Exception (evaluate, throw)
import Control.Monad
import Data.Char
import Data.IORef
import Data.List
import Data.Ord
import Network
import System.Exit
import System.FilePath
import System.IO
import System.IO.Error
import System.Posix.Files
import System.Posix.Directory
import System.Time

import Game
import Log
import Rating
import Version

state_path :: FilePath
state_path = "imcsd"

version_path :: FilePath
version_path = state_path </> "VERSION"

private_path :: FilePath
private_path = state_path </> "private"

game_id_path :: FilePath
game_id_path = private_path </> "GAMEID"

pwf_path :: FilePath
pwf_path = private_path </> "passwd"

pwf_tmp_path :: FilePath
pwf_tmp_path = private_path </> "passwd.tmp"

log_path :: FilePath
log_path = state_path </> "log"

default_time :: Maybe Int
default_time = Just 300000

data Wakeup =
    Wakeup {
      wakeup_name :: String,
      wakeup_client_id :: String,
      wakeup_handle :: Handle }
  | Nevermind

data GamePost =
    GameResv {
      game_resv_game_id :: Int,
      game_resv_name :: String,
      game_resv_client_id :: String,
      game_resv_side :: Char,
      game_resv_wakeup :: Chan Wakeup }
  | InProgress {
      in_progress_game_id :: Int,
      in_progress_name_white :: String,
      in_progress_name_black :: String,
      in_progress_wakeup :: MVar () }

data PWFEntry = PWFEntry {
      pwf_entry_name :: String,
      pwf_entry_password :: String,
      pwf_entry_rating :: Rating }

data ServiceState = ServiceState {
      service_state_game_id :: Int,
      service_state_game_list :: [GamePost],
      service_state_pwf :: [PWFEntry] }

initService :: Int -> String -> IO ()
initService port admin_pw = do
  fversion <- read_versionf
  case fversion of
    "2.2" -> do
      putStrLn $ "using existing version " ++ fversion
      terminate_existing_server
    "2.1" -> do
      terminate_existing_server
      to_v2_2
    "2.0" -> to_v2_1
    "" -> do
      to_v2_0
      to_v2_1
    v -> error $ "unknown version " ++ v
  where
    to_v2_2 = write_versionf
    to_v2_1 = write_versionf
    to_v2_0 = do
       game_id <- read_game_id
       case game_id of
         1 -> to_v2_0_from_v1_0
         _ -> to_v2_0_from_v1_4
       write_versionf
    to_v2_0_from_v1_0 = do
       createDirectory state_path 0o755
       createDirectory private_path 0o700
       createDirectory log_path 0o755
       h <- openFile pwf_path AppendMode
       hClose h
       write_versionf
    to_v2_0_from_v1_4 = do
       old_pwf <- read_v1_4_pwf
       let new_pwf = map to_pwe old_pwf
       write_pwf new_pwf
       where
         to_pwe (name, password) = PWFEntry name password baseRating
    terminate_existing_server = do
      let try_to_connect =
              connectTo "127.0.0.1" $ PortNumber $ fromIntegral port
      let fail_to_connect e = do
              putStrLn $ "could not connect to localhost:" ++ show port ++
                         " : " ++ show e
              throw e
      h <- catch try_to_connect fail_to_connect
      let expect code failure = do
            putStrLn $ "expecting " ++ code
            let process_line = do
                  line <- hGetLine h
                  putStrLn $ "got " ++ line
                  case words line of
                    (code' : _) | code == code' -> return ()
                    _ ->  do 
                      let msg = failure ++ ": " ++ line
                      let e = mkIOError userErrorType msg (Just h) Nothing
                      throw e
            let io_fail e = do
                  putStrLn $ "IO Error: exiting"
                  throw e
            catch process_line io_fail
      let send s = do
            putStrLn $ "sending " ++ s
            hPutStrLn h s
            hFlush h
      expect "100" "unexpected server hello"
      send $ "me admin " ++ admin_pw
      expect "201" "could not become admin"
      send "stop"
      expect "205" "server cannot or would not stop"
      hClose h
      return ()

read_versionf :: IO String
read_versionf = catch read_version_file give_up where
    read_version_file = do
      vh <- openFile version_path ReadMode
      l <- hGetLine vh
      hClose vh
      return $ unwords $ words l
    give_up _ = do
      return ""

write_versionf :: IO ()
write_versionf = do
  vh <- openFile version_path WriteMode
  hPutStrLn vh version
  hClose vh

write_game_id :: Int -> IO ()
write_game_id game_id = do
  idh <- openFile game_id_path WriteMode
  hPrint idh game_id
  hClose idh

write_pwf :: [PWFEntry] -> IO ()
write_pwf pwf = do
  h <- openFile pwf_tmp_path WriteMode
  let write_pwfe (PWFEntry name password rating) =
        hPutStrLn h $ name ++ " " ++ password ++ " " ++ show rating
  mapM_ write_pwfe pwf
  hClose h
  removeLink pwf_path
  rename pwf_tmp_path pwf_path

read_v1_4_pwf :: IO [(String, String)]
read_v1_4_pwf = do
  h <- openFile pwf_path ReadMode
  s <- hGetContents h
  return $ map (make_pwfe . words) $ lines s
  where
    make_pwfe [name, password] =
        (name, password)
    make_pwfe _ = error "bad password file format: exiting"

read_pwf :: IO [PWFEntry]
read_pwf = do
  h <- openFile pwf_path ReadMode
  s <- hGetContents h
  return $ map (make_pwfe . words) $ lines s
  where
    make_pwfe [name, password, rating] =
        PWFEntry name password (read rating)
    make_pwfe _ = error "bad password file format: exiting"

read_game_id :: IO Int
read_game_id = catch read_game_file give_up where
    read_game_file = do
      idh <- openFile game_id_path ReadMode
      l <- hGetLine idh
      hClose idh
      return $ read l
    give_up _ = do
      return 1

initServiceState :: IO ServiceState
initServiceState = do
  fversion <- read_versionf
  unless (fversion == version)
         (evaluate $ error $ "daemon " ++ version ++
                             ", fs " ++ fversion ++
                             ": exiting")
  next_game_id <- read_game_id
  pwf <- read_pwf
  return $ ServiceState {
    service_state_game_id = next_game_id,
    service_state_game_list = [],
    service_state_pwf = pwf }

parse_int :: String -> Maybe Int
parse_int "" = Nothing
parse_int s
    | length s < 9 && all isDigit s = Just (read s)
    | otherwise = Nothing

pw_lookup :: ServiceState -> String -> Maybe (String, Rating)
pw_lookup ss name = lookup name pwf where
    pwf = map (\(PWFEntry n p r) -> (n, (p, r))) $ service_state_pwf ss

game_lookup :: [GamePost] -> Int
            -> LogIO (Either String (String, Chan Wakeup, [GamePost]))
game_lookup game_list game_id = do
  case partition waiting_game game_list of
    ([GameResv _ other_name _ _ wakeup], rest) ->
        return $ Right (other_name, wakeup, rest)
    ([], _) -> 
        return $ Left "408 no such game"
    _ ->
        return $ Left "499 internal error: multiple games with same id in list"
  where
    waiting_game (GameResv game_id' _ _ _ _) | game_id' == game_id = True
    waiting_game _ = False

doCommands :: (Handle, String) -> MVar ServiceState -> LogIO ()
doCommands (h, client_id) state = do
  liftIO $ hPutStrLn h $ "100 imcs " ++ version
  continue <- liftIO $ newIORef True
  me <- liftIO $ newIORef Nothing
  whileLogIO continue $ do
    line <- liftIO $ hGetLine h
    case words line of
      [] -> do
        return ()
      ["help"] -> do
        liftIO $ hPutStr h $ unlines [
          "210 imcs " ++ version ++ " help",
          " help: this help",
          " quit: quit imcs",
          " me <name> <password>: log in",
          " register <name> <password>: register a new name and log in",
          " password <password>: change password",
          " list: list available games in format",
          "       <id> <opponent-name> <opponent-color> <opponent-rating>",
          " ratings: list player ratings (top 10 plus own)",
          " offer <color>: offer a game as W or B",
          " accept <id>: accept a game with an opponent",
          " clean: cancel all outstanding offers by player",
          "." ]
      ["quit"] -> do
        logMsg $ "client " ++ client_id ++ " quits"
        liftIO $ do
          hPutStrLn h "200 Goodbye"
          writeIORef continue False
          hClose h
      ["me", name, password] -> do
        ss <- liftIO $ readMVar state
        case pw_lookup ss name of
          Nothing ->
              liftIO $ hPutStrLn h $ "400 no such username: " ++
                                     "please use register command"
          Just (password', rating') ->
              if password /= password'
              then
                liftIO $ hPutStrLn h "401 wrong password"
              else do
                logMsg $ "client " ++ client_id ++ " aka " ++ name
                liftIO $ writeIORef me $ Just name
                liftIO $ hPutStrLn h $ "201 hello " ++ name
      ["register", name, password] -> do
         ss <- liftIO $ takeMVar state
         case pw_lookup ss name of
           Just _ -> liftIO $ do
             putMVar state ss
             hPutStrLn h $ "402 username already exists: " ++
                           "please use password command to change"
           Nothing -> do
             let ServiceState game_id game_list pwf = ss
             let pwfe = PWFEntry name password baseRating
             let pwf' = pwf ++ [pwfe]
             let ss' = ServiceState game_id game_list pwf'
             liftIO $ do
               write_pwf pwf' --- XXX failure will hang server
               putMVar state ss'
               writeIORef me $ Just name
               hPutStrLn h $ "202 hello new user " ++ name
             logMsg $ "registered client " ++ client_id ++
                      " as user " ++ name
      ["password", password] -> do
        maybe_my_name <- liftIO $ readIORef me
        case maybe_my_name of
          Nothing ->
            liftIO $ hPutStrLn h "403 please use the me command first"
          Just my_name -> do
            ss <- liftIO $ takeMVar state
            case pw_lookup ss my_name of
              Nothing -> do
                liftIO $ putMVar state ss
                logMsg $ "client " ++ client_id ++ " name " ++
                         my_name ++ "not in password file"
                liftIO $ hPutStrLn h "500 you do not exist: go away"
              Just _ -> do
                let ServiceState game_id game_list pwf = ss
                let newpass e@(PWFEntry n _ rating)
                     | n == my_name = PWFEntry n password rating
                     | otherwise = e
                let pwf' = map newpass pwf
                let ss' = ServiceState game_id game_list pwf'
                liftIO $ do
                  write_pwf pwf'  --- XXX failure will hang server
                  putMVar state ss'
                  hPutStrLn h $ "203 password change for user " ++ my_name
                logMsg $ "changed password for client " ++ client_id ++
                         " user " ++ my_name
      ["list"] -> liftIO $ do
        ss@(ServiceState _ game_list _) <- readMVar state
        hPutStrLn h "211 available games"
        let lookup_rating other_name =
                case pw_lookup ss other_name of
                  Nothing -> "?"
                  Just (_, r) -> show r
        let output_game (GameResv game_id other_name _ color _) =
                hPutStrLn h $ " " ++ show game_id ++
                              " " ++ other_name ++
                              " " ++ [color] ++
                              " " ++ lookup_rating other_name ++
                              " [offer]"
            output_game (InProgress game_id name_white name_black _) =
                hPutStrLn h $ " " ++ show game_id ++
                              " " ++ name_white ++
                              " " ++ name_black ++
                              " (" ++ lookup_rating name_white ++ "/" ++
                                   lookup_rating name_black ++ ") " ++
                              " [in-progress]"
        mapM_ output_game game_list
        hPutStrLn h "."
      ["ratings"] -> liftIO $ do
        ServiceState _ _ pwf <- readMVar state
        maybe_my_name <- readIORef me
        let ratings = map rating_info pwf
        let top10 = take 10 $ sortBy (comparing (negate . snd)) ratings
        let rating_list =
                case maybe_my_name of
                  Nothing -> top10
                  Just my_name ->
                      case lookup my_name top10 of
                        Just _ -> top10
                        Nothing ->
                            case lookup my_name ratings of
                              Nothing -> top10
                              Just my_rating -> top10 ++ [(my_name, my_rating)]
        hPutStrLn h "212 ratings"
        mapM_ output_rating rating_list
        hPutStrLn h "."
        where
          rating_info (PWFEntry pname _ prating) = (pname, prating)
          output_rating (pname, prating) =
            hPutStrLn h $ " " ++ pname ++
                          " " ++ show prating
      ["offer", color] -> do
        maybe_my_name <- liftIO $ readIORef me
        case (maybe_my_name, valid_color color) of
          (Nothing, _) ->
            liftIO $ hPutStrLn h "404 must set name first using me command"
          (_, False) ->
            liftIO $ hPutStrLn h $ "405 bad color " ++ color
          (Just my_name, True) -> do
            logMsg $ "client " ++ client_id ++ " offers game as " ++ color
            wakeup <- liftIO $ newChan
            ss <- liftIO $ takeMVar state
            let ServiceState game_id game_list pwf = ss
            let my_rating =
                  case pw_lookup ss my_name of
                    Just (_, r) -> r
                    --- XXX shouldn't normally happen
                    Nothing -> baseRating
            let new_game =
                  GameResv game_id my_name client_id (head color) wakeup
            let service_state' =
                  ServiceState (game_id + 1) (game_list ++ [new_game]) pwf
            liftIO $ do
              write_game_id (game_id + 1)   --- XXX failure will hang server

              putMVar state service_state'
              hPutStrLn h $ "101 game " ++ show game_id ++
                            " waiting for offer acceptance"
            w <- liftIO $ readChan wakeup
            case w of
              Wakeup other_name other_id other_h -> do
                liftIO $ hPutStrLn h "102 received acceptance"
                liftIO $ writeIORef continue False
                let ((p1, p1_name), (p2, p2_name)) = 
                      case head color of
                        'W' -> (((h, default_time), my_name),
                                ((other_h, default_time), other_name))
                        'B' -> (((other_h, default_time), other_name),
                                ((h, default_time), my_name))
                        _   -> error "internal error: bad color"
                wchan <- liftIO $ newEmptyMVar
                let ip = InProgress game_id p1_name p2_name wchan
                (ServiceState game_id'' game_list pwf) <- liftIO $ takeMVar state
                let gl' = game_list ++ [ip]
                liftIO $ putMVar state (ServiceState game_id'' gl' pwf)
                let run_game = do
                    let game_desc = show game_id ++ ": " ++
                                    my_name ++ "(" ++ client_id ++
                                    ", " ++ color ++ ") vs " ++
                                    other_name ++ "(" ++ other_id ++ ")"
                    logMsg $ "game " ++ game_desc ++ " begins"
                    let path = log_path </> show game_id
                    game_log <- liftIO $ openFile path WriteMode
                    liftIO $ withLogDo game_log $ do
                      time <- liftIO $ getClockTime
                      let date = calendarTimeToString $ toUTCTime time
                      logMsg game_desc
                      logMsg date
                      score <- doGame p1 p2
                      liftIO $ do
                        p1_rating <- lookup_rating p1_name
                        p2_rating <- lookup_rating p2_name
                        update_rating p1_name p1_rating p2_rating score
                        update_rating p2_name p2_rating p1_rating (-score)
                        hClose h
                        hClose other_h
                      logMsg $ "client " ++ client_id ++ " closes"
                      where
                        lookup_rating name = do
                          ss <- readMVar state
                          case pw_lookup ss name of
                            Just (_, rating) -> return rating
                            --- XXX should never happen
                            Nothing -> return baseRating
                        update_rating name ra rb s = do
                          let ra' = updateRating ra rb s
                          ss <- takeMVar state
                          let ServiceState game_id'' game_list pwf = ss
                          let newpass e@(PWFEntry n password _)
                                | n == name = PWFEntry n password ra'
                                | otherwise = e
                          let pwf' = map newpass pwf
                          let ss' = ServiceState game_id'' game_list pwf'
                          write_pwf pwf'   --- XXX failure will hang server
                          putMVar state ss'
                let clean_up e = do
                    logMsg $ "game " ++ client_id ++
                             " incurs IO error: " ++ show e
                    liftIO $ do
                      close_it h
                      close_it other_h
                    where
                      close_it h = 
                        catch (do
                                  hPutStrLn h "420 fatal IO error: exiting"
                                  hClose h)
                              (\_ -> return ())
                catchLogIO run_game clean_up
                (ServiceState game_id'' game_list pwf) <- liftIO $ takeMVar state
                let exclude_me (InProgress game_id' _ _ _)
                       | game_id == game_id' = False
                    exclude_me _ = True
                let gl' = filter exclude_me game_list
                liftIO $ putMVar state (ServiceState game_id'' gl' pwf)
                liftIO $ putMVar wchan ()
              Nevermind ->
                alsoLogMsg h "421 offer countermanded"
        where
          valid_color "W" = True
          valid_color "B" = True
          valid_color _ = False
      ["accept", accept_game_id] -> do
        maybe_my_name <- liftIO $ readIORef me
        case (parse_int accept_game_id, maybe_my_name) of
          (_, Nothing) ->
            liftIO $ hPutStrLn h "406 must set name first using me command"
          (Nothing, _) ->
            liftIO $ hPutStrLn h "407 bad game id"
          (Just ask_id, Just my_name) -> do
            ss@(ServiceState game_id game_list pwf) <- liftIO $ takeMVar state
            game <- game_lookup game_list ask_id
            case game of
              Left error -> do
                liftIO $ putMVar state ss
                alsoLogMsg h error
              Right (other_name, wakeup, game_list') ->  do
                liftIO $ putMVar state $ ServiceState game_id game_list' pwf
                logMsg $ "client " ++ client_id ++
                         " accepts " ++ show other_name
                liftIO $ do
                  writeIORef continue False
                  hPutStrLn h "103 accepting offer"
                  writeChan wakeup $ Wakeup my_name client_id h
      ["clean"] -> do
        maybe_my_name <- liftIO $ readIORef me
        case maybe_my_name of
          Nothing -> liftIO $ hPutStrLn h $
                     "406 must set name first using me command"
          Just my_name -> do
            ss@(ServiceState game_id game_list pwf) <- liftIO $ takeMVar state
            let (my_list, other_list) = partition my_game game_list
            let ss' = ServiceState game_id other_list pwf
            liftIO $ putMVar state ss'
            liftIO $ mapM_ close_game my_list
            liftIO $ hPutStrLn h $ "204 " ++ show (length my_list) ++
                                   " games cleaned"
            where
              my_game (GameResv { game_resv_name = name })
                  | name == my_name = True
              my_game _ = False
              close_game gr = writeChan (game_resv_wakeup gr) Nevermind
      ["stop"] -> do
        maybe_my_name <- liftIO $ readIORef me
        case maybe_my_name of
          Nothing -> liftIO $ hPutStrLn h $
                     "406 must set name first using me command"
          Just "admin" -> do
            logMsg $ "stopping server for " ++ client_id
            liftIO $ do
              hPutStrLn h "205 server stopping, goodbye"
              ss@(ServiceState game_id game_list pwf) <- takeMVar state
              let ss' = ServiceState game_id [] pwf
              putMVar state ss'
              mapM_ close_game game_list
              hClose h
            exitSuccessLogIO
            where
              close_game (GameResv { game_resv_wakeup = w }) =
                  writeChan w Nevermind
              close_game (InProgress { in_progress_wakeup = w }) = do
                  readMVar w
          Just _ -> liftIO $ hPutStrLn h "502 admin only"
      _ -> liftIO $ hPutStrLn h $ "501 unknown command"
