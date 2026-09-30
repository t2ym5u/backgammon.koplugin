# Changelog

All notable changes to this project will be documented in this file.

## [1.2.0] - 2026-09-30

### Added
- **Computer opponent.** A turn in backgammon is a whole sequence of moves,
  not one move, so the engine enumerates every legal sequence the dice allow
  and scores the position each leaves behind — race position, made points and
  primes, blots weighted by how easily they can be hit, checkers on the bar
  and borne off. It beat a random-legal-move player 20-0 over 20 games, at
  0.02s per turn and 0.84s at worst (doubles, four dice to place). Toggle it
  from the options menu; the computer plays Black.
- **Opening roll.** Each side rolls one die and the higher starts, playing
  that pair as its first move — rather than White simply always going first.
  Kept out of `reset()` so that setting up a position stays deterministic.

### Fixed
- A turn must now use as many dice as it legally can, and when only one of the
  two can be played it must be the higher one. Neither rule was enforced, so a
  player could quietly skip the awkward half of an awkward roll.

### Known gap
- Still no doubling cube.
