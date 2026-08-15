--[[--
Geometry utilities for Pencil plugin.
Pure functions for stroke geometry calculations.

@module pencil.lib.geometry
--]]--

local Geometry = {}

--- Check if a point is near any point in a stroke.
-- Uses squared distance comparison to avoid sqrt for performance.
-- @param px X coordinate of point to check
-- @param py Y coordinate of point to check
-- @param stroke Table with points array
-- @param threshold Distance threshold (default 20)
-- @return boolean True if point is within threshold of any stroke point
function Geometry.isPointNearStroke(px, py, stroke, threshold)
    if not stroke or not stroke.points then
        return false
    end

    threshold = threshold or 20
    local threshold_sq = threshold * threshold

    for _, point in ipairs(stroke.points) do
        local dx = px - point.x
        local dy = py - point.y
        if dx * dx + dy * dy <= threshold_sq then
            return true
        end
    end
    return false
end

--- Squared distance from point (px,py) to segment a→b.
function Geometry.distSqPointToSegment(px, py, ax, ay, bx, by)
    local dx, dy = bx - ax, by - ay
    local l2 = dx * dx + dy * dy
    if l2 == 0 then
        local ex, ey = px - ax, py - ay
        return ex * ex + ey * ey
    end
    local t = ((px - ax) * dx + (py - ay) * dy) / l2
    if t < 0 then t = 0 elseif t > 1 then t = 1 end
    local qx, qy = ax + t * dx, ay + t * dy
    local ex, ey = px - qx, py - qy
    return ex * ex + ey * ey
end

--- True if (px,py) lies inside any erase dab (circle). extra_r inflates the radius.
function Geometry.pointInEraseDabs(px, py, dabs, extra_r)
    extra_r = extra_r or 0
    for i = 1, #dabs do
        local d = dabs[i]
        local r = d.r + extra_r
        local dx, dy = px - d.x, py - d.y
        if dx * dx + dy * dy <= r * r then
            return true
        end
    end
    return false
end

--- True if segment a→b comes within any dab's radius.
function Geometry.segmentHitsEraseDabs(ax, ay, bx, by, dabs, extra_r)
    extra_r = extra_r or 0
    for i = 1, #dabs do
        local d = dabs[i]
        local r = d.r + extra_r
        if Geometry.distSqPointToSegment(d.x, d.y, ax, ay, bx, by) <= r * r then
            return true
        end
    end
    return false
end

--- Punch holes in a polyline: drop points (and breaks) under erase dabs.
-- Returns a list of fragment strokes (same metadata, new point arrays).
function Geometry.splitStrokeByEraseDabs(stroke, dabs, extra_r)
    extra_r = extra_r or 0
    if not stroke or not stroke.points or #stroke.points == 0 then
        return {}
    end
    if not dabs or #dabs == 0 then
        return { stroke }
    end

    local fragments = {}
    local current = {}
    local prev = nil

    local function flush()
        if #current == 0 then return end
        local frag = {
            page = stroke.page,
            tool = stroke.tool,
            width = stroke.width,
            color = stroke.color,
            color_name = stroke.color_name,
            alpha = stroke.alpha,
            datetime = stroke.datetime,
            points = current,
        }
        table.insert(fragments, frag)
        current = {}
    end

    for _, p in ipairs(stroke.points) do
        local in_dab = Geometry.pointInEraseDabs(p.x, p.y, dabs, extra_r)
        local seg_hit = prev and Geometry.segmentHitsEraseDabs(
            prev.x, prev.y, p.x, p.y, dabs, extra_r)
        if in_dab then
            flush()
        else
            if seg_hit then
                flush()
            end
            table.insert(current, { x = p.x, y = p.y })
        end
        prev = p
    end
    flush()
    return fragments
end

-- Rotation mode constants (matches KOReader's framebuffer constants)
Geometry.ROTATION_UPRIGHT = 0
Geometry.ROTATION_CLOCKWISE = 1
Geometry.ROTATION_UPSIDE_DOWN = 2
Geometry.ROTATION_COUNTER_CLOCKWISE = 3

--- Transform coordinates based on screen rotation.
-- Converts from hardware/physical coordinate space to logical/display space.
-- @param x Raw X coordinate from hardware
-- @param y Raw Y coordinate from hardware
-- @param rotation Rotation mode (0=upright, 1=CW, 2=upside-down, 3=CCW)
-- @param screen_width Current logical screen width
-- @param screen_height Current logical screen height
-- @return number, number Transformed X and Y coordinates
function Geometry.transformForRotation(x, y, rotation, screen_width, screen_height)
    if rotation == Geometry.ROTATION_UPRIGHT then
        return x, y
    elseif rotation == Geometry.ROTATION_CLOCKWISE then
        return screen_width - y, x
    elseif rotation == Geometry.ROTATION_UPSIDE_DOWN then
        return screen_width - x, screen_height - y
    elseif rotation == Geometry.ROTATION_COUNTER_CLOCKWISE then
        return y, screen_height - x
    end
    return x, y  -- fallback for unknown rotation
end

--- Compute the bounding box of a stroke from its points array.
-- @param stroke Table with points array (each point has x, y)
-- @return table {x0, y0, x1, y1} or nil if no points
function Geometry.computeStrokeBbox(stroke)
    if not stroke or not stroke.points or #stroke.points == 0 then
        return nil
    end
    local p = stroke.points[1]
    local x0, y0, x1, y1 = p.x, p.y, p.x, p.y
    for i = 2, #stroke.points do
        p = stroke.points[i]
        if p.x < x0 then x0 = p.x end
        if p.y < y0 then y0 = p.y end
        if p.x > x1 then x1 = p.x end
        if p.y > y1 then y1 = p.y end
    end
    return { x0 = x0, y0 = y0, x1 = x1, y1 = y1 }
end

--- Drop collinear-ish samples. Keeps endpoints. min_dist is pixels.
function Geometry.thinPoints(points, min_dist)
    if not points or #points <= 2 then
        return points
    end
    min_dist = min_dist or 3
    local min_sq = min_dist * min_dist
    local out = { points[1] }
    local last = points[1]
    for i = 2, #points - 1 do
        local p = points[i]
        local dx, dy = p.x - last.x, p.y - last.y
        if dx * dx + dy * dy >= min_sq then
            out[#out + 1] = p
            last = p
        end
    end
    out[#out + 1] = points[#points]
    return out
end

--- Bounding box of erase dabs (circles), optional extra radius.
function Geometry.dabsBbox(dabs, extra_r)
    if not dabs or #dabs == 0 then return nil end
    extra_r = extra_r or 0
    local d = dabs[1]
    local r = (d.r or 0) + extra_r
    local x0, y0, x1, y1 = d.x - r, d.y - r, d.x + r, d.y + r
    for i = 2, #dabs do
        d = dabs[i]
        r = (d.r or 0) + extra_r
        local a, b = d.x - r, d.y - r
        local c, e = d.x + r, d.y + r
        if a < x0 then x0 = a end
        if b < y0 then y0 = b end
        if c > x1 then x1 = c end
        if e > y1 then y1 = e end
    end
    return { x0 = x0, y0 = y0, x1 = x1, y1 = y1 }
end

--- True if axis-aligned boxes overlap (inclusive).
function Geometry.bboxesOverlap(a, b)
    if not a or not b then return false end
    return a.x0 <= b.x1 and a.x1 >= b.x0 and a.y0 <= b.y1 and a.y1 >= b.y0
end

--- Compute minimum pixel distance between two bounding boxes.
-- Returns 0 if the boxes overlap.
-- @param a table {x0, y0, x1, y1}
-- @param b table {x0, y0, x1, y1}
-- @return number minimum distance in pixels
function Geometry.bboxDistance(a, b)
    -- Compute gap on each axis (negative means overlap)
    local dx = math.max(a.x0 - b.x1, b.x0 - a.x1, 0)
    local dy = math.max(a.y0 - b.y1, b.y0 - a.y1, 0)
    if dx == 0 and dy == 0 then
        return 0  -- overlapping
    elseif dx == 0 then
        return dy
    elseif dy == 0 then
        return dx
    else
        return math.sqrt(dx * dx + dy * dy)
    end
end

--- Compute the union of two bounding boxes.
-- @param a table {x0, y0, x1, y1}
-- @param b table {x0, y0, x1, y1}
-- @return table {x0, y0, x1, y1}
function Geometry.bboxUnion(a, b)
    return {
        x0 = math.min(a.x0, b.x0),
        y0 = math.min(a.y0, b.y0),
        x1 = math.max(a.x1, b.x1),
        y1 = math.max(a.y1, b.y1),
    }
end

--- Expand a bounding box by margin pixels on each side.
-- @param bbox table {x0, y0, x1, y1}
-- @param margin number pixels to expand on each side
-- @return table {x0, y0, x1, y1}
function Geometry.bboxExpand(bbox, margin)
    return {
        x0 = bbox.x0 - margin,
        y0 = bbox.y0 - margin,
        x1 = bbox.x1 + margin,
        y1 = bbox.y1 + margin,
    }
end

--- Clamp a bounding box to fit within screen bounds.
-- @param bbox table {x0, y0, x1, y1}
-- @param sw number screen width
-- @param sh number screen height
-- @return table {x0, y0, x1, y1}
function Geometry.bboxClampToScreen(bbox, sw, sh)
    return {
        x0 = math.max(0, math.min(bbox.x0, sw)),
        y0 = math.max(0, math.min(bbox.y0, sh)),
        x1 = math.max(0, math.min(bbox.x1, sw)),
        y1 = math.max(0, math.min(bbox.y1, sh)),
    }
end

--- Compute a full-screen-width capture strip rect for an annotation bbox.
-- The strip vertically encloses the bbox plus v_margin on each side, is
-- floored at min_h px tall (extending around the bbox center), and is
-- shifted back onto the screen if a side runs off so the min-height
-- contract is preserved. Finally clamped to the screen.
-- @param bbox table {y0, y1} (x ignored; strip is always full-width)
-- @param sw number screen width
-- @param sh number screen height
-- @param v_margin number padding above/below the bbox before min_h applies
-- @param min_h number minimum strip height (legibility floor)
-- @return table {x0, y0, x1, y1} where x0=0 and x1=sw
function Geometry.captureStripRect(bbox, sw, sh, v_margin, min_h)
    local bbox_h = bbox.y1 - bbox.y0
    local strip_h = math.max(bbox_h + 2 * v_margin, min_h)
    strip_h = math.min(strip_h, sh)
    local cy = (bbox.y0 + bbox.y1) / 2
    local y0 = math.floor(cy - strip_h / 2)
    local y1 = math.floor(cy + strip_h / 2)
    -- Shift back onscreen rather than clamp-and-chop, so a near-edge bbox
    -- still produces a min_h-tall strip (when screen has room for it).
    if y0 < 0 then
        y1 = y1 - y0
        y0 = 0
    end
    if y1 > sh then
        y0 = y0 - (y1 - sh)
        y1 = sh
    end
    y0 = math.max(0, y0)
    y1 = math.min(sh, y1)
    return { x0 = 0, y0 = y0, x1 = sw, y1 = y1 }
end

-- Fountain / calligraphy nib: fixed ~20° edge (Kindle Scribe fountain pen).
-- Width is a function of stroke heading vs nib angle, not pressure.
-- Stock: weight scales nib *length*; hairline stays ~1px.
Geometry.FOUNTAIN_NIB_ANGLE = math.rad(20)
Geometry.FOUNTAIN_HEADING_SMOOTH = 0.35
Geometry.FOUNTAIN_HAIRLINE = 1
Geometry.FOUNTAIN_NIB_SCALE = 2
Geometry.FOUNTAIN_NIB_MIN_LENGTH = 5
-- Mild base contrast (n≈1 is physical). Piecewise map below shapes the zones.
Geometry.FOUNTAIN_THIN_POWER = 1.8
-- Contrast 0..HAIR_END → leave pure 1px quickly (narrow min zone).
-- Contrast HAIR_END..NEAR_END → hang in 2nd-thin (wider near-hairline band).
-- Above NEAR_END → ramp to full chisel.
Geometry.FOUNTAIN_HAIR_END = 0.10
Geometry.FOUNTAIN_NEAR_END = 0.58
Geometry.FOUNTAIN_NEAR_RATIO = 0.38

--- Hairline and full-nib widths from the ballpoint weight.
-- @param weight number selected pen width
-- @return number, number w_min (hairline), w_max (nib length)
function Geometry.fountainWidthRange(weight)
    weight = math.max(1, weight or 3)
    local nib = math.max(Geometry.FOUNTAIN_NIB_MIN_LENGTH, weight * Geometry.FOUNTAIN_NIB_SCALE - 1)
    return Geometry.FOUNTAIN_HAIRLINE, nib
end

--- 0 = along the nib (hairline), 1 = across it (full width).
function Geometry.nibContrast(heading, nib_angle, power)
    if not heading then return 0 end
    power = power or Geometry.FOUNTAIN_THIN_POWER
    local s = math.abs(math.sin(heading - nib_angle))
    if power ~= 1 then
        s = s ^ power
    end
    return s
end

--- Stamp length for this heading: narrow 1px cone, wide 2nd-thin band, then full.
function Geometry.nibLengthForHeading(heading, nib_angle, w_min, w_max, power)
    local t = Geometry.nibContrast(heading, nib_angle, power)
    local near = w_min + (w_max - w_min) * Geometry.FOUNTAIN_NEAR_RATIO
    near = math.max(w_min + 1, math.min(w_max, near))
    local near_hi = math.min(w_max, near + (near - w_min) * 0.4)
    local t1 = Geometry.FOUNTAIN_HAIR_END
    local t2 = Geometry.FOUNTAIN_NEAR_END

    if t <= t1 then
        -- Leave pure hairline quickly (narrow 1px zone).
        local u = (t1 > 0) and (t / t1) or 1
        return w_min + (near - w_min) * (u * u)
    elseif t <= t2 then
        -- Spend most "thin" headings in the 2nd-thin band.
        local u = (t - t1) / (t2 - t1)
        return near + (near_hi - near) * u
    else
        local u = (t - t2) / (1 - t2)
        return near_hi + (w_max - near_hi) * (u * u)
    end
end

--- Heading of the segment p1→p2 in radians, or nil if the points coincide.
function Geometry.strokeHeading(p1, p2)
    local dx = p2.x - p1.x
    local dy = p2.y - p1.y
    if dx == 0 and dy == 0 then
        return nil
    end
    return math.atan2(dy, dx)
end

--- Wrap-safe exponential smooth of headings in radians.
function Geometry.smoothHeading(prev, new, k)
    if not new then return prev end
    if not prev then return new end
    k = k or Geometry.FOUNTAIN_HEADING_SMOOTH
    local delta = new - prev
    while delta > math.pi do
        new = new - 2 * math.pi
        delta = new - prev
    end
    while delta < -math.pi do
        new = new + 2 * math.pi
        delta = new - prev
    end
    return prev + k * (new - prev)
end

--- Calligraphic width: hairline along the nib, full width across it.
function Geometry.nibWidth(heading, nib_angle, w_min, w_max)
    return Geometry.nibLengthForHeading(heading, nib_angle, w_min, w_max)
end

return Geometry
