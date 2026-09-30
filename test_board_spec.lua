local DIR = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"

package.preload["gettext"] = function()
    return setmetatable({}, { __call = function(_, s) return s end })
end
package.path = DIR .. "common/?.lua;" .. DIR .. "?.lua;" .. package.path

describe("Backgammon", function()
    local Board

    setup(function()
        Board = require("board")
    end)

    local function newBoard()
        return Board:new()
    end

    describe("construction / reset", function()
        it("sets up the standard starting position with 15 checkers per side", function()
            local b = newBoard()
            local counts = { white = 0, black = 0 }
            for i = 1, 24 do
                local pt = b.points[i]
                if pt.color then counts[pt.color] = counts[pt.color] + pt.count end
            end
            assert.are.equal(15, counts.white)
            assert.are.equal(15, counts.black)
            assert.are.equal("white", b.turn)
            assert.are.equal("playing", b.status)
        end)

        it("places checkers at the standard points", function()
            local b = newBoard()
            assert.are.equal(2, b.points[24].count)
            assert.are.equal("white", b.points[24].color)
            assert.are.equal(5, b.points[13].count)
            assert.are.equal(3, b.points[8].count)
            assert.are.equal(5, b.points[6].count)
            assert.are.equal(2, b.points[1].count)
            assert.are.equal("black", b.points[1].color)
            assert.are.equal(5, b.points[12].count)
            assert.are.equal(3, b.points[17].count)
            assert.are.equal(5, b.points[19].count)
        end)
    end)

    describe("rollDice", function()
        it("populates 2 dice normally, 4 on doubles", function()
            local b = newBoard()
            local doubles_seen, normal_seen = false, false
            for seed = 1, 60 do
                math.randomseed(seed)
                b.remaining_dice = {}
                local dice = b:rollDice()
                if dice[1] == dice[2] then
                    assert.are.equal(4, #b.remaining_dice)
                    doubles_seen = true
                else
                    assert.are.equal(2, #b.remaining_dice)
                    normal_seen = true
                end
                if doubles_seen and normal_seen then break end
            end
            assert.is_true(doubles_seen and normal_seen)
        end)

        it("refuses to reroll while dice are still in hand", function()
            local b = newBoard()
            b:rollDice()
            assert.is_true(#b.remaining_dice > 0)
            local again = b:rollDice()
            assert.is_nil(again)
        end)
    end)

    describe("getLegalMoves", function()
        it("computes correct destinations for White from the starting position", function()
            local b = newBoard()
            local moves = b:getLegalMoves(6)
            local dests = {}
            for _, m in ipairs(moves) do dests[m.from .. "->" .. m.to] = true end
            assert.is_true(dests["24->18"])
            assert.is_true(dests["13->7"])
            assert.is_true(dests["8->2"])
        end)

        it("blocks landing on a point with 2+ opposing checkers", function()
            local b = newBoard()
            -- point 19 has 5 black checkers; White at 24 moving 5 would land there
            local moves = b:getLegalMoves(5)
            for _, m in ipairs(moves) do
                assert.are_not.equal(19, m.to)
            end
        end)

        it("allows hitting a single opposing checker (blot)", function()
            local b = newBoard()
            for i = 1, 24 do b.points[i] = { color = nil, count = 0 } end
            b.points[10] = { color = "white", count = 1 }
            b.points[5]  = { color = "black", count = 1 }
            b.bar = { white = 0, black = 0 }
            b.turn = "white"
            local moves = b:getLegalMoves(5)
            local found = false
            for _, m in ipairs(moves) do
                if m.from == 10 and m.to == 5 then found = true end
            end
            assert.is_true(found)
        end)

        it("forces bar re-entry before any other move", function()
            local b = newBoard()
            b.bar.white = 1
            b.turn = "white"
            local moves = b:getLegalMoves(3)
            assert.are.equal(1, #moves)
            assert.are.equal("bar", moves[1].from)
            assert.are.equal(22, moves[1].to)  -- 25 - 3
        end)

        it("blocks bar entry onto a point with 2+ opposing checkers", function()
            local b = newBoard()
            b.bar.white = 1
            b.turn = "white"
            -- White entering with die=6 would land on point 19 (25-6), which
            -- has 5 black checkers -- blocked.
            local moves = b:getLegalMoves(6)
            assert.are.equal(0, #moves)
        end)
    end)

    describe("canBearOff / bearing off", function()
        it("is false while any checker remains outside the home board", function()
            local b = newBoard()
            assert.is_false(b:canBearOff("white"))
        end)

        it("is true once all 15 checkers are in the home board", function()
            local b = newBoard()
            for i = 1, 24 do b.points[i] = { color = nil, count = 0 } end
            b.points[3] = { color = "white", count = 15 }
            b.bar = { white = 0, black = 0 }
            b.off = { white = 0, black = 0 }
            assert.is_true(b:canBearOff("white"))
        end)

        it("allows exact bear-off and blocks non-exact when a higher checker exists", function()
            local b = newBoard()
            for i = 1, 24 do b.points[i] = { color = nil, count = 0 } end
            b.points[3] = { color = "white", count = 1 }
            b.points[5] = { color = "white", count = 14 }
            b.bar = { white = 0, black = 0 }
            b.off = { white = 0, black = 0 }
            local moves3 = b:getLegalMoves(3)
            local exact = false
            for _, m in ipairs(moves3) do if m.from == 3 and m.to == "off" then exact = true end end
            assert.is_true(exact)

            -- die=6 on point3 (distance 3) would be an overshoot, but point5
            -- still has checkers (further from home), so it's illegal.
            local moves6 = b:getLegalMoves(6)
            local overshoot = false
            for _, m in ipairs(moves6) do if m.from == 3 and m.to == "off" then overshoot = true end end
            assert.is_false(overshoot)
        end)

        it("allows overshoot bear-off when no checker sits further from home", function()
            local b = newBoard()
            for i = 1, 24 do b.points[i] = { color = nil, count = 0 } end
            b.points[3] = { color = "white", count = 1 }
            b.points[2] = { color = "white", count = 14 }
            b.bar = { white = 0, black = 0 }
            b.off = { white = 0, black = 0 }
            local moves = b:getLegalMoves(6)
            local overshoot = false
            for _, m in ipairs(moves) do if m.from == 3 and m.to == "off" then overshoot = true end end
            assert.is_true(overshoot)
        end)
    end)

    describe("applyMove", function()
        it("moves a checker and consumes the matching die", function()
            local b = newBoard()
            b.remaining_dice = { 6, 2 }
            local result = b:applyMove(24, 6)
            assert.are.equal("ok", result)
            assert.are.equal(1, b.points[24].count)
            assert.are.equal(1, b.points[18].count)
            assert.are.equal("white", b.points[18].color)
            assert.are.same({ 2 }, b.remaining_dice)
        end)

        it("rejects a die not currently in hand", function()
            local b = newBoard()
            b.remaining_dice = { 6, 2 }
            assert.are.equal("invalid", b:applyMove(24, 5))
        end)

        it("sends a hit opposing blot to the bar", function()
            local b = newBoard()
            for i = 1, 24 do b.points[i] = { color = nil, count = 0 } end
            b.points[10] = { color = "white", count = 1 }
            b.points[5]  = { color = "black", count = 1 }
            b.bar = { white = 0, black = 0 }
            b.off = { white = 0, black = 0 }
            b.turn = "white"
            b.remaining_dice = { 5 }
            local result = b:applyMove(10, 5)
            assert.are.equal("turn_ended", result)  -- only 1 die given, hand empties
            assert.are.equal("white", b.points[5].color)
            assert.are.equal(1, b.points[5].count)
            assert.are.equal(1, b.bar.black)
        end)

        it("ends the turn and switches player once all dice are used", function()
            local b = newBoard()
            b.remaining_dice = { 6 }
            local result = b:applyMove(24, 6)
            assert.are.equal("turn_ended", result)
            assert.are.equal("black", b.turn)
            assert.are.equal(0, #b.remaining_dice)
        end)

        it("declares a winner once all 15 checkers are off", function()
            local b = newBoard()
            for i = 1, 24 do b.points[i] = { color = nil, count = 0 } end
            b.points[1] = { color = "white", count = 1 }
            b.off = { white = 14, black = 0 }
            b.bar = { white = 0, black = 0 }
            b.turn = "white"
            b.remaining_dice = { 1 }
            local result = b:applyMove(1, 1)
            assert.are.equal("won", result)
            assert.are.equal("ended", b.status)
            assert.are.equal("white", b.winner)
            assert.are.equal(15, b.off.white)
        end)
    end)

    describe("serialize / load", function()
        it("round-trips the starting position", function()
            local b = newBoard()
            local data = b:serialize()
            local b2 = Board:new()
            local ok = b2:load(data)
            assert.is_true(ok)
            assert.are.equal(b.points[24].count, b2.points[24].count)
            assert.are.equal(b.turn, b2.turn)
        end)

        it("round-trips mid-game state including bar/off/dice", function()
            local b = newBoard()
            b.remaining_dice = { 4, 4, 4, 4 }
            b:applyMove(24, 4)
            local data = b:serialize()
            local b2 = Board:new()
            assert.is_true(b2:load(data))
            assert.are.same(b.remaining_dice, b2.remaining_dice)
            assert.are.equal(b.points[20].count, b2.points[20].count)
        end)

        it("load returns false for invalid data", function()
            local b = Board:new()
            assert.is_false(b:load(nil))
            assert.is_false(b:load({}))
        end)

        it("load rejects data with the wrong total checker count (checksum guard)", function()
            local b = newBoard()
            local data = b:serialize()
            data.points[24].count = data.points[24].count - 1  -- now only 14 white
            local b2 = Board:new()
            assert.is_false(b2:load(data))
        end)
    end)
end)

describe("doubling cube", function()
    local Backgammon
    setup(function() Backgammon = require("board") end)

    local function fresh()
        local b = Backgammon:new()
        b:reset()
        b.turn = "white"
        return b
    end

    it("starts in the middle at stake 1, offerable by whoever is to play", function()
        local b = fresh()
        assert.are.equal(1, b.cube_value)
        assert.is_nil(b.cube_owner)
        assert.is_true(b:canDouble("white"))
        b.turn = "black"
        assert.is_true(b:canDouble("black"))
    end)

    it("refuses a double once the dice are in hand", function()
        -- Doubling after seeing the roll would be playing with known dice.
        local b = fresh()
        b.remaining_dice = { 3, 5 }
        assert.is_false(b:canDouble("white"))
    end)

    it("hands the cube to the accepter, who alone may redouble", function()
        local b = fresh()
        assert.is_true(b:offerDouble("white"))
        assert.is_true(b:acceptDouble())
        assert.are.equal(2, b.cube_value)
        assert.are.equal("black", b.cube_owner)

        b.turn = "white"
        assert.is_false(b:canDouble("white"), "white no longer owns the cube")
        b.turn = "black"
        assert.is_true(b:canDouble("black"))
    end)

    it("ends the game when a double is declined, at the stake before it", function()
        local b = fresh()
        b:offerDouble("white")
        assert.is_true(b:declineDouble())
        assert.are.equal("ended", b.status)
        assert.are.equal("white", b.winner)
        assert.are.equal(1, b.cube_value, "the refused double does not count")
        assert.are.equal(1, b:stake())
    end)

    it("stops at 64", function()
        local b = fresh()
        b.cube_value = 64
        assert.is_false(b:canDouble("white"))
    end)

    it("scores a gammon at double and a backgammon at triple", function()
        local b = fresh()
        b.cube_value = 2
        b.status, b.winner = "ended", "white"

        -- Loser bore at least one checker off: plain stake.
        b.off = { white = 15, black = 1 }
        assert.are.equal(2, b:stake())

        -- Loser bore nothing off and is clear of the winner's home: gammon.
        b.off = { white = 15, black = 0 }
        b.bar = { white = 0, black = 0 }
        for i = 1, 24 do b.points[i] = { color = nil, count = 0 } end
        b.points[20] = { color = "black", count = 15 }
        assert.are.equal(4, b:stake())

        -- Still on the bar: backgammon.
        b.bar = { white = 0, black = 1 }
        assert.are.equal(6, b:stake())
    end)
end)

