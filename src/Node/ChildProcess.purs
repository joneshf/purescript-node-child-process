module Node.ChildProcess
  ( Handle()
  , ChildProcess()
  , CHILD_PROCESS()
  , stderr
  , stdout
  , stdin
  , pid
  , connected
  , kill
  , send
  , disconnect
  , ChildProcessError()
  , onExit
  , onClose
  , onDisconnect
  , onMessage
  , onError
  , spawn
  , SpawnOptions()
  , StdIOBehaviour()
  , defaultSpawnOptions
  ) where

import Prelude

import Control.Monad.Eff (Eff())

import Data.StrMap (StrMap())
import Data.Function (Fn2(), runFn2)
import Data.Nullable (Nullable(), toNullable)
import Data.Maybe (Maybe(..), fromMaybe)
import Data.Foreign (Foreign())
import Unsafe.Coerce (unsafeCoerce)

import Node.FS as FS
import Node.Buffer (Buffer())
import Node.Stream (Readable(), Writable(), Stream())
import Node.ChildProcess.Signal (Signal(..))

-- | A handle for inter-process communication (IPC).
foreign import data Handle :: *

-- | The effect for creating and interacting with child processes.
foreign import data CHILD_PROCESS :: !

newtype ChildProcess = ChildProcess ChildProcessRec

runChildProcess :: ChildProcess -> ChildProcessRec
runChildProcess (ChildProcess r) = r

-- | Note: some of these types are lies, and so it is unsafe to access some of
-- | these record fields directly.
type ChildProcessRec =
  { stderr     :: forall eff. Readable () (cp :: CHILD_PROCESS | eff) Buffer
  , stdin      :: forall eff. Writable () (cp :: CHILD_PROCESS | eff) Buffer
  , stdout     :: forall eff. Readable () (cp :: CHILD_PROCESS | eff) Buffer
  , pid        :: Int
  , connected  :: Boolean
  , kill       :: Signal -> Boolean
  , send       :: forall r. Fn2 { | r} Handle Boolean
  , disconnect :: forall eff. Eff eff Unit
  }

-- | The standard error stream of a child process. Note that this is only
-- | available if the process was spawned with the stderr option set to "pipe".
stderr :: forall eff. ChildProcess -> Readable () (cp :: CHILD_PROCESS | eff) Buffer
stderr = _.stderr <<< runChildProcess

-- | The standard output stream of a child process. Note that this is only
-- | available if the process was spawned with the stdout option set to "pipe".
stdout :: forall eff. ChildProcess -> Readable () (cp :: CHILD_PROCESS | eff) Buffer
stdout = _.stdout <<< runChildProcess

-- | The standard input stream of a child process. Note that this is only
-- | available if the process was spawned with the stdin option set to "pipe".
stdin :: forall eff. ChildProcess -> Writable () (cp :: CHILD_PROCESS | eff) Buffer
stdin = _.stdin <<< runChildProcess

-- | The process ID of a child process. Note that if the process has already
-- | exited, another process may have taken the same ID, so be careful!
pid :: ChildProcess -> Int
pid = _.pid <<< runChildProcess

connected :: forall eff. ChildProcess -> Eff (cp :: CHILD_PROCESS | eff) Boolean
connected = pure <<< _.connected <<< runChildProcess

send :: forall eff props. { | props } -> Handle -> ChildProcess -> Eff (cp :: CHILD_PROCESS | eff) Boolean
send msg handle (ChildProcess cp) = pure (runFn2 cp.send msg handle)

disconnect :: forall eff. ChildProcess -> Eff (cp :: CHILD_PROCESS | eff) Unit
disconnect = _.disconnect <<< runChildProcess

-- | Send a signal to a child process. It's an unfortunate historical decision
-- | that this function is called "kill", as sending a signal to a child
-- | process won't necessarily kill it.
kill :: forall eff. Signal -> ChildProcess -> Eff (cp :: CHILD_PROCESS | eff) Boolean
kill sig (ChildProcess cp) = pure (cp.kill sig)

type SpawnOptions =
  { cwd       :: Maybe String
  , stdio     :: Array (Maybe StdIOBehaviour)
  , env       :: Maybe (StrMap String)
  , detached  :: Boolean
  , uid       :: Maybe Int
  , gid       :: Maybe Int
  }

onExit :: forall eff. ChildProcess -> (Maybe Int -> Maybe Signal -> Eff eff Unit) -> Eff eff Unit
onExit = mkOnExit Nothing Just Signal

foreign import mkOnExit :: forall a eff.
          Maybe a -> (a -> Maybe a) -> (String -> Signal) ->
          ChildProcess -> (Maybe Int -> Maybe Signal -> Eff eff Unit) -> Eff eff Unit

onClose :: forall eff. ChildProcess -> (Maybe Int -> Maybe Signal -> Eff eff Unit) -> Eff eff Unit
onClose = mkOnClose Nothing Just Signal

foreign import mkOnClose :: forall a eff.
          Maybe a -> (a -> Maybe a) -> (String -> Signal) ->
          ChildProcess -> (Maybe Int -> Maybe Signal -> Eff eff Unit) -> Eff eff Unit

onMessage :: forall eff.  ChildProcess -> (Foreign -> Maybe Handle -> Eff eff Unit) -> Eff eff Unit
onMessage = mkOnMessage Nothing Just

foreign import mkOnMessage :: forall a eff.
          Maybe a -> (a -> Maybe a) ->
          ChildProcess -> (Foreign -> Maybe Handle -> Eff eff Unit) -> Eff eff Unit

foreign import onDisconnect :: forall eff. ChildProcess -> Eff eff Unit -> Eff eff Unit
foreign import onError :: forall eff. ChildProcess -> (ChildProcessError -> Eff eff Unit) -> Eff eff Unit

spawn :: forall eff. String -> Array String -> SpawnOptions -> Eff (cp :: CHILD_PROCESS | eff) ChildProcess
spawn cmd args opts = spawnImpl cmd args (convertOpts opts)
  where
  convertOpts opts =
    { cwd: fromMaybe undefined opts.cwd
    , stdio: toActualStdIOOptions opts.stdio
    , env: toNullable opts.env
    , detached: opts.detached
    , uid: fromMaybe undefined opts.uid
    , gid: fromMaybe undefined opts.gid
    }

foreign import spawnImpl :: forall opts eff. String -> Array String -> { | opts } -> Eff (cp :: CHILD_PROCESS | eff) ChildProcess

-- There's gotta be a better way.
foreign import undefined :: forall a. a

defaultSpawnOptions :: SpawnOptions
defaultSpawnOptions =
  { cwd: Nothing
  , stdio: pipe
  , env: Nothing
  , detached: false
  , uid: Nothing
  , gid: Nothing
  }

-- | An error which occurred inside a child process.
type ChildProcessError =
  { code :: String
  , errno :: String
  , syscall :: String
  }

-- | Behaviour for standard IO streams (eg, standard input, standard output) of
-- | a child process.
-- |
-- | * `Pipe`: creates a pipe between the child and parent process, which can
-- |   then be accessed as a `Stream` via the `stdin`, `stdout`, or `stderr`
-- |   functions.
-- | * `Ignore`: ignore this stream. This will cause Node to open /dev/null and
-- |   connect it to the stream.
-- | * `ShareStream`: Connect the supplied stream to the corresponding file
-- |    descriptor in the child.
-- | * `ShareFD`: Connect the supplied file descriptor (which should be open
-- |   in the parent) to the corresponding file descriptor in the child.
data StdIOBehaviour
  = Pipe
  | Ignore
  | ShareStream (forall r eff a. Stream r eff a)
  | ShareFD FS.FileDescriptor

-- | Create pipes for each of the three standard IO streams.
pipe :: Array (Maybe StdIOBehaviour)
pipe = map Just [Pipe, Pipe, Pipe]

-- | Share stdin with stdin, stdout with stdout, and stderr with stderr.
inherit :: Array (Maybe StdIOBehaviour)
inherit = map Just
  [ ShareStream process.stdin
  , ShareStream process.stdout
  , ShareStream process.stderr
  ]

foreign import process :: forall props. { | props }

-- | Ignore all streams.
ignore :: Array (Maybe StdIOBehaviour)
ignore = map Just [Ignore, Ignore, Ignore]

foreign import data ActualStdIOBehaviour :: *

toActualStdIOBehaviour :: StdIOBehaviour -> ActualStdIOBehaviour
toActualStdIOBehaviour b = case b of
  Pipe               -> c "pipe"
  Ignore             -> c "ignore"
  ShareFD x          -> c x
  ShareStream stream -> c stream
  where
  c :: forall a. a -> ActualStdIOBehaviour
  c = unsafeCoerce

type ActualStdIOOptions = Array (Nullable ActualStdIOBehaviour)

toActualStdIOOptions :: Array (Maybe StdIOBehaviour) -> ActualStdIOOptions
toActualStdIOOptions = map (toNullable <<< map toActualStdIOBehaviour)
