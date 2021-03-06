module Sim (simulate, SCircuit, Circuit, simulateIO, stateless) where
import Data.Typeable

simulate f input s = do
  putStr "Input: "
  putStr $ show input
  putStr "\nInitial State: "
  putStr $ show s
  putStr "\n\n"
  foldl1 (>>) (map (printOutput) output)
  where
    output = run f input s

-- A circuit with input of type a, state of type s and output of type b
type SCircuit i s o = i -> s -> (s, o)
type Circuit i o = i -> o

run :: SCircuit i s o -> [i] -> s -> [(i, o, s)]
run f (i:input) s =
  (i, o, s'): (run f input s')
  where
    (s', o) = f i s
run _ [] _ = []

simulateIO :: (Read i, Show i, Show o, Show s) => SCircuit i s o -> s -> IO()
simulateIO c s = do
  putStr "Initial State: "
  putStr $ show s
  putStr "\n\n"
  runIO c s

runIO :: (Read i, Show i, Show o, Show s) => SCircuit i s o -> s -> IO()
runIO f s = do
  putStr "\nInput? "
  line <- getLine
  if (line == "") then
      return ()
    else
      let i = (read line) in do
      let (s', o) = f i s in do
      printOutput (i, o, s')
      simulateIO f s'

printOutput :: (Show i, Show o, Show s) => (i, o, s) -> IO ()
printOutput (i, o, s) = do
  putStr "Input: "
  putStr $ show i
  putStr "\nOutput: "
  putStr $ show o
  putStr "\nNew State: "
  putStr $ show s
  putStr "\n\n"

-- Takes a stateless circuit and turns it into a stateful circuit (with an
-- empty state) so it can be used in simulation
stateless :: Circuit i o -> SCircuit i () o
stateless f = \i s -> (s, f i)

-- vim: set ts=8 sw=2 sts=2 expandtab:
