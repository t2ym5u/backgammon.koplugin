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
    self.off             = { white = 0, black = 0 }
    self.turn              = "white"
    self.dice                = {}
    self.remaining_dice        = {}
    self.status                  = "playing"
    self.winner                    = nil
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

-- Returns an array of { from = "bar"|1..24, to = 1..24|"off" } for the
-- current turn's color using the given die value.
function Backgammon:getLegalMoves(die)
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

function Backgammon:hasAnyLegalMove()
    for _, d in ipairs(self.remaining_dice) do
        if #self:getLegalMoves(d) > 0 then return true end
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
    return true
end

return Backgammon
