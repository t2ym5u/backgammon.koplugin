# Changelog

All notable changes to this project will be documented in this file.

## [1.2.0] - 2026-09-30

### Added
- **Doubling cube**, the last thing the README admitted was missing. Offered
  before rolling by whoever owns the cube (either player while it sits in the
  middle); accepting doubles the stake and hands the cube to the accepter, who
  alone may redouble; declining ends the game at the stake *before* the refused
  double, which is the whole point of the cube -- it lets a player bank a win
  rather than play it out. Capped at 64.
- Games are now scored rather than just won: the stake doubles for a gammon
  (the loser bore nothing off) and triples for a backgammon (and still had a
  checker on the bar or in the winner's home board).
- Against the computer there is nobody to hand the offer to, so it answers
  itself: it takes unless it is more than a quarter behind on the pip count.
  Simple, roughly right, and never absurd.

### Note
- The computer never offers a double of its own. Declining to double is never
  a blunder that loses a game, whereas offering badly is, and a sound doubling
  policy needs equity estimates this engine does not have.

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
