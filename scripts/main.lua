-- ============================================================================
-- 磁力冲浪者：隐形星路 (Magnetic Surfer: Invisible Star Path)
-- 教育物理游戏 - 通过切换磁极(N/S)驾驶飞船冲浪磁力线
-- 渲染: NanoVG (Mode B: 系统逻辑分辨率 + DPR)
-- ============================================================================

require "LuaScripts/Utilities/Sample"

-- ============================================================================
-- 1. 常量配置
-- ============================================================================
local SHIP_RADIUS = 14
local GOAL_RADIUS = 22
local FIELD_STRENGTH = 180000
local MAX_SPEED = 800
local DRAG = 0.999
local PARTICLE_MAX = 350
local PARTICLE_SPEED = 60
local TRAIL_MAX = 40
local SPAWN_INTERVAL = 0.03

-- 颜色
local CN = {255, 80, 80}       -- 北极红
local CS = {80, 130, 255}      -- 南极蓝
local CF = {255, 210, 60}      -- 磁力线金色
local CG = {80, 255, 160}      -- 目标绿

-- ============================================================================
-- 2. 全局状态
-- ============================================================================
local vg = nil
local fontNormal = -1
---@type Graphics
local gfx = nil

local gameState = "menu"   -- menu | levelSelect | playing | complete | fail
local gameTime = 0
local levelIndex = 1
local levelTime = 0

-- 屏幕尺寸 (逻辑像素，每帧更新)
local W, H = 800, 600
local dpr = 1

-- 飞船
local ship = {
    x = 0, y = 0,
    vx = 0, vy = 0,
    polarity = "N",   -- "N" 或 "S"
    trail = {},        -- { {x,y}, ... }
    alive = true,
    toggleFlash = 0,   -- 切换闪光计时
}

-- 粒子系统 (磁力线可视化)
local particles = {}   -- { {x,y,vx,vy,life,maxLife}, ... }
local spawnTimer = 0

-- 磁感线 (预计算)
local fieldLines = {}   -- { { {x,y}, {x,y}, ... }, ... }

-- 背景星星
local bgStars = {}

-- 当前关卡数据引用
local curLevel = nil

-- 关卡定义
local levels = {}

-- 过渡动画
local fadeAlpha = 1.0
local fadeDir = -1  -- -1=淡入, 1=淡出
local fadeCallback = nil

-- ============================================================================
-- 3. 关卡定义 (基于屏幕尺寸计算)
-- ============================================================================
local function InitLevels()
    levels = {
        -- 关卡1：推力起航 - 同性相斥
        {
            name = "推力起航",
            subtitle = "基础概念：同性相斥",
            desc = "将飞船切换为红色(N)，利用与红色星体的同性相斥力弹射出去！",
            tutorial = {
                "点击屏幕或按空格切换磁极",
                "红色=北极(N)  蓝色=南极(S)",
                "同性相斥，异性相吸！",
                "把自己变成红色(N)，让红色星体推你出去！",
            },
            stars = {
                { x = W * 0.15, y = H * 0.5, pol = "N", str = FIELD_STRENGTH * 0.7, r = 50 },
            },
            shipStart = { x = W * 0.28, y = H * 0.5 },
            shipPol = "S",
            goal = { x = W * 0.85, y = H * 0.5 },
            goalR = GOAL_RADIUS,
        },
        -- 关卡2：顺流而下 - 磁感线方向
        {
            name = "顺流而下",
            subtitle = "进阶：沿磁感线滑行",
            desc = "切换为S极被N极推开，沿磁感线滑向右侧S极附近的目标！",
            tutorial = {
                "磁感线从红色(N)流向蓝色(S)",
                "切换为蓝色(S)，被N极排斥推向右边",
                "靠近目标时切换为红色(N)",
                "利用S极的排斥力微调方向！",
            },
            stars = {
                { x = W * 0.20, y = H * 0.50, pol = "N", str = FIELD_STRENGTH * 0.6, r = 45 },
                { x = W * 0.80, y = H * 0.50, pol = "S", str = FIELD_STRENGTH * 0.5, r = 40 },
            },
            shipStart = { x = W * 0.35, y = H * 0.38 },
            shipPol = "N",
            goal = { x = W * 0.72, y = H * 0.30 },
            goalR = GOAL_RADIUS * 1.2,
        },
        -- 关卡3：磁力弹弓 - 双极变轨
        {
            name = "磁力弹弓",
            subtitle = "高阶：双极变轨",
            desc = "利用上方N极弹射，在中途切换磁极借S极转弯到达目标！",
            tutorial = {
                "先保持红色(N)被上方N极推开",
                "飞到中间时切换为蓝色(S)",
                "S极会吸引你转弯向下",
                "瞄准目标，适时再切换微调！",
            },
            stars = {
                { x = W * 0.30, y = H * 0.20, pol = "N", str = FIELD_STRENGTH * 0.5, r = 40 },
                { x = W * 0.70, y = H * 0.80, pol = "S", str = FIELD_STRENGTH * 0.4, r = 35 },
            },
            shipStart = { x = W * 0.15, y = H * 0.35 },
            shipPol = "N",
            goal = { x = W * 0.88, y = H * 0.65 },
            goalR = GOAL_RADIUS * 1.2,
        },
    }
end

-- ============================================================================
-- 4. 背景星空初始化
-- ============================================================================
local function InitBgStars()
    bgStars = {}
    for i = 1, 120 do
        bgStars[i] = {
            x = math.random() * W,
            y = math.random() * H,
            size = 0.5 + math.random() * 2.0,
            brightness = 0.3 + math.random() * 0.7,
            twinkleSpeed = 1.0 + math.random() * 3.0,
            twinklePhase = math.random() * math.pi * 2,
        }
    end
end

-- ============================================================================
-- 5. 磁力物理
-- ============================================================================

--- 计算某一点的磁场方向 (归一化)
---@return number, number 场强 fx, fy
local function FieldAt(px, py, includeShip)
    local fx, fy = 0, 0
    if not curLevel then return 0, 0 end

    for _, star in ipairs(curLevel.stars) do
        local dx = px - star.x
        local dy = py - star.y
        local distSq = dx * dx + dy * dy
        local dist = math.sqrt(distSq)
        if dist < 5 then dist = 5; distSq = 25 end

        -- N极: 场向外, S极: 场向内
        local sign = (star.pol == "N") and 1 or -1
        local mag = star.str / distSq
        fx = fx + sign * (dx / dist) * mag
        fy = fy + sign * (dy / dist) * mag
    end

    -- 飞船自身的场扰动 (field warping)
    if includeShip and ship.alive then
        local dx = px - ship.x
        local dy = py - ship.y
        local distSq = dx * dx + dy * dy
        local dist = math.sqrt(distSq)
        if dist > 15 then
            local sign = (ship.polarity == "N") and 1 or -1
            local mag = 3000 / distSq
            fx = fx + sign * (dx / dist) * mag
            fy = fy + sign * (dy / dist) * mag
        end
    end

    return fx, fy
end

--- 计算所有星体对飞船的合力
local function ForceOnShip()
    local fx, fy = 0, 0
    if not curLevel then return 0, 0 end

    for _, star in ipairs(curLevel.stars) do
        local dx = ship.x - star.x
        local dy = ship.y - star.y
        local distSq = dx * dx + dy * dy
        local dist = math.sqrt(distSq)
        if dist < 15 then dist = 15; distSq = 225 end

        local mag = star.str / distSq
        -- 同性相斥(+), 异性相吸(-)
        local same = (ship.polarity == star.pol)
        local sign = same and 1 or -1
        fx = fx + sign * (dx / dist) * mag
        fy = fy + sign * (dy / dist) * mag
    end

    return fx, fy
end

-- ============================================================================
-- 6. 粒子系统 (磁力线可视化)
-- ============================================================================

local function SpawnParticle()
    if not curLevel then return end
    if #particles >= PARTICLE_MAX then return end

    for _, star in ipairs(curLevel.stars) do
        if star.pol == "N" then
            -- N 极：从表面向外发散（金色）
            local angle = math.random() * math.pi * 2
            local px = star.x + math.cos(angle) * (star.r + 5)
            local py = star.y + math.sin(angle) * (star.r + 5)
            local life = 3.0 + math.random() * 3.0
            particles[#particles + 1] = {
                x = px, y = py,
                life = life,
                maxLife = life,
                speed = PARTICLE_SPEED * (0.7 + math.random() * 0.6),
                kind = "N",
            }
        else
            -- S 极：从远处向内汇聚（蓝色）
            local angle = math.random() * math.pi * 2
            local dist = star.r * 2.5 + math.random() * star.r * 3.0
            local px = star.x + math.cos(angle) * dist
            local py = star.y + math.sin(angle) * dist
            local life = 2.5 + math.random() * 2.5
            particles[#particles + 1] = {
                x = px, y = py,
                life = life,
                maxLife = life,
                speed = PARTICLE_SPEED * (0.6 + math.random() * 0.5),
                kind = "S",
                targetX = star.x,
                targetY = star.y,
                targetR = star.r,
            }
        end
    end

    -- 飞船尾迹粒子（较稀疏）
    if ship.alive and math.random() < 0.4 then
        local speed = math.sqrt(ship.vx * ship.vx + ship.vy * ship.vy)
        if speed > 20 then
            local spread = 6
            local px = ship.x + (math.random() - 0.5) * spread
            local py = ship.y + (math.random() - 0.5) * spread
            local life = 0.5 + math.random() * 0.8
            particles[#particles + 1] = {
                x = px, y = py,
                life = life,
                maxLife = life,
                speed = 0,
                kind = "ship",
                shipPol = ship.polarity,
            }
        end
    end
end

local function UpdateParticles(dt)
    spawnTimer = spawnTimer + dt
    while spawnTimer >= SPAWN_INTERVAL do
        spawnTimer = spawnTimer - SPAWN_INTERVAL
        SpawnParticle()
    end

    for i = #particles, 1, -1 do
        local p = particles[i]
        p.life = p.life - dt

        local absorbed = false

        if p.kind == "S" then
            -- S 极粒子：直接朝目标星体汇聚
            local dx = p.targetX - p.x
            local dy = p.targetY - p.y
            local dist = math.sqrt(dx * dx + dy * dy)
            if dist > 1 then
                p.x = p.x + (dx / dist) * p.speed * dt
                p.y = p.y + (dy / dist) * p.speed * dt
            end
            -- 到达 S 极核心被吸收
            if dist < p.targetR then
                absorbed = true
            end
        elseif p.kind == "ship" then
            -- 飞船尾迹：原地不动，自然衰减
        else
            -- N 极粒子：沿磁场方向移动
            local fx, fy = FieldAt(p.x, p.y, true)
            local fmag = math.sqrt(fx * fx + fy * fy)
            if fmag > 0.001 then
                p.x = p.x + (fx / fmag) * p.speed * dt
                p.y = p.y + (fy / fmag) * p.speed * dt
            end
            -- 被 S 极吸收
            if curLevel then
                for _, star in ipairs(curLevel.stars) do
                    if star.pol == "S" then
                        local dx = p.x - star.x
                        local dy = p.y - star.y
                        if dx * dx + dy * dy < star.r * star.r then
                            absorbed = true
                            break
                        end
                    end
                end
            end
        end

        -- 移除死亡粒子
        if p.life <= 0 or absorbed or p.x < -50 or p.x > W + 50 or p.y < -50 or p.y > H + 50 then
            particles[i] = particles[#particles]
            particles[#particles] = nil
        end
    end
end

-- ============================================================================
-- 6.5. 磁感线预计算
-- ============================================================================

--- 从一个起点沿磁场方向追踪一条磁感线
local function TraceFieldLine(startX, startY, maxSteps, stepSize)
    local line = { { x = startX, y = startY } }
    local px, py = startX, startY

    for _ = 1, maxSteps do
        local fx, fy = FieldAt(px, py, false)
        local fmag = math.sqrt(fx * fx + fy * fy)
        if fmag < 0.01 then break end

        px = px + (fx / fmag) * stepSize
        py = py + (fy / fmag) * stepSize

        -- 超出屏幕边界就停
        if px < -60 or px > W + 60 or py < -60 or py > H + 60 then
            line[#line + 1] = { x = px, y = py }
            break
        end

        -- 被 S 极吸收就停
        local absorbed = false
        if curLevel then
            for _, star in ipairs(curLevel.stars) do
                if star.pol == "S" then
                    local dx = px - star.x
                    local dy = py - star.y
                    if dx * dx + dy * dy < (star.r * 0.8) * (star.r * 0.8) then
                        -- 终点拉到星体边缘
                        local dist = math.sqrt(dx * dx + dy * dy)
                        if dist > 1 then
                            px = star.x + dx / dist * star.r * 0.8
                            py = star.y + dy / dist * star.r * 0.8
                        end
                        absorbed = true
                        break
                    end
                end
            end
        end

        line[#line + 1] = { x = px, y = py }
        if absorbed then break end
    end

    return line
end

--- 预计算当前关卡的所有磁感线
local function ComputeFieldLines()
    fieldLines = {}
    if not curLevel then return end

    local linesPerStar = 12  -- 每个 N 极发出的磁感线数量

    for _, star in ipairs(curLevel.stars) do
        if star.pol == "N" then
            for i = 1, linesPerStar do
                local angle = (i - 1) / linesPerStar * math.pi * 2
                local startX = star.x + math.cos(angle) * (star.r + 3)
                local startY = star.y + math.sin(angle) * (star.r + 3)
                local line = TraceFieldLine(startX, startY, 300, 4)
                if #line >= 3 then
                    fieldLines[#fieldLines + 1] = line
                end
            end
        end
    end
end

-- ============================================================================
-- 7. 游戏逻辑
-- ============================================================================

local function StartLevel(idx)
    levelIndex = idx
    InitLevels()
    curLevel = levels[idx]
    if not curLevel then return end

    -- 重置飞船
    ship.x = curLevel.shipStart.x
    ship.y = curLevel.shipStart.y
    ship.vx = 0
    ship.vy = 0
    ship.polarity = curLevel.shipPol
    ship.trail = {}
    ship.alive = true
    ship.toggleFlash = 0

    -- 清空粒子
    particles = {}
    spawnTimer = 0
    levelTime = 0

    -- 预计算磁感线
    ComputeFieldLines()

    gameState = "playing"
    fadeAlpha = 1.0
    fadeDir = -1
end

local function UpdateShip(dt)
    if not ship.alive then return end

    -- 计算磁力
    local fx, fy = ForceOnShip()

    -- 加速度 (假设质量 = 1)
    ship.vx = ship.vx + fx * dt
    ship.vy = ship.vy + fy * dt

    -- 阻尼
    ship.vx = ship.vx * DRAG
    ship.vy = ship.vy * DRAG

    -- 限速
    local speed = math.sqrt(ship.vx * ship.vx + ship.vy * ship.vy)
    if speed > MAX_SPEED then
        ship.vx = ship.vx / speed * MAX_SPEED
        ship.vy = ship.vy / speed * MAX_SPEED
    end

    -- 更新位置
    ship.x = ship.x + ship.vx * dt
    ship.y = ship.y + ship.vy * dt

    -- 更新轨迹
    ship.trail[#ship.trail + 1] = { x = ship.x, y = ship.y }
    while #ship.trail > TRAIL_MAX do
        table.remove(ship.trail, 1)
    end

    -- 切换闪光衰减
    if ship.toggleFlash > 0 then
        ship.toggleFlash = ship.toggleFlash - dt * 3.0
        if ship.toggleFlash < 0 then ship.toggleFlash = 0 end
    end
end

local function CheckCollisions()
    if not ship.alive or not curLevel then return end

    -- 检测撞击星体
    for _, star in ipairs(curLevel.stars) do
        local dx = ship.x - star.x
        local dy = ship.y - star.y
        local dist = math.sqrt(dx * dx + dy * dy)
        if dist < star.r + SHIP_RADIUS * 0.5 then
            ship.alive = false
            gameState = "fail"
            fadeAlpha = 0
            fadeDir = 0
            print("[GAME] Ship crashed into star!")
            return
        end
    end

    -- 检测到达目标
    local gx, gy = curLevel.goal.x, curLevel.goal.y
    local dx = ship.x - gx
    local dy = ship.y - gy
    local dist = math.sqrt(dx * dx + dy * dy)
    if dist < curLevel.goalR + SHIP_RADIUS then
        gameState = "complete"
        fadeAlpha = 0
        fadeDir = 0
        print("[GAME] Level complete! Time: " .. string.format("%.1f", levelTime) .. "s")
        return
    end

    -- 检测飞出边界
    local margin = 80
    if ship.x < -margin or ship.x > W + margin or ship.y < -margin or ship.y > H + margin then
        ship.alive = false
        gameState = "fail"
        fadeAlpha = 0
        fadeDir = 0
        print("[GAME] Ship flew out of bounds!")
        return
    end
end

local function TogglePolarity()
    if gameState ~= "playing" or not ship.alive then return end
    ship.polarity = (ship.polarity == "N") and "S" or "N"
    ship.toggleFlash = 1.0
    print("[GAME] Polarity → " .. ship.polarity)
end

-- ============================================================================
-- 8. 绘制函数
-- ============================================================================

--- 绘制发光圆 (bloom 效果)
local function DrawGlow(cx, cy, radius, r, g, b, alpha)
    local outerR = radius * 2.5
    nvgBeginPath(vg)
    nvgCircle(vg, cx, cy, outerR)
    local grad = nvgRadialGradient(vg, cx, cy, radius * 0.3, outerR,
        nvgRGBAf(r, g, b, alpha * 0.4),
        nvgRGBAf(r, g, b, 0))
    nvgFillPaint(vg, grad)
    nvgFill(vg)
end

--- 绘制太空背景
local function DrawBackground()
    -- 深空渐变
    local bg = nvgLinearGradient(vg, 0, 0, 0, H,
        nvgRGBA(8, 10, 25, 255),
        nvgRGBA(15, 12, 35, 255))
    nvgBeginPath(vg)
    nvgRect(vg, 0, 0, W, H)
    nvgFillPaint(vg, bg)
    nvgFill(vg)

    -- 星星
    for _, s in ipairs(bgStars) do
        local twinkle = 0.5 + 0.5 * math.sin(gameTime * s.twinkleSpeed + s.twinklePhase)
        local alpha = s.brightness * twinkle
        nvgBeginPath(vg)
        nvgCircle(vg, s.x, s.y, s.size)
        nvgFillColor(vg, nvgRGBAf(1, 1, 0.9, alpha))
        nvgFill(vg)
    end
end

--- 绘制磁感线（预计算的静态曲线）
local function DrawFieldLines()
    if #fieldLines == 0 then return end

    -- 流动动画偏移
    local flowOffset = gameTime * 2.0

    for _, line in ipairs(fieldLines) do
        local n = #line
        if n < 3 then goto continueLine end

        -- 绘制磁感线曲线
        nvgBeginPath(vg)
        nvgMoveTo(vg, line[1].x, line[1].y)
        for i = 2, n do
            nvgLineTo(vg, line[i].x, line[i].y)
        end
        nvgStrokeColor(vg, nvgRGBAf(0.9, 0.75, 0.3, 0.12))
        nvgStrokeWidth(vg, 1.2)
        nvgStroke(vg)

        -- 沿线条绘制流动箭头点（每隔一段距离画一个小三角）
        local arrowSpacing = 40
        local totalLen = 0
        -- 先算总长
        for i = 2, n do
            local dx = line[i].x - line[i - 1].x
            local dy = line[i].y - line[i - 1].y
            totalLen = totalLen + math.sqrt(dx * dx + dy * dy)
        end

        if totalLen > arrowSpacing then
            local accum = 0
            for i = 2, n do
                local dx = line[i].x - line[i - 1].x
                local dy = line[i].y - line[i - 1].y
                local segLen = math.sqrt(dx * dx + dy * dy)
                if segLen < 0.1 then goto continueArrow end

                local prevAccum = accum
                accum = accum + segLen

                -- 检查这段线上是否有箭头位置
                local startDist = math.ceil((prevAccum - (flowOffset % arrowSpacing)) / arrowSpacing) * arrowSpacing + (flowOffset % arrowSpacing)
                local d = startDist
                while d <= accum do
                    if d >= prevAccum and d <= accum then
                        local t = (d - prevAccum) / segLen
                        local ax = line[i - 1].x + dx * t
                        local ay = line[i - 1].y + dy * t

                        -- 箭头方向
                        local angle = math.atan(dy, dx)
                        local arrowSize = 4
                        -- 根据沿线位置渐变透明度
                        local lineFrac = d / totalLen
                        local arrowAlpha = 0.35 * math.sin(lineFrac * math.pi)

                        nvgSave(vg)
                        nvgTranslate(vg, ax, ay)
                        nvgRotate(vg, angle)
                        nvgBeginPath(vg)
                        nvgMoveTo(vg, arrowSize, 0)
                        nvgLineTo(vg, -arrowSize * 0.6, -arrowSize * 0.5)
                        nvgLineTo(vg, -arrowSize * 0.6, arrowSize * 0.5)
                        nvgClosePath(vg)
                        nvgFillColor(vg, nvgRGBAf(1.0, 0.85, 0.4, arrowAlpha))
                        nvgFill(vg)
                        nvgRestore(vg)
                    end
                    d = d + arrowSpacing
                end

                ::continueArrow::
            end
        end

        ::continueLine::
    end
end

--- 绘制磁力线粒子
local function DrawParticles()
    for _, p in ipairs(particles) do
        local lifeRatio = p.life / p.maxLife
        local alpha = lifeRatio * 0.8

        if p.kind == "S" then
            -- S 极粒子：蓝色向内汇聚
            nvgBeginPath(vg)
            nvgCircle(vg, p.x, p.y, 3.5)
            nvgFillColor(vg, nvgRGBAf(CS[1] / 255, CS[2] / 255, CS[3] / 255, alpha * 0.3))
            nvgFill(vg)

            nvgBeginPath(vg)
            nvgCircle(vg, p.x, p.y, 1.3)
            nvgFillColor(vg, nvgRGBAf(0.6, 0.75, 1.0, alpha))
            nvgFill(vg)

        elseif p.kind == "ship" then
            -- 飞船尾迹：跟随极性颜色，小而淡
            local col = (p.shipPol == "N") and CN or CS
            local r, g, b = col[1] / 255, col[2] / 255, col[3] / 255
            local size = lifeRatio * 3.0
            nvgBeginPath(vg)
            nvgCircle(vg, p.x, p.y, size)
            nvgFillColor(vg, nvgRGBAf(r, g, b, alpha * 0.5))
            nvgFill(vg)

        else
            -- N 极粒子：金色向外发散（原有效果）
            nvgBeginPath(vg)
            nvgCircle(vg, p.x, p.y, 4)
            nvgFillColor(vg, nvgRGBAf(CF[1] / 255, CF[2] / 255, CF[3] / 255, alpha * 0.3))
            nvgFill(vg)

            nvgBeginPath(vg)
            nvgCircle(vg, p.x, p.y, 1.5)
            nvgFillColor(vg, nvgRGBAf(1.0, 0.95, 0.6, alpha))
            nvgFill(vg)
        end
    end
end

--- 绘制磁星体
local function DrawStars()
    if not curLevel then return end

    for _, star in ipairs(curLevel.stars) do
        local col = (star.pol == "N") and CN or CS
        local r, g, b = col[1] / 255, col[2] / 255, col[3] / 255

        -- 多层辉光
        DrawGlow(star.x, star.y, star.r * 1.8, r, g, b, 0.15)
        DrawGlow(star.x, star.y, star.r * 1.2, r, g, b, 0.3)

        -- 星体核心渐变
        nvgBeginPath(vg)
        nvgCircle(vg, star.x, star.y, star.r)
        local coreGrad = nvgRadialGradient(vg, star.x, star.y, star.r * 0.2, star.r,
            nvgRGBAf(1, 1, 1, 0.9),
            nvgRGBAf(r, g, b, 0.95))
        nvgFillPaint(vg, coreGrad)
        nvgFill(vg)

        -- 星体边缘光晕
        nvgBeginPath(vg)
        nvgCircle(vg, star.x, star.y, star.r + 3)
        nvgStrokeColor(vg, nvgRGBAf(r, g, b, 0.6))
        nvgStrokeWidth(vg, 2)
        nvgStroke(vg)

        -- 极性标签
        nvgFontFaceId(vg, fontNormal)
        nvgFontSize(vg, 22)
        nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
        nvgFillColor(vg, nvgRGBA(255, 255, 255, 220))
        nvgText(vg, star.x, star.y, star.pol, nil)
    end
end

--- 绘制目标点
local function DrawGoal()
    if not curLevel then return end
    local gx, gy = curLevel.goal.x, curLevel.goal.y
    local gr = curLevel.goalR

    -- 脉冲动画
    local pulse = 0.8 + 0.2 * math.sin(gameTime * 3.0)
    local r, g, b = CG[1] / 255, CG[2] / 255, CG[3] / 255

    -- 外圈辉光
    DrawGlow(gx, gy, gr * 2.0 * pulse, r, g, b, 0.2)

    -- 目标环
    nvgBeginPath(vg)
    nvgCircle(vg, gx, gy, gr * pulse)
    nvgStrokeColor(vg, nvgRGBAf(r, g, b, 0.8))
    nvgStrokeWidth(vg, 3)
    nvgStroke(vg)

    -- 内环
    nvgBeginPath(vg)
    nvgCircle(vg, gx, gy, gr * 0.5 * pulse)
    nvgStrokeColor(vg, nvgRGBAf(r, g, b, 0.5))
    nvgStrokeWidth(vg, 2)
    nvgStroke(vg)

    -- 中心点
    nvgBeginPath(vg)
    nvgCircle(vg, gx, gy, 3)
    nvgFillColor(vg, nvgRGBAf(r, g, b, 0.9))
    nvgFill(vg)

    -- 标签
    nvgFontSize(vg, 12)
    nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_TOP)
    nvgFillColor(vg, nvgRGBAf(r, g, b, 0.7))
    nvgText(vg, gx, gy + gr + 6, "目标", nil)
end

--- 绘制飞船
local function DrawShip()
    if not ship.alive then return end

    local col = (ship.polarity == "N") and CN or CS
    local r, g, b = col[1] / 255, col[2] / 255, col[3] / 255

    -- 轨迹
    for i = 1, #ship.trail do
        local t = ship.trail[i]
        local alpha = i / #ship.trail * 0.5
        local size = (i / #ship.trail) * SHIP_RADIUS * 0.4
        nvgBeginPath(vg)
        nvgCircle(vg, t.x, t.y, size)
        nvgFillColor(vg, nvgRGBAf(r, g, b, alpha * 0.6))
        nvgFill(vg)
    end

    -- 切换闪光效果
    if ship.toggleFlash > 0 then
        local flashR = SHIP_RADIUS * (3.0 - ship.toggleFlash * 2.0)
        nvgBeginPath(vg)
        nvgCircle(vg, ship.x, ship.y, flashR)
        local flashGrad = nvgRadialGradient(vg, ship.x, ship.y, 0, flashR,
            nvgRGBAf(1, 1, 1, ship.toggleFlash * 0.6),
            nvgRGBAf(r, g, b, 0))
        nvgFillPaint(vg, flashGrad)
        nvgFill(vg)
    end

    -- 飞船辉光
    DrawGlow(ship.x, ship.y, SHIP_RADIUS * 1.5, r, g, b, 0.35)

    -- 飞船主体 (朝速度方向的三角形)
    local angle = math.atan(ship.vy, ship.vx)
    local speed = math.sqrt(ship.vx * ship.vx + ship.vy * ship.vy)
    if speed < 5 then angle = 0 end

    nvgSave(vg)
    nvgTranslate(vg, ship.x, ship.y)
    nvgRotate(vg, angle)

    -- 飞船外壳
    nvgBeginPath(vg)
    nvgMoveTo(vg, SHIP_RADIUS, 0)
    nvgLineTo(vg, -SHIP_RADIUS * 0.7, -SHIP_RADIUS * 0.6)
    nvgLineTo(vg, -SHIP_RADIUS * 0.3, 0)
    nvgLineTo(vg, -SHIP_RADIUS * 0.7, SHIP_RADIUS * 0.6)
    nvgClosePath(vg)
    nvgFillColor(vg, nvgRGBAf(r * 0.9, g * 0.9, b * 0.9, 0.95))
    nvgFill(vg)
    nvgStrokeColor(vg, nvgRGBAf(1, 1, 1, 0.5))
    nvgStrokeWidth(vg, 1.5)
    nvgStroke(vg)

    -- 飞船核心高光
    nvgBeginPath(vg)
    nvgCircle(vg, 0, 0, SHIP_RADIUS * 0.25)
    nvgFillColor(vg, nvgRGBA(255, 255, 255, 200))
    nvgFill(vg)

    nvgRestore(vg)

    -- 极性标签 (在飞船旁边)
    nvgFontSize(vg, 14)
    nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_BOTTOM)
    nvgFillColor(vg, nvgRGBAf(r, g, b, 0.9))
    nvgText(vg, ship.x, ship.y - SHIP_RADIUS - 6, ship.polarity, nil)
end

--- 绘制 HUD
local function DrawHUD()
    if gameState ~= "playing" then return end
    if not curLevel then return end

    -- 左上角: 关卡名称
    nvgFontSize(vg, 18)
    nvgTextAlign(vg, NVG_ALIGN_LEFT + NVG_ALIGN_TOP)
    nvgFillColor(vg, nvgRGBA(255, 255, 255, 180))
    nvgText(vg, 16, 16, curLevel.name, nil)

    nvgFontSize(vg, 12)
    nvgFillColor(vg, nvgRGBA(200, 200, 200, 140))
    nvgText(vg, 16, 38, curLevel.subtitle, nil)

    -- 右上角: 返回按钮
    local backBtnW, backBtnH = 80, 32
    local backBtnX = W - backBtnW - 12
    local backBtnY = 12

    nvgBeginPath(vg)
    nvgRoundedRect(vg, backBtnX, backBtnY, backBtnW, backBtnH, 16)
    nvgFillColor(vg, nvgRGBA(255, 255, 255, 30))
    nvgFill(vg)
    nvgStrokeColor(vg, nvgRGBA(255, 255, 255, 80))
    nvgStrokeWidth(vg, 1)
    nvgStroke(vg)

    nvgFontSize(vg, 14)
    nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
    nvgFillColor(vg, nvgRGBA(255, 255, 255, 180))
    nvgText(vg, backBtnX + backBtnW / 2, backBtnY + backBtnH / 2, "< 选关", nil)

    -- 时间显示 (返回按钮下方)
    nvgFontSize(vg, 16)
    nvgTextAlign(vg, NVG_ALIGN_RIGHT + NVG_ALIGN_TOP)
    nvgFillColor(vg, nvgRGBA(255, 255, 255, 160))
    nvgText(vg, W - 16, backBtnY + backBtnH + 8, string.format("%.1fs", levelTime), nil)

    -- 底部: 极性切换提示
    local col = (ship.polarity == "N") and CN or CS
    local polText = (ship.polarity == "N") and "当前: 北极(N)" or "当前: 南极(S)"

    -- 底部指示器背景
    local barW = 200
    local barH = 36
    local barX = (W - barW) / 2
    local barY = H - barH - 12

    nvgBeginPath(vg)
    nvgRoundedRect(vg, barX, barY, barW, barH, 18)
    nvgFillColor(vg, nvgRGBA(0, 0, 0, 140))
    nvgFill(vg)
    nvgStrokeColor(vg, nvgRGBA(col[1], col[2], col[3], 180))
    nvgStrokeWidth(vg, 2)
    nvgStroke(vg)

    -- 极性指示灯
    nvgBeginPath(vg)
    nvgCircle(vg, barX + 22, barY + barH / 2, 8)
    nvgFillColor(vg, nvgRGBA(col[1], col[2], col[3], 255))
    nvgFill(vg)

    -- 极性文字
    nvgFontSize(vg, 14)
    nvgTextAlign(vg, NVG_ALIGN_LEFT + NVG_ALIGN_MIDDLE)
    nvgFillColor(vg, nvgRGBA(255, 255, 255, 220))
    nvgText(vg, barX + 38, barY + barH / 2, polText, nil)

    -- 教学引导文字 (前8秒显示)
    if levelTime < 10.0 and curLevel.tutorial then
        local tutAlpha = 1.0
        if levelTime > 8.0 then
            tutAlpha = 1.0 - (levelTime - 8.0) / 2.0
        end
        if tutAlpha > 0 then
            local ty = H * 0.15
            nvgFontSize(vg, 16)
            nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_TOP)
            for i, line in ipairs(curLevel.tutorial) do
                nvgFillColor(vg, nvgRGBAf(1, 0.9, 0.5, tutAlpha * 0.85))
                nvgText(vg, W / 2, ty + (i - 1) * 24, line, nil)
            end
        end
    end
end

--- 绘制主菜单
local function DrawMenu()
    -- 标题发光
    local titleY = H * 0.25
    local pulse = 0.8 + 0.2 * math.sin(gameTime * 2.0)

    -- 标题辉光
    nvgFontSize(vg, 42)
    nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
    nvgFillColor(vg, nvgRGBAf(0.4, 0.6, 1.0, 0.15 * pulse))
    nvgText(vg, W / 2 + 2, titleY + 2, "磁力冲浪者", nil)

    nvgFillColor(vg, nvgRGBA(255, 255, 255, 240))
    nvgText(vg, W / 2, titleY, "磁力冲浪者", nil)

    -- 副标题
    nvgFontSize(vg, 20)
    nvgFillColor(vg, nvgRGBAf(0.6, 0.75, 1.0, 0.7))
    nvgText(vg, W / 2, titleY + 40, "隐形星路", nil)

    -- 装饰: N/S 极示意
    local demoY = H * 0.5
    local demoSpacing = 100

    -- N 极示意
    DrawGlow(W / 2 - demoSpacing, demoY, 25, CN[1] / 255, CN[2] / 255, CN[3] / 255, 0.3 * pulse)
    nvgBeginPath(vg)
    nvgCircle(vg, W / 2 - demoSpacing, demoY, 20)
    nvgFillColor(vg, nvgRGBA(CN[1], CN[2], CN[3], 200))
    nvgFill(vg)
    nvgFontSize(vg, 16)
    nvgFillColor(vg, nvgRGBA(255, 255, 255, 220))
    nvgText(vg, W / 2 - demoSpacing, demoY, "N", nil)
    nvgFontSize(vg, 12)
    nvgFillColor(vg, nvgRGBA(CN[1], CN[2], CN[3], 180))
    nvgText(vg, W / 2 - demoSpacing, demoY + 30, "北极", nil)

    -- 磁力线箭头 (N → S)
    for i = 1, 5 do
        local t = ((gameTime * 0.5 + i * 0.2) % 1.0)
        local ax = W / 2 - demoSpacing + t * demoSpacing * 2
        local alpha = math.sin(t * math.pi) * 0.6
        nvgBeginPath(vg)
        nvgCircle(vg, ax, demoY, 2)
        nvgFillColor(vg, nvgRGBAf(CF[1] / 255, CF[2] / 255, CF[3] / 255, alpha))
        nvgFill(vg)
    end

    -- S 极示意
    DrawGlow(W / 2 + demoSpacing, demoY, 25, CS[1] / 255, CS[2] / 255, CS[3] / 255, 0.3 * pulse)
    nvgBeginPath(vg)
    nvgCircle(vg, W / 2 + demoSpacing, demoY, 20)
    nvgFillColor(vg, nvgRGBA(CS[1], CS[2], CS[3], 200))
    nvgFill(vg)
    nvgFontSize(vg, 16)
    nvgFillColor(vg, nvgRGBA(255, 255, 255, 220))
    nvgText(vg, W / 2 + demoSpacing, demoY, "S", nil)
    nvgFontSize(vg, 12)
    nvgFillColor(vg, nvgRGBA(CS[1], CS[2], CS[3], 180))
    nvgText(vg, W / 2 + demoSpacing, demoY + 30, "南极", nil)

    -- 说明文字
    nvgFontSize(vg, 14)
    nvgFillColor(vg, nvgRGBA(200, 200, 220, 160))
    nvgText(vg, W / 2, demoY + 60, "磁力线从 N 极流向 S 极", nil)

    -- 开始按钮
    local btnY = H * 0.75
    local btnW, btnH = 180, 48
    local btnX = (W - btnW) / 2

    nvgBeginPath(vg)
    nvgRoundedRect(vg, btnX, btnY, btnW, btnH, 24)
    nvgFillColor(vg, nvgRGBA(60, 100, 200, 220))
    nvgFill(vg)
    nvgStrokeColor(vg, nvgRGBA(120, 160, 255, 180))
    nvgStrokeWidth(vg, 2)
    nvgStroke(vg)

    nvgFontSize(vg, 20)
    nvgFillColor(vg, nvgRGBA(255, 255, 255, 240))
    nvgText(vg, W / 2, btnY + btnH / 2, "开始冲浪", nil)

    nvgFontSize(vg, 12)
    nvgFillColor(vg, nvgRGBA(180, 190, 220, 140))
    nvgText(vg, W / 2, H - 30, "点击或按空格键开始", nil)
end

--- 绘制关卡选择
local function DrawLevelSelect()
    nvgFontSize(vg, 28)
    nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
    nvgFillColor(vg, nvgRGBA(255, 255, 255, 220))
    nvgText(vg, W / 2, H * 0.1, "选择关卡", nil)

    local cardW = math.min(220, (W - 80) / 3)
    local cardH = 160
    local totalW = cardW * 3 + 20 * 2
    local startX = (W - totalW) / 2
    local cardY = H * 0.3

    for i = 1, #levels do
        local lv = levels[i]
        local cx = startX + (i - 1) * (cardW + 20)
        local isHover = false  -- 简化，不做鼠标悬停

        -- 卡片背景
        nvgBeginPath(vg)
        nvgRoundedRect(vg, cx, cardY, cardW, cardH, 12)
        nvgFillColor(vg, nvgRGBA(25, 30, 50, 220))
        nvgFill(vg)
        nvgStrokeColor(vg, nvgRGBA(80, 100, 160, 150))
        nvgStrokeWidth(vg, 2)
        nvgStroke(vg)

        -- 关卡编号
        nvgFontSize(vg, 36)
        nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
        nvgFillColor(vg, nvgRGBAf(0.4, 0.6, 1.0, 0.3))
        nvgText(vg, cx + cardW / 2, cardY + 40, tostring(i), nil)

        -- 关卡名称
        nvgFontSize(vg, 16)
        nvgFillColor(vg, nvgRGBA(255, 255, 255, 220))
        nvgText(vg, cx + cardW / 2, cardY + 75, lv.name, nil)

        -- 副标题
        nvgFontSize(vg, 11)
        nvgFillColor(vg, nvgRGBA(180, 190, 220, 160))
        nvgText(vg, cx + cardW / 2, cardY + 98, lv.subtitle, nil)

        -- 磁极预览小图标
        local previewY = cardY + 125
        for j, star in ipairs(lv.stars) do
            local sc = (star.pol == "N") and CN or CS
            local px = cx + cardW / 2 + (j - (#lv.stars + 1) / 2) * 25
            nvgBeginPath(vg)
            nvgCircle(vg, px, previewY, 8)
            nvgFillColor(vg, nvgRGBA(sc[1], sc[2], sc[3], 200))
            nvgFill(vg)
            nvgFontSize(vg, 8)
            nvgFillColor(vg, nvgRGBA(255, 255, 255, 200))
            nvgText(vg, px, previewY, star.pol, nil)
        end
    end

    -- 底部提示
    nvgFontSize(vg, 14)
    nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
    nvgFillColor(vg, nvgRGBA(180, 190, 220, 140))
    nvgText(vg, W / 2, H * 0.85, "点击关卡卡片开始  |  按 ESC 返回", nil)
end

--- 绘制关卡完成界面
local function DrawComplete()
    -- 半透明遮罩
    nvgBeginPath(vg)
    nvgRect(vg, 0, 0, W, H)
    nvgFillColor(vg, nvgRGBA(0, 0, 0, 140))
    nvgFill(vg)

    local panelW = math.min(320, W - 40)
    local panelH = 220
    local px = (W - panelW) / 2
    local py = (H - panelH) / 2

    -- 面板
    nvgBeginPath(vg)
    nvgRoundedRect(vg, px, py, panelW, panelH, 16)
    nvgFillColor(vg, nvgRGBA(20, 30, 50, 240))
    nvgFill(vg)
    nvgStrokeColor(vg, nvgRGBA(CG[1], CG[2], CG[3], 180))
    nvgStrokeWidth(vg, 2)
    nvgStroke(vg)

    nvgFontSize(vg, 32)
    nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
    nvgFillColor(vg, nvgRGBA(CG[1], CG[2], CG[3], 255))
    nvgText(vg, W / 2, py + 50, "关卡完成！", nil)

    nvgFontSize(vg, 18)
    nvgFillColor(vg, nvgRGBA(255, 255, 255, 200))
    nvgText(vg, W / 2, py + 95, string.format("用时: %.1f 秒", levelTime), nil)

    -- 下一关 / 返回按钮
    local hasNext = levelIndex < #levels
    local btnText = hasNext and "下一关" or "返回选关"
    local btnW, btnH = 140, 40
    local btnX = (W - btnW) / 2
    local btnY = py + panelH - 65

    nvgBeginPath(vg)
    nvgRoundedRect(vg, btnX, btnY, btnW, btnH, 20)
    nvgFillColor(vg, nvgRGBA(60, 100, 200, 220))
    nvgFill(vg)
    nvgFontSize(vg, 16)
    nvgFillColor(vg, nvgRGBA(255, 255, 255, 240))
    nvgText(vg, W / 2, btnY + btnH / 2, btnText, nil)
end

--- 绘制失败界面
local function DrawFail()
    -- 半透明遮罩
    nvgBeginPath(vg)
    nvgRect(vg, 0, 0, W, H)
    nvgFillColor(vg, nvgRGBA(0, 0, 0, 140))
    nvgFill(vg)

    local panelW = math.min(320, W - 40)
    local panelH = 200
    local px = (W - panelW) / 2
    local py = (H - panelH) / 2

    -- 面板
    nvgBeginPath(vg)
    nvgRoundedRect(vg, px, py, panelW, panelH, 16)
    nvgFillColor(vg, nvgRGBA(20, 30, 50, 240))
    nvgFill(vg)
    nvgStrokeColor(vg, nvgRGBA(CN[1], CN[2], CN[3], 180))
    nvgStrokeWidth(vg, 2)
    nvgStroke(vg)

    nvgFontSize(vg, 28)
    nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
    nvgFillColor(vg, nvgRGBA(CN[1], CN[2], CN[3], 255))
    nvgText(vg, W / 2, py + 50, "飞船坠毁！", nil)

    nvgFontSize(vg, 14)
    nvgFillColor(vg, nvgRGBA(200, 200, 220, 180))
    nvgText(vg, W / 2, py + 85, "试着在合适时机切换磁极", nil)

    -- 重试按钮
    local btnW, btnH = 120, 40
    local btnX = (W - btnW) / 2
    local btnY = py + panelH - 65

    nvgBeginPath(vg)
    nvgRoundedRect(vg, btnX, btnY, btnW, btnH, 20)
    nvgFillColor(vg, nvgRGBA(200, 80, 80, 220))
    nvgFill(vg)
    nvgFontSize(vg, 16)
    nvgFillColor(vg, nvgRGBA(255, 255, 255, 240))
    nvgText(vg, W / 2, btnY + btnH / 2, "重新挑战", nil)
end

--- 绘制过渡效果
local function DrawFade()
    if fadeAlpha > 0.01 then
        nvgBeginPath(vg)
        nvgRect(vg, 0, 0, W, H)
        nvgFillColor(vg, nvgRGBAf(0, 0, 0, fadeAlpha))
        nvgFill(vg)
    end
end

-- ============================================================================
-- 9. 事件处理
-- ============================================================================

---@param eventType string
---@param eventData UpdateEventData
function HandleUpdate(eventType, eventData)
    local dt = eventData["TimeStep"]:GetFloat()
    gameTime = gameTime + dt

    -- 过渡动画
    if fadeDir ~= 0 then
        fadeAlpha = fadeAlpha + fadeDir * dt * 2.5
        if fadeAlpha <= 0 then
            fadeAlpha = 0
            fadeDir = 0
        elseif fadeAlpha >= 1 then
            fadeAlpha = 1
            fadeDir = 0
            if fadeCallback then
                fadeCallback()
                fadeCallback = nil
            end
        end
    end

    if gameState == "playing" then
        levelTime = levelTime + dt
        UpdateShip(dt)
        UpdateParticles(dt)
        CheckCollisions()
    elseif gameState == "menu" or gameState == "levelSelect" then
        -- 菜单状态下也更新粒子用于装饰
    end
end

function HandleRender(eventType, eventData)
    if vg == nil then return end

    -- 更新屏幕尺寸 (Mode B: 逻辑分辨率)
    local physW = gfx:GetWidth()
    local physH = gfx:GetHeight()
    dpr = gfx:GetDPR()
    W = physW / dpr
    H = physH / dpr

    nvgBeginFrame(vg, W, H, dpr)

    -- 绘制背景
    DrawBackground()

    if gameState == "playing" or gameState == "complete" or gameState == "fail" then
        DrawFieldLines()
        DrawParticles()
        DrawStars()
        DrawGoal()
        DrawShip()
        DrawHUD()

        if gameState == "complete" then
            DrawComplete()
        elseif gameState == "fail" then
            DrawFail()
        end
    elseif gameState == "menu" then
        DrawMenu()
    elseif gameState == "levelSelect" then
        DrawLevelSelect()
    end

    DrawFade()

    nvgEndFrame(vg)
end

--- 点击事件处理 (含关卡选择碰撞检测)
---@param eventType string
---@param eventData MouseButtonDownEventData
function HandleMouseClick(eventType, eventData)
    local button = eventData["Button"]:GetInt()
    if button ~= MOUSEB_LEFT then return end

    -- 获取逻辑坐标
    local mx = input.mousePosition.x / dpr
    local my = input.mousePosition.y / dpr

    if gameState == "menu" then
        -- 检查开始按钮点击
        local btnY = H * 0.75
        local btnW, btnH = 180, 48
        local btnX = (W - btnW) / 2
        if mx >= btnX and mx <= btnX + btnW and my >= btnY and my <= btnY + btnH then
            fadeDir = 1
            fadeAlpha = 0
            fadeCallback = function()
                InitLevels()
                gameState = "levelSelect"
                fadeDir = -1
            end
        end
    elseif gameState == "levelSelect" then
        -- 检查关卡卡片点击
        local cardW = math.min(220, (W - 80) / 3)
        local cardH = 160
        local totalW = cardW * 3 + 20 * 2
        local startX = (W - totalW) / 2
        local cardY = H * 0.3

        for i = 1, #levels do
            local cx = startX + (i - 1) * (cardW + 20)
            if mx >= cx and mx <= cx + cardW and my >= cardY and my <= cardY + cardH then
                fadeDir = 1
                fadeAlpha = 0
                local chosenLevel = i
                fadeCallback = function()
                    StartLevel(chosenLevel)
                    fadeDir = -1
                end
                break
            end
        end
    elseif gameState == "playing" then
        -- 检查返回按钮
        local backBtnW, backBtnH = 80, 32
        local backBtnX = W - backBtnW - 12
        local backBtnY = 12
        if mx >= backBtnX and mx <= backBtnX + backBtnW and my >= backBtnY and my <= backBtnY + backBtnH then
            fadeDir = 1
            fadeAlpha = 0
            fadeCallback = function()
                InitLevels()
                gameState = "levelSelect"
                fadeDir = -1
            end
            return
        end
        TogglePolarity()
    elseif gameState == "complete" then
        -- 点击按钮: 下一关或返回选关
        local panelW = math.min(320, W - 40)
        local panelH = 220
        local py = (H - panelH) / 2
        local btnW, btnH = 140, 40
        local btnX = (W - btnW) / 2
        local btnY = py + panelH - 65

        if mx >= btnX and mx <= btnX + btnW and my >= btnY and my <= btnY + btnH then
            local hasNext = levelIndex < #levels
            if hasNext then
                fadeDir = 1
                fadeAlpha = 0
                fadeCallback = function()
                    StartLevel(levelIndex + 1)
                    fadeDir = -1
                end
            else
                fadeDir = 1
                fadeAlpha = 0
                fadeCallback = function()
                    InitLevels()
                    gameState = "levelSelect"
                    fadeDir = -1
                end
            end
        end
    elseif gameState == "fail" then
        -- 点击重试按钮
        local panelW = math.min(320, W - 40)
        local panelH = 200
        local py = (H - panelH) / 2
        local btnW, btnH = 120, 40
        local btnX = (W - btnW) / 2
        local btnY = py + panelH - 65

        if mx >= btnX and mx <= btnX + btnW and my >= btnY and my <= btnY + btnH then
            fadeDir = 1
            fadeAlpha = 0
            fadeCallback = function()
                StartLevel(levelIndex)
                fadeDir = -1
            end
        end
    end
end

---@param eventType string
---@param eventData KeyDownEventData
function HandleKeyDown(eventType, eventData)
    local key = eventData["Key"]:GetInt()

    if key == KEY_SPACE then
        if gameState == "menu" then
            fadeDir = 1
            fadeAlpha = 0
            fadeCallback = function()
                InitLevels()
                gameState = "levelSelect"
                fadeDir = -1
            end
        elseif gameState == "playing" then
            TogglePolarity()
        elseif gameState == "complete" then
            local hasNext = levelIndex < #levels
            if hasNext then
                fadeDir = 1
                fadeAlpha = 0
                fadeCallback = function()
                    StartLevel(levelIndex + 1)
                    fadeDir = -1
                end
            else
                fadeDir = 1
                fadeAlpha = 0
                fadeCallback = function()
                    InitLevels()
                    gameState = "levelSelect"
                    fadeDir = -1
                end
            end
        elseif gameState == "fail" then
            fadeDir = 1
            fadeAlpha = 0
            fadeCallback = function()
                StartLevel(levelIndex)
                fadeDir = -1
            end
        end
    elseif key == KEY_ESCAPE then
        if gameState == "levelSelect" then
            fadeDir = 1
            fadeAlpha = 0
            fadeCallback = function()
                gameState = "menu"
                fadeDir = -1
            end
        elseif gameState == "playing" or gameState == "complete" or gameState == "fail" then
            fadeDir = 1
            fadeAlpha = 0
            fadeCallback = function()
                InitLevels()
                gameState = "levelSelect"
                fadeDir = -1
            end
        end
    elseif key == KEY_1 or key == KEY_2 or key == KEY_3 then
        if gameState == "levelSelect" then
            local idx = key - KEY_1 + 1
            if idx >= 1 and idx <= #levels then
                fadeDir = 1
                fadeAlpha = 0
                fadeCallback = function()
                    StartLevel(idx)
                    fadeDir = -1
                end
            end
        end
    end
end

-- 触摸事件支持
---@param eventType string
---@param eventData TouchBeginEventData
function HandleTouchBegin(eventType, eventData)
    -- 触摸模拟为点击
    if gameState == "playing" then
        TogglePolarity()
    end
end

-- ============================================================================
-- 10. 生命周期
-- ============================================================================

function Start()
    SampleStart()
    graphics.windowTitle = "磁力冲浪者：隐形星路"

    gfx = GetGraphics()

    -- 初始化 NanoVG
    vg = nvgCreate(1)
    if not vg then
        print("[ERROR] Failed to create NanoVG context!")
        return
    end

    fontNormal = nvgCreateFont(vg, "sans", "Fonts/MiSans-Regular.ttf")
    if fontNormal == -1 then
        print("[ERROR] Failed to load font!")
        return
    end

    -- 初始化屏幕尺寸
    local physW = gfx:GetWidth()
    local physH = gfx:GetHeight()
    dpr = gfx:GetDPR()
    W = physW / dpr
    H = physH / dpr

    -- 初始化关卡和背景
    InitLevels()
    InitBgStars()

    -- 鼠标模式: 自由 (需要点击交互)
    SampleInitMouseMode(MM_FREE)

    -- 订阅事件
    SubscribeToEvent(vg, "NanoVGRender", "HandleRender")
    SubscribeToEvent("Update", "HandleUpdate")
    SubscribeToEvent("MouseButtonDown", "HandleMouseClick")
    SubscribeToEvent("KeyDown", "HandleKeyDown")
    SubscribeToEvent("TouchBegin", "HandleTouchBegin")

    print("=== 磁力冲浪者：隐形星路 启动 ===")
    print("操作: 点击/空格=切换磁极, ESC=返回, 1/2/3=选关")
end

function Stop()
    if vg then
        nvgDelete(vg)
        vg = nil
    end
    print("=== 磁力冲浪者 停止 ===")
end

function GetScreenJoystickPatchString()
    return "<patch><add sel=\"/element/element[./attribute[@name='Name' and @value='Hat0']]\"><attribute name=\"Is Visible\" value=\"false\" /></add></patch>"
end
