local _dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
local function lrequire(name)
    local key = _dir .. name
    if not package.loaded[key] then
        package.loaded[key] = assert(loadfile(_dir .. name .. ".lua"))()
    end
    return package.loaded[key]
end

local ButtonDialog    = require("ui/widget/buttondialog")
local ButtonTable     = require("ui/widget/buttontable")
local Device          = require("device")
local FrameContainer  = require("ui/widget/container/framecontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local Size            = require("ui/size")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local _               = require("i18n")
local T               = require("ffi/util").template

local ScreenBase = require("screen_base")

local BackgammonBoard       = lrequire("board")
local BackgammonBoardWidget = lrequire("board_widget")

local DeviceScreen = Device.screen

local GAME_RULES_EN = _([[
Backgammon — Rules (2-player pass-and-play)

White moves from point 24 toward point 1; Black moves from point 1 toward point 24. Roll the dice, then tap a checker to select it and tap a destination to move it by that many points. Doubles give 4 moves instead of 2.

A point with a single opposing checker (a blot) can be hit, sending it to the bar. A checker on the bar must re-enter the board before any other move. Once all 15 of your checkers are in your home board, you may bear them off.

A computer opponent is available from the options menu (it plays Black); otherwise two players share the device. Each side rolls one die to open and the higher starts. A turn must use as many dice as it legally can, and when only one of the two can be played it must be the higher. The doubling cube is available before rolling: accepting doubles the stake and passes the cube, declining ends the game at the stake before it.
]])

local GAME_RULES_FR = [[
Backgammon — Règles

Les Blancs vont du point 24 vers le point 1 ; les Noirs vont du point 1 vers le point 24. Lancez les dés, puis touchez un pion pour le sélectionner et touchez une destination pour le déplacer. Un double donne 4 déplacements au lieu de 2.

Un point occupé par un seul pion adverse (isolé) peut être pris, l'envoyant sur la barre. Un pion sur la barre doit rentrer avant tout autre déplacement. Une fois vos 15 pions dans votre jan intérieur, vous pouvez les sortir.

Un adversaire informatique est disponible depuis le menu des options (il joue les Noirs) ; sinon deux joueurs partagent l'appareil. Chaque camp lance un dé pour l'ouverture, le plus fort commence. Un tour doit utiliser autant de dés qu'il le peut légalement, et quand un seul des deux est jouable, ce doit être le plus grand. Le videau est disponible avant de lancer : accepter double l'enjeu et transmet le videau, refuser met fin à la partie à l'enjeu d'avant.
]]

local BackgammonScreen = ScreenBase:extend{}

function BackgammonScreen:init()
    local state = self.plugin:loadState()
    self.board = BackgammonBoard:new()
    if not self.board:load(state) then
        self.board:reset()
    self.board:rollOpening()
    end
    ScreenBase.init(self)
end

-- ---------------------------------------------------------------------------
-- Opponent
--
-- The AI always plays Black, so a solo player keeps the opening roll's verdict
-- rather than being handed a colour. Its whole turn is computed at once (see
-- board:getAITurn) and then applied move by move, with a pause between each so
-- the checkers can be seen travelling instead of teleporting.
-- ---------------------------------------------------------------------------

local AI_COLOR       = "black"
local AI_MOVE_DELAY  = 0.45   -- seconds between the AI's individual moves

function BackgammonScreen:isSolo()
    return self.plugin:getSetting("opponent", "human") == "ai"
end

function BackgammonScreen:getOpponentButtonText()
    return self:isSolo() and _("Opponent: Computer") or _("Opponent: Human")
end

function BackgammonScreen:toggleOpponent()
    self.plugin:saveSetting("opponent", self:isSolo() and "human" or "ai")
    self:updateStatus(self:isSolo()
        and _("The computer now plays Black.")
        or  _("Two players on one device."))
    self:maybeRunAI()
end

function BackgammonScreen:maybeRunAI()
    local board = self.board
    if not self:isSolo() then return end
    if board.status ~= "playing" or board.turn ~= AI_COLOR then return end
    if self.ai_thinking then return end
    self.ai_thinking = true

    UIManager:scheduleIn(AI_MOVE_DELAY, function()
        if board.status ~= "playing" or board.turn ~= AI_COLOR then
            self.ai_thinking = false
            return
        end
        if #board.remaining_dice == 0 then
            local dice = board:rollDice()
            self.board_widget:refresh()
            if dice then
                self:updateStatus(T(_("Computer rolled %1-%2."), dice[1], dice[2]))
            end
            self.ai_thinking = false
            self:maybeRunAI()
            return
        end

        local turn = board:getAITurn()
        if #turn == 0 then
            board:endTurn()
        else
            -- Apply only the first move here and come back for the rest, so
            -- each one gets its own refresh.
            local mv = turn[1]
            if board:applyMove(mv.from, mv.die) == "invalid" then board:endTurn() end
        end
        self.board_widget:refresh()
        self.plugin:saveState(self.board:serialize())
        self:updateStatus()
        self.ai_thinking = false
        self:maybeRunAI()
    end)
end

function BackgammonScreen:serializeState()
    return self.board:serialize()
end

function BackgammonScreen:buildLayout()
    local sw = DeviceScreen:getWidth()
    local sh = DeviceScreen:getHeight()
    local is_landscape = self:isLandscape()

    local title_bar = self:buildTitleBar(_("Backgammon"), function()
        return {
            { text = _("New game"), callback = function() self:onNewGame() end },
            { text = self:getOpponentButtonText(), callback = function() self:toggleOpponent() end },
            self:makeRulesButtonConfig(GAME_RULES_EN, GAME_RULES_FR),
        }
    end)

    local board_w = is_landscape and math.floor(sw * 0.85) or math.floor(sw * 0.94)
    local board_h = math.floor(board_w * 0.62)

    self.board_widget = BackgammonBoardWidget:new{
        board        = self.board,
        width        = board_w,
        height       = board_h,
        onCellAction = function(zone) self:onCellAction(zone) end,
    }

    local board_frame = FrameContainer:new{
        padding = Size.padding.default,
        margin  = Size.margin.default,
        self.board_widget,
    }

    self.status_text:setMaxWidth(board_frame:getSize().w)

    local roll_button = ButtonTable:new{
        width = math.floor(sw * 0.6),
        shrink_unneeded_width = true,
        buttons = {{
            { text = _("Roll dice"), callback = function() self:onRoll() end },
            { id = "double_btn", text = _("Double"), callback = function() self:onDouble() end },
        }},
    }

    local content = VerticalGroup:new{
        align = "center",
        board_frame,
        VerticalSpan:new{ width = Size.span.vertical_default },
        roll_button,
        VerticalSpan:new{ width = Size.span.vertical_default },
        self.status_text,
    }
    self:buildPortraitLayout(title_bar, content, nil)
    self:updateStatus()
end

-- ---------------------------------------------------------------------------
-- Doubling cube
-- ---------------------------------------------------------------------------

function BackgammonScreen:onDouble()
    local board = self.board
    if board.status ~= "playing" then return end
    if not board:canDouble() then
        if #board.remaining_dice > 0 then
            self:updateStatus(_("Double before rolling, not after."))
        elseif board.cube_owner and board.cube_owner ~= board.turn then
            self:updateStatus(_("Your opponent owns the cube."))
        else
            self:updateStatus(_("The cube is already at its maximum."))
        end
        return
    end

    local offerer = board.turn
    board:offerDouble(offerer)
    local stake = board.cube_value * 2
    local label = (offerer == "white") and _("White") or _("Black")

    -- Against the computer there is nobody to hand the dialog to: it answers.
    -- The rule is the simplest sound one -- take unless clearly behind in the
    -- race -- which is roughly right and never absurd. A player more than a
    -- quarter behind on pips is losing badly enough to drop.
    if self:isSolo() and offerer ~= AI_COLOR then
        local mine  = board:pipCount(AI_COLOR)
        local yours = board:pipCount(offerer)
        if mine > yours * 1.25 then
            board:declineDouble()
            self.plugin:saveState(self:serializeState())
            self:updateStatus()
            self:showMessage(T(_("The computer declines. %1 wins %2 point(s)."),
                               label, board:stake()), 4)
        else
            board:acceptDouble()
            self.plugin:saveState(self:serializeState())
            self:updateStatus(T(_("The computer accepts. Stake is now %1."), board.cube_value))
        end
        return
    end

    -- The answer is the opponent's, so it is asked outright rather than left
    -- as another button on a shared board.
    local dlg
    dlg = ButtonDialog:new{
        title   = T(_("%1 offers to double the stake to %2."), label, stake),
        buttons = {{
            { text = _("Accept"), callback = function()
                UIManager:close(dlg)
                board:acceptDouble()
                self.plugin:saveState(self:serializeState())
                self:updateStatus(T(_("Double accepted. Stake is now %1."), board.cube_value))
                self:maybeRunAI()
            end },
            { text = _("Decline"), callback = function()
                UIManager:close(dlg)
                board:declineDouble()
                self.plugin:saveState(self:serializeState())
                self:updateStatus()
                self:showMessage(T(_("%1 wins %2 point(s)."), label, board:stake()), 4)
            end },
        }},
    }
    UIManager:show(dlg)
end

function BackgammonScreen:onRoll()
    local board = self.board
    if board.status ~= "playing" then return end
    if #board.remaining_dice > 0 then
        self:updateStatus(_("Finish using your current dice first."))
        return
    end

    local dice = board:rollDice()
    self.board_widget:refresh()
    self.plugin:saveState(self:serializeState())

    if not dice then
        return
    elseif #board.remaining_dice == 0 then
        self:updateStatus(T(_("Rolled %1-%2 -- no legal moves, turn passed."), dice[1], dice[2]))
        self:maybeRunAI()
    else
        self:updateStatus(T(_("Rolled %1-%2."), dice[1], dice[2]))
    end
end

function BackgammonScreen:onCellAction(zone)
    local board = self.board
    if board.status ~= "playing" then return end
    if #board.remaining_dice == 0 then
        self:updateStatus(_("Roll the dice first."))
        return
    end

    if not board.selected then
        if board.bar[board.turn] > 0 and zone ~= "bar" then
            self:updateStatus(_("You must enter from the bar first."))
            return
        end
        if zone == "bar" then
            if board.bar[board.turn] > 0 then
                board.selected = { from = "bar" }
                self.board_widget:refresh()
            end
        elseif type(zone) == "number" then
            local pt = board.points[zone]
            if pt.color == board.turn and pt.count > 0 then
                board.selected = { from = zone }
                self.board_widget:refresh()
            end
        end
        return
    end

    local sel_from = board.selected.from
    if zone == sel_from then
        board.selected = nil
        self.board_widget:refresh()
        return
    end

    local dest = (zone == "off_white" or zone == "off_black") and "off" or zone

    local applied_die = nil
    for _, d in ipairs(board.remaining_dice) do
        for _, m in ipairs(board:getLegalMoves(d)) do
            if m.from == sel_from and m.to == dest then
                applied_die = d
                break
            end
        end
        if applied_die then break end
    end

    board.selected = nil

    if not applied_die then
        self.board_widget:refresh()
        self:updateStatus(_("Invalid move."))
        return
    end

    local result = board:applyMove(sel_from, applied_die)
    self.board_widget:refresh()
    self.plugin:saveState(self:serializeState())

    if result == "won" then
        self:updateStatus()
        local winner_label = board.winner == "white" and _("White") or _("Black")
        self:showMessage(T(_("%1 wins!"), winner_label), 4)
    elseif result == "turn_ended" then
        self:updateStatus(_("No more legal moves -- turn passed."))
        self:maybeRunAI()
    else
        self:updateStatus()
    end
end

function BackgammonScreen:onNewGame()
    self.board:reset()
    self.board:rollOpening()
    self.plugin:saveState(self.board:serialize())
    self:buildLayout()
    UIManager:setDirty(self, function() return "ui", self.dimen end)
    self:maybeRunAI()
end

function BackgammonScreen:updateStatus(msg)
    local status
    if msg then
        status = msg
    elseif self.board.status == "ended" then
        local winner_label = self.board.winner == "white" and _("White") or _("Black")
        status = T(_("%1 wins %2 point(s)!"), winner_label, self.board:stake())
    else
        local turn_label = self.board.turn == "white" and _("White") or _("Black")
        local cube = self.board.cube_value or 1
        if #self.board.remaining_dice > 0 then
            status = T(_("%1 to play  Dice: %2  Stake: %3"),
                turn_label, table.concat(self.board.remaining_dice, ","), cube)
        else
            status = T(_("%1 to play  Off W:%2 B:%3  Stake: %4"),
                turn_label, self.board.off.white, self.board.off.black, cube)
        end
    end
    ScreenBase.updateStatus(self, status)
end

return BackgammonScreen
