--[[
    Single parry:
        ["animId"] = 0.3

    Multi-hit parry (legacy array):
        ["animId"] = {0.2, 0.6}

    Typed single:
        ["animId"] = {type="parry",  t=0.3}
        ["animId"] = {type="dodge",  t=0.3}
        ["animId"] = {type="jump",   t=0.3}
        ["animId"] = {type="crouch", t=0.3}

    Typed multi:
        ["animId"] = {type="parry", t={0.2, 0.6}}

    Sequence (hybrid — one animation, multiple mixed actions):
        ["animId"] = {
            {type="jump",  t=0.4},
            {type="parry", t=0.9},
            {type="parry", t=1.1},
            {type="jump",  t=1.5},
        }

    Notes:
    - "dodge" entries respect the "Parry Unparryables" toggle
      (presses F instead of Q when that is on).
    - "jump" and "crouch" fire automatically with no separate toggle.
    - "crouch" always auto-uncrouches after ~500ms.
]]

return {

    ----------------------------------------------------------------
    -- DEFAULT SWORD
    ----------------------------------------------------------------
    ["7600450739"] = 0.1,   -- LightAttack 1
    ["7600160919"] = 0.1,   -- LightAttack 3
    ["7600485223"] = 0.15,  -- LightAttack 2
    ["7600224169"] = 0.15,  -- LightAttack 2 (alt)
    ["9484850093"] = 0.1,   -- LightAttack 4
    ["7318254065"] = 0.5,   -- Critical
    ["4699358112"] = 0.5,   -- Running LightAttack
    ["7576748728"] = 0.5,   -- Aerial LightAttack

    ----------------------------------------------------------------
    -- BATTLEAXE
    ----------------------------------------------------------------
    ["5064195992"]  = 0.2,   -- LightAttack 1
    ["5067105317"]  = 0.2,   -- LightAttack 2
    ["5067090007"]  = 0.4,   -- LightAttack 3
    ["7388133473"]  = 0.5,   -- Critical
    ["11363599835"] = 0.5,   -- Aerial LightAttack

    ----------------------------------------------------------------
    -- STILETTO
    ----------------------------------------------------------------
    ["7627854272"] = 0.5,   -- LightAttack 1 / 3
    ["7627889074"] = 0.1,   -- LightAttack 2
    ["5950080662"] = 0.15,  -- LightAttack 4
    ["7350770431"] = 0.5,   -- Critical
    ["5063313656"] = 0.5,   -- Running Light
    ["7576614609"] = 0.5,   -- Aerial Light

    ----------------------------------------------------------------
    -- NPCS
    ----------------------------------------------------------------

    -- Sharko
    ["5121733951"] = {0.10, 0.30}, -- Double Swipe
    ["5117879514"] = 0.1,          -- Single Swipe
    ["11710290503"] = 0.15,        -- Kick

    -- Golem
    -- Add real animation IDs here when available.
    -- ["ANIMATION_ID"] = 0, -- Uppercut
    -- ["ANIMATION_ID"] = 0, -- Downslam
    -- ["ANIMATION_ID"] = 0, -- Beam
    -- ["ANIMATION_ID"] = {type="jump", t=0}, -- Stomp

    -- Thresher
    ["822787518"]  = 0.6,             -- Tail Swipe
    ["8227583745"] = {0.4, 0.7},      -- Double Slash
    ["8226933122"] = {0.5, 1, 1.4},  -- Triple Bite

    -- Angels
    -- Add animation IDs here.

    -- Stone Knight
    -- Add real animation IDs here when available.
    -- ["ANIMATION_ID"] = 0, -- First Swing
    -- ["ANIMATION_ID"] = 0, -- Second Swing
    -- ["ANIMATION_ID"] = 0, -- Kick
    -- ["ANIMATION_ID"] = 0, -- Pillar
    -- ["ANIMATION_ID"] = 0, -- Slash

    ----------------------------------------------------------------
    -- ENFORCER
    ----------------------------------------------------------------
    ["7019686291"] = 0.15, -- Kick
    ["7018046790"] = 0.25, -- M1
    ["7018083796"] = 0.25, -- M2
    -- ["7019018522"] = 0.6, -- Spin (disabled)
    -- ["7271659917"] = 0.6, -- Pull (disabled)

    ----------------------------------------------------------------
    -- PRIMADON
    ----------------------------------------------------------------
    ["9225098544"] = 0.6,                -- Stomp (single)
    ["6432260013"] = {0.10, 0.50, 0.90}, -- Stomp (3-hit)

    ----------------------------------------------------------------
    -- VOW OF IRON — SHOGUN
    ----------------------------------------------------------------

    -- Parry animations
    ["118154222392812"] = {
        type = "parry",
        t = {0.7, 1.5}
    }, -- Double Slash

    ["86527092652774"] = 0.6, -- Single Diagonal Slash

    ["134600514326413"] = {
        type = "parry",
        t = {0.7, 1.2}
    }, -- Stomp into Slash

    -- Dodge animations
    -- Unparryable: Q normally, F with "Parry Unparryables" enabled
    ["124963391435150"] = {
        type = "dodge",
        t = {0.5, 1.0}
    }, -- Red Double Slash

    -- Crouch example
    -- This is intentionally disabled because it uses the same
    -- animation ID as the dodge above.
    -- ["124963391435150"] = {
    --     type = "crouch",
    --     t = 0.3
    -- },

    -- Hybrid / sequence
    -- Jump + parry in one animation
    ["112423929319383"] = {
        {type = "jump",  t = 0.4},
        {type = "parry", t = 0.9},
        {type = "parry", t = 1.1},
        {type = "jump",  t = 1.5},
    }, -- Jump Stomps with Slashes

    -- Flurry Combo
    ["76782656543761"] = {
        {type = "parry", t = 0.3},
        {type = "dodge", t = 0.5},
        {type = "parry", t = 0.6},
        {type = "parry", t = 0.8},
    },

    ----------------------------------------------------------------
    -- TEMPLATE — copy and fill in for new bosses/weapons
    ----------------------------------------------------------------
    -- ["animId"] = 0.3, -- M1
    -- ["animId"] = 0.3, -- M2
    -- ["animId"] = 0.3, -- M3
    -- ["animId"] = 0.3, -- M4
    -- ["animId"] = 0.3, -- M5
    -- ["animId"] = 0.5, -- Critical
}
