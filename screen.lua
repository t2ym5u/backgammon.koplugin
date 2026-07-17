local _dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
local function lrequire(name)
    local key = _dir .. name
    if not package.loaded[key] then
        package.loaded[key] = assert(loadfile(_dir .. name .. ".lua"))()
    end
    return package.loaded[key]
end

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

This version is 2-player only (no AI), has no doubling cube, White always moves first, and does not enforce using both dice if only one has a legal play.
]])

local GAME_RULES_FR = [[
Backgammon — Règles (2 joueurs, tour par tour)

Les Blancs vont du point 24 vers le point 1 ; les Noirs vont du point 1 vers le point 24. Lancez les dés, puis touchez un pion pour le sélectionner et touchez une destination pour le déplacer. Un double donne 4 déplacements au lieu de 2.

Un point occupé par un seul pion adverse (isolé) peut être pris, l'envoyant sur la barre. Un pion sur la barre doit rentrer avant tout autre déplacement. Une fois vos 15 pions dans votre jan intérieur, vous pouvez les sortir.

Cette version est à 2 joueurs uniquement (pas d'IA), sans cube de doublement, les Blancs commencent toujours, et n'impose pas d'utiliser les deux dés si un seul a un coup légal.
]]

local BackgammonScreen = ScreenBase:extend{}

function BackgammonScreen:init()
    local state = self.plugin:loadState()
    self.board = BackgammonBoard:new()
    if not self.board:load(state) then
        self.board:reset()
    end
    ScreenBase.init(self)
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

    local roll_button = ButtonTable:new{
        width = math.floor(sw * 0.6),
        shrink_unneeded_width = true,
        buttons = {{
            { text = _("Roll dice"), callback = function() self:onRoll() end },
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
    else
        self:updateStatus()
    end
end

function BackgammonScreen:onNewGame()
    self.board:reset()
    self.plugin:saveState(self.board:serialize())
    self:buildLayout()
    UIManager:setDirty(self, function() return "ui", self.dimen end)
end

function BackgammonScreen:updateStatus(msg)
    local status
    if msg then
        status = msg
    elseif self.board.status == "ended" then
        local winner_label = self.board.winner == "white" and _("White") or _("Black")
        status = T(_("%1 wins!"), winner_label)
    else
        local turn_label = self.board.turn == "white" and _("White") or _("Black")
        if #self.board.remaining_dice > 0 then
            status = T(_("%1 to play  Dice: %2"),
                turn_label, table.concat(self.board.remaining_dice, ","))
        else
            status = T(_("%1 to play  Off W:%2 B:%3"),
                turn_label, self.board.off.white, self.board.off.black)
        end
    end
    ScreenBase.updateStatus(self, status)
end

return BackgammonScreen
