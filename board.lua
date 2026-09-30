-- BackgammonBoard — 2-player local pass-and-play, no AI.
--
-- Direction convention: White moves 24 -> 1 (bears off past 1, home =
-- points 1-6). Black moves 1 -> 24 (bears off past 24, home = points
-- 19-24). Starting position is the standard mirrored setup.
--
-- Explicitly OUT OF SCOPE for v1 (documented simplifications, not
-- omissions by oversight):
--   * AI opponent -- 2-player pass-and-play only.
--   * Doubling cube.
--   * Opening-roll-decides-first-player -- White always starts.
--   * Gammon / backgammon scoring multipliers -- first to bear off all 15
--     simply wins.
--   * Mandatory maximal-dice-usage -- a die is forfeited if it has no
--     legal application at the moment it's tried, rather than proving no
--     legal full-usage ordering exists across both dice.

local HOME_WHITE = { 1, 6 }
local HOME_BLACK = { 19, 24 }

local function direction(color) return color == "white" and -1 or 1 end
local function homeRange(color) return color == "white" and HOME_WHITE or HOME_BLACK end
local function otherColor(color) return color == "white" and "black" or "white" end

local Backgammon = {}
Backgammon.__index = Backgammon

function Backgammon:new()
    local obj = setmetatable({}, self)
    obj:reset()
    return obj
end

function Backgammon:reset()
    self.points = {}
    for i = 1, 24 do self.points[i] = { color = nil, count = 0 } end

    local function set(p, color, count) self.points[p] = { color = color, count = count } end
    set(24, "white", 2)
    set(13, "white", 5)
    set(8,  "white", 3)
    set(6,  "white", 5)
    set(1,  "black", 2)
    set(12, "black", 5)
    set(17, "black", 3)
    set(19, "black", 5)

    self.bar            = { white = 0, black = 0 }
    self.off            = { white = 0, black = 0 }
    self.dice           = {}
    self.remaining_dice = {}
    self.status         = "playing"
    self.winner         = nil
    self.opening_roll   = nil
    self.turn           = "white"

    -- Doubling cube. value is the current stake multiplier (1, 2, 4 ... 64).
    -- owner is the side that may double next: nil means the cube is in the
    -- middle and either player may. pending_double is the colour of a player
    -- who has offered and is waiting for an answer.
    self.cube_value     = 1
    self.cube_owner     = nil
    self.pending_double = nil
end

-- Real backgammon does not simply give White the first move: each side rolls
-- one die and the higher goes first, playing that pair as its opening roll.
-- Kept out of reset() on purpose -- reset() stays deterministic, so it can set
-- up a position for a test or a reload without the dice deciding anything --
-- and called by the screen when a game actually starts.
--
-- Rolls until the two differ, so the opening roll is never a double.
function Backgammon:rollOpening()
    local w, b
    repeat
        w, b = math.random(6), math.random(6)
    until w ~= b
    self.opening_roll   = { white = w, black = b }
    self.turn           = (w > b) and "white" or "black"
    self.dice           = { w, b }
    self.remaining_dice = { w, b }   -- never doubles: the loop above rerolls
    if not self:hasAnyLegalMove() then self:endTurn() end
    return self.opening_roll
end

-- Returns {d1, d2} and populates remaining_dice (4 entries on doubles).
-- Returns nil if dice are already in hand (must finish the current roll
-- via applyMove()/endTurn() first) or the game has ended.
function Backgammon:rollDice()
    if self.status ~= "playing" then return nil end
    if #self.remaining_dice > 0 then return nil end

    local d1 = math.random(6)
    local d2 = math.random(6)
    self.dice = { d1, d2 }
    self.remaining_dice = (d1 == d2) and { d1, d1, d1, d1 } or { d1, d2 }

    if not self:hasAnyLegalMove() then
        self:endTurn()
    end

    return self.dice
end

function Backgammon:_canLand(dest, color)
    local pt = self.points[dest]
    if pt.count == 0 then return true end
    if pt.color == color then return true end
    return pt.count == 1  -- single opposing checker (blot) can be hit
end

-- True once all 15 of `color`'s checkers are in its home board or already off.
function Backgammon:canBearOff(color)
    if self.bar[color] > 0 then return false end
    local range = homeRange(color)
    local home_count = 0
    for p = 1, 24 do
        local pt = self.points[p]
        if pt.color == color and pt.count > 0 then
            if p < range[1] or p > range[2] then return false end
            home_count = home_count + pt.count
        end
    end
    return (home_count + self.off[color]) == 15
end

-- Distance from point p to bearing off exactly (die value that removes it
-- with no overshoot).
local function bearOffDistance(p, color)
    return (color == "white") and p or (25 - p)
end

function Backgammon:_isValidBearOff(p, die, color)
    if not self:canBearOff(color) then return false end
    local dist = bearOffDistance(p, color)
    if die == dist then return true end
    if die < dist then return false end
    -- Overshoot: only legal if no checker sits further from home than p.
    local range = homeRange(color)
    if color == "white" then
        for pp = p + 1, range[2] do
            local pt = self.points[pp]
            if pt.color == color and pt.count > 0 then return false end
        end
    else
        for pp = range[1], p - 1 do
            local pt = self.points[pp]
            if pt.color == color and pt.count > 0 then return false end
        end
    end
    return true
end

-- Every move this die could make, ignoring the obligation to use as many dice
-- as possible. getLegalMoves() below applies that rule; this is what the rule
-- itself is computed from, so it must stay unfiltered or the two would
-- recurse into each other.
function Backgammon:_rawLegalMoves(die)
    local color = self.turn
    local moves = {}

    if self.bar[color] > 0 then
        local dest = (color == "white") and (25 - die) or die
        if self:_canLand(dest, color) then
            moves[#moves + 1] = { from = "bar", to = dest }
        end
        return moves
    end

    local can_bear_off = self:canBearOff(color)
    for p = 1, 24 do
        local pt = self.points[p]
        if pt.color == color and pt.count > 0 then
            local dest = p + direction(color) * die
            if dest >= 1 and dest <= 24 then
                if self:_canLand(dest, color) then
                    moves[#moves + 1] = { from = p, to = dest }
                end
            elseif can_bear_off and self:_isValidBearOff(p, die, color) then
                moves[#moves + 1] = { from = p, to = "off" }
            end
        end
    end
    return moves
end

-- A backgammon turn must use as many dice as it legally can, and when only
-- one of two can be played it must be the higher. Both halves of that rule
-- are the same question -- "how many dice can still be played from here?" --
-- so both fall out of the search below.

function Backgammon:_snapshot()
    local pts = {}
    for i = 1, 24 do
        pts[i] = { color = self.points[i].color, count = self.points[i].count }
    end
    local dice = {}
    for i, d in ipairs(self.remaining_dice) do dice[i] = d end
    return {
        points = pts, dice = dice, turn = self.turn,
        bar = { white = self.bar.white, black = self.bar.black },
        off = { white = self.off.white, black = self.off.black },
    }
end

function Backgammon:_restore(snap)
    for i = 1, 24 do
        self.points[i].color = snap.points[i].color
        self.points[i].count = snap.points[i].count
    end
    -- Refill in place rather than assigning a fresh table: _maxPlayable walks
    -- this list while restoring between branches, and swapping the table out
    -- from under its iterator left it looping over an orphaned copy -- it
    -- silently examined only the first die.
    local dice = self.remaining_dice
    for i = #dice, 1, -1 do dice[i] = nil end
    for i, d in ipairs(snap.dice) do dice[i] = d end
    self.turn = snap.turn
    self.bar.white, self.bar.black = snap.bar.white, snap.bar.black
    self.off.white, self.off.black = snap.off.white, snap.off.black
end

-- Moves a checker without any rule checking or turn bookkeeping. Used only by
-- the lookahead below, always between a snapshot and a restore.
function Backgammon:_applyRaw(move, die_idx)
    local color = self.turn
    if move.from == "bar" then
        self.bar[color] = self.bar[color] - 1
    else
        local src = self.points[move.from]
        src.count = src.count - 1
        if src.count == 0 then src.color = nil end
    end
    if move.to == "off" then
        self.off[color] = self.off[color] + 1
    else
        local dest = self.points[move.to]
        if dest.count == 1 and dest.color ~= nil and dest.color ~= color then
            self.bar[dest.color] = self.bar[dest.color] + 1
            dest.color, dest.count = color, 1
        else
            dest.color = color
            dest.count = dest.count + 1
        end
    end
    table.remove(self.remaining_dice, die_idx)
end

-- Greatest number of the remaining dice playable from here, and the largest
-- die that can start such a sequence.
function Backgammon:_maxPlayable()
    local best_count, best_die = 0, nil
    local snap = self:_snapshot()
    -- Iterate a copy: the body mutates self.remaining_dice on the way down.
    local dice = {}
    for i, d in ipairs(self.remaining_dice) do dice[i] = d end
    for idx, die in ipairs(dice) do
        local moves = self:_rawLegalMoves(die)
        for _, m in ipairs(moves) do
            self:_applyRaw(m, idx)
            local deeper = self:_maxPlayable()
            self:_restore(snap)
            local total = 1 + deeper
            if total > best_count or (total == best_count and die > (best_die or 0)) then
                best_count, best_die = total, die
            end
        end
    end
    return best_count, best_die
end

-- Legal moves for this die, with the use-as-many-dice-as-possible rule
-- applied: a move is only offered if playing it still leaves the longest
-- sequence available. That also enforces "play the higher die" when only one
-- of the two can be used, since the shorter branch is simply not offered.
function Backgammon:getLegalMoves(die)
    local raw = self:_rawLegalMoves(die)
    if #raw == 0 then return raw end

    local target, best_die = self:_maxPlayable()
    if target <= 1 then
        -- Only one die can be played at all, so it has to be the higher one
        -- that can be: offer this die only if nothing larger can play.
        if best_die and die < best_die then return {} end
        return raw
    end

    local die_idx
    for i, d in ipairs(self.remaining_dice) do
        if d == die then die_idx = i break end
    end
    if not die_idx then return {} end

    local snap = self:_snapshot()
    local kept = {}
    for _, m in ipairs(raw) do
        self:_applyRaw(m, die_idx)
        local after = self:_maxPlayable()
        self:_restore(snap)
        if 1 + after >= target then kept[#kept + 1] = m end
    end
    return kept
end

function Backgammon:hasAnyLegalMove()
    for _, d in ipairs(self.remaining_dice) do
        if #self:_rawLegalMoves(d) > 0 then return true end
    end
    return false
end

-- Applies a move using `die` (which must currently be in remaining_dice)
-- starting from `from` ("bar" or a point 1-24). Returns:
-- "ok" | "won" | "turn_ended" | "invalid" | "ended"
function Backgammon:applyMove(from, die)
    if self.status ~= "playing" then return "ended" end

    local die_idx = nil
    for i, d in ipairs(self.remaining_dice) do
        if d == die then die_idx = i; break end
    end
    if not die_idx then return "invalid" end

    local color = self.turn
    local move = nil
    for _, m in ipairs(self:getLegalMoves(die)) do
        if m.from == from then move = m; break end
    end
    if not move then return "invalid" end

    if move.from == "bar" then
        self.bar[color] = self.bar[color] - 1
    else
        local src = self.points[move.from]
        src.count = src.count - 1
        if src.count == 0 then src.color = nil end
    end

    if move.to == "off" then
        self.off[color] = self.off[color] + 1
    else
        local dest = self.points[move.to]
        if dest.count == 1 and dest.color ~= nil and dest.color ~= color then
            local opp = dest.color
            self.bar[opp] = self.bar[opp] + 1
            dest.color = color
            dest.count = 1
        else
            dest.color = color
            dest.count = dest.count + 1
        end
    end

    table.remove(self.remaining_dice, die_idx)

    if self.off[color] == 15 then
        self.status = "ended"
        self.winner = color
        return "won"
    end

    if #self.remaining_dice == 0 or not self:hasAnyLegalMove() then
        self:endTurn()
        return "turn_ended"
    end

    return "ok"
end

function Backgammon:endTurn()
    self.dice = {}
    self.remaining_dice = {}
    self.turn = otherColor(self.turn)
end

-- ---------------------------------------------------------------------------
-- AI
--
-- A backgammon turn is a whole sequence of moves, not one move, so the engine
-- enumerates every legal sequence the dice allow and scores the position each
-- one leaves behind. No lookahead into the opponent's roll: with 21 distinct
-- rolls to average over, a second ply costs far more than it is worth on an
-- e-ink CPU, and a sound positional evaluation already plays a decent game.
-- ---------------------------------------------------------------------------

-- Distance still to travel for every checker, the standard measure of who is
-- ahead in the race. Lower is better.
function Backgammon:pipCount(color)
    local pip = 0
    for p = 1, 24 do
        local pt = self.points[p]
        if pt.color == color and pt.count > 0 then
            pip = pip + pt.count * bearOffDistance(p, color)
        end
    end
    -- A checker on the bar re-enters at the far end: a full 25 to travel.
    pip = pip + self.bar[color] * 25
    return pip
end

-- How exposed a lone checker is: a blot the opponent can reach with one die
-- is far worse than one they would need a large roll for.
local function blotRisk(board, p, color)
    local opp = otherColor(color)
    local risk = 0
    for d = 1, 6 do
        local src = p - direction(color) * d          -- where a hitter would come from
        if src >= 1 and src <= 24 then
            local pt = board.points[src]
            if pt.color == opp and pt.count > 0 then risk = risk + (7 - d) end
        end
    end
    if board.bar[opp] > 0 then
        -- An opponent on the bar re-enters into their own home board and can
        -- hit from there on the same roll.
        local entry = (opp == "white") and (25 - p) or p
        if entry <= 6 then risk = risk + 6 end
    end
    return risk
end

-- Positive is good for `color`.
function Backgammon:evaluateFor(color)
    local opp = otherColor(color)
    local score = 0

    score = score + (self.off[color] - self.off[opp]) * 60
    score = score + (self:pipCount(opp) - self:pipCount(color)) * 1.0
    score = score + (self.bar[opp] - self.bar[color]) * 25

    local home = homeRange(color)
    local run, best_run = 0, 0
    for p = 1, 24 do
        local pt = self.points[p]
        if pt.color == color and pt.count >= 2 then
            score = score + 8                                   -- a made point
            if p >= home[1] and p <= home[2] then score = score + 6 end
            run = run + 1
            if run > best_run then best_run = run end
        else
            run = 0
        end
        if pt.color == color and pt.count == 1 then
            score = score - blotRisk(self, p, color) * 2
        end
        -- Stacking six on one point wastes checkers that could be making
        -- points elsewhere.
        if pt.color == color and pt.count > 4 then
            score = score - (pt.count - 4) * 3
        end
    end
    score = score + best_run * best_run          -- consecutive points: a prime

    return score
end

-- Every distinct sequence of moves the remaining dice allow, as a list of
-- { moves = { {from=, die=}, ... }, score = }. Sequences that reach the same
-- position are collapsed, which is what keeps doubles (four dice) tractable.
local MAX_SEQUENCES = 4000

function Backgammon:_enumerateTurns(color, seen, acc, path, budget)
    if budget.n >= MAX_SEQUENCES then return end

    local any = false
    local snap = self:_snapshot()
    local dice = {}
    for i, d in ipairs(self.remaining_dice) do dice[i] = d end

    local tried = {}
    for idx, die in ipairs(dice) do
        if not tried[die] then           -- identical dice give identical branches
            tried[die] = true
            for _, m in ipairs(self:getLegalMoves(die)) do
                any = true
                self:_applyRaw(m, idx)
                path[#path + 1] = { from = m.from, die = die }
                self:_enumerateTurns(color, seen, acc, path, budget)
                path[#path] = nil
                self:_restore(snap)
            end
        end
    end

    if not any then
        -- Nothing further can be played: this is a complete turn.
        local key = self:_positionKey()
        if not seen[key] then
            seen[key] = true
            local moves = {}
            for i, mv in ipairs(path) do moves[i] = { from = mv.from, die = mv.die } end
            acc[#acc + 1] = { moves = moves, score = self:evaluateFor(color) }
            budget.n = budget.n + 1
        end
    end
end

function Backgammon:_positionKey()
    local parts = {}
    for p = 1, 24 do
        local pt = self.points[p]
        parts[#parts + 1] = (pt.color == "white" and "w" or (pt.color == "black" and "b" or "-")) .. pt.count
    end
    parts[#parts + 1] = "B" .. self.bar.white .. "," .. self.bar.black
    parts[#parts + 1] = "O" .. self.off.white .. "," .. self.off.black
    return table.concat(parts, "|")
end

-- The whole turn, as an ordered list of { from = "bar"|1..24, die = n } ready
-- to feed back into applyMove(). Empty when the dice allow nothing.
function Backgammon:getAITurn()
    if self.status ~= "playing" then return {} end
    if #self.remaining_dice == 0 then return {} end

    local color = self.turn
    local seen, acc, budget = {}, {}, { n = 0 }
    local snap = self:_snapshot()
    self:_enumerateTurns(color, seen, acc, {}, budget)
    self:_restore(snap)

    if #acc == 0 then return {} end
    local best = acc[1]
    for i = 2, #acc do
        if acc[i].score > best.score then best = acc[i] end
    end
    return best.moves
end

-- ---------------------------------------------------------------------------
-- Doubling cube
--
-- Offered before rolling, by whoever currently owns the cube (either player
-- while it sits in the middle). Accepting doubles the stake and hands the cube
-- to the accepter, who alone may double next. Declining ends the game there
-- and then: the offerer wins what was already at stake, which is the whole
-- point of the cube -- it lets a player bank a win rather than play it out.
-- ---------------------------------------------------------------------------

local MAX_CUBE = 64

function Backgammon:canDouble(color)
    color = color or self.turn
    if self.status ~= "playing" then return false end
    if self.pending_double then return false end
    -- Only before rolling: a double mid-turn would be playing with the dice
    -- already seen.
    if #self.remaining_dice > 0 then return false end
    if color ~= self.turn then return false end
    if self.cube_value >= MAX_CUBE then return false end
    return self.cube_owner == nil or self.cube_owner == color
end

function Backgammon:offerDouble(color)
    color = color or self.turn
    if not self:canDouble(color) then return false end
    self.pending_double = color
    return true
end

function Backgammon:acceptDouble()
    if not self.pending_double then return false end
    local offerer = self.pending_double
    self.pending_double = nil
    self.cube_value = self.cube_value * 2
    -- The accepter now owns the cube and is the only one who may redouble.
    self.cube_owner = otherColor(offerer)
    return true
end

function Backgammon:declineDouble()
    if not self.pending_double then return false end
    local offerer = self.pending_double
    self.pending_double = nil
    self.status = "ended"
    self.winner = offerer
    self.declined = true
    return true
end

-- What the finished game is worth: the cube's value, doubled for a gammon
-- (the loser bore nothing off) and tripled for a backgammon (and still had a
-- checker on the bar or in the winner's home board). A declined double is
-- always worth the plain stake.
function Backgammon:stake()
    if self.status ~= "ended" or not self.winner then return self.cube_value end
    if self.declined then return self.cube_value end

    local loser = otherColor(self.winner)
    if self.off[loser] > 0 then return self.cube_value end

    local home = homeRange(self.winner)
    if self.bar[loser] > 0 then return self.cube_value * 3 end
    for p = home[1], home[2] do
        local pt = self.points[p]
        if pt.color == loser and pt.count > 0 then return self.cube_value * 3 end
    end
    return self.cube_value * 2
end

-- ---------------------------------------------------------------------------
-- Persistence
-- ---------------------------------------------------------------------------

function Backgammon:serialize()
    local points_out = {}
    for i = 1, 24 do
        points_out[i] = { color = self.points[i].color, count = self.points[i].count }
    end
    local dice_out = { self.dice[1], self.dice[2] }
    local remaining_out = {}
    for i, d in ipairs(self.remaining_dice) do remaining_out[i] = d end
    return {
        points         = points_out,
        bar            = { white = self.bar.white, black = self.bar.black },
        off            = { white = self.off.white, black = self.off.black },
        turn           = self.turn,
        dice           = dice_out,
        remaining_dice = remaining_out,
        status         = self.status,
        winner         = self.winner,
        cube_value     = self.cube_value,
        cube_owner     = self.cube_owner,
        pending_double = self.pending_double,
        declined       = self.declined,
    }
end

-- Validates that every one of the 15 checkers per color is accounted for
-- exactly once across points+bar+off before accepting.
function Backgammon:load(data)
    if type(data) ~= "table" or type(data.points) ~= "table" or #data.points ~= 24 then
        return false
    end

    local counts = { white = 0, black = 0 }
    for i = 1, 24 do
        local pt = data.points[i]
        if type(pt) ~= "table" then return false end
        if pt.color == "white" or pt.color == "black" then
            counts[pt.color] = counts[pt.color] + (pt.count or 0)
        elseif pt.color ~= nil then
            return false
        end
    end
    local bar = data.bar or {}
    local off = data.off or {}
    counts.white = counts.white + (bar.white or 0) + (off.white or 0)
    counts.black = counts.black + (bar.black or 0) + (off.black or 0)
    if counts.white ~= 15 or counts.black ~= 15 then return false end

    self.points = {}
    for i = 1, 24 do
        self.points[i] = { color = data.points[i].color, count = data.points[i].count or 0 }
    end
    self.bar    = { white = bar.white or 0, black = bar.black or 0 }
    self.off    = { white = off.white or 0, black = off.black or 0 }
    self.turn   = data.turn or "white"
    self.dice   = { (data.dice and data.dice[1]), (data.dice and data.dice[2]) }
    self.remaining_dice = {}
    if data.remaining_dice then
        for i, d in ipairs(data.remaining_dice) do self.remaining_dice[i] = d end
    end
    self.status = data.status or "playing"
    self.winner = data.winner
    self.cube_value     = data.cube_value or 1
    self.cube_owner     = data.cube_owner
    self.pending_double = data.pending_double
    self.declined       = data.declined
    return true
end

return Backgammon
